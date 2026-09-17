import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/meshcore_device.dart';
import 'meshcore_service.dart';

class LocationTrackingService extends ChangeNotifier {
  final MeshCoreService _meshCoreService;

  LocationTrackingService(this._meshCoreService);

  static const String _prefsEnabledKey = 'location_tracking_enabled';
  static const String _prefsIntervalKey = 'location_tracking_interval_seconds';

  static const Duration defaultTrackingInterval = Duration(seconds: 30);
  static const Duration _fastLocationStationaryInterval = Duration(minutes: 9);
  static const Duration _fastLocationWalkingInterval = Duration(seconds: 60);
  static const Duration _fastLocationRunningInterval = Duration(seconds: 30);
  static const Duration _fastLocationDrivingInterval = Duration(seconds: 10);
  static const double _fastLocationMoveRadiusMeters = 20.0;
  static const Duration _fastLocationStopDwell = Duration(seconds: 15);
  static const double _fastLocationIdleSpeedMaxMetersPerSecond = 1.2;
  static const double _fastLocationWalkingSpeedMaxMetersPerSecond = 2.8;
  static const double fastLocationMovementThresholdMeters = 20.0;

  StreamSubscription<Position>? _positionSubscription;
  Timer? _periodicTimer;
  bool _isTracking = false;
  bool _isInitialized = false;
  Duration _trackingInterval = defaultTrackingInterval;
  Position? _currentPosition;

  bool _fastGpsRefValid = false;
  bool _fastGpsIsMoving = false;
  int? _fastGpsAnchorLatE6;
  int? _fastGpsAnchorLonE6;
  DateTime? _fastGpsMoveStateSince;
  double _fastGpsSpeedKmh = 0.0;
  int? _lastFastLocationSentLatE6;
  int? _lastFastLocationSentLonE6;
  DateTime? _lastFastLocationSentAt;
  DateTime? _fastGpsRxHoldoffUntil;

  bool fastLocationUpdatesEnabled = true;
  int? fastLocationChannelIdx;
  void Function(double latitude, double longitude, int speedKmh, String reason)?
      onFastLocationUpdate;

  bool get isTracking => _isTracking;
  Duration get trackingInterval => _trackingInterval;
  Position? get currentPosition => _currentPosition;

  Future<void> initialize() async {
    if (_isInitialized) return;
    _isInitialized = true;
    final prefs = await SharedPreferences.getInstance();
    _isTracking = prefs.getBool(_prefsEnabledKey) ?? false;
    final seconds = prefs.getInt(_prefsIntervalKey);
    if (seconds != null && seconds > 0) {
      _trackingInterval = Duration(seconds: seconds);
    }
    if (_isTracking) {
      await startTracking();
    }
  }

  Future<bool> _ensurePermission() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
  }

  Future<void> startTracking() async {
    if (!await _ensurePermission()) return;
    if (_isTracking) return;

    _isTracking = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsEnabledKey, true);

    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
      ),
    ).listen(_handlePosition);

    _periodicTimer?.cancel();
    _periodicTimer = Timer.periodic(_trackingInterval, (_) {
      _maybeSendFastLocation();
    });

    notifyListeners();
  }

  Future<void> stopTracking() async {
    _isTracking = false;
    await _positionSubscription?.cancel();
    _positionSubscription = null;
    _periodicTimer?.cancel();
    _periodicTimer = null;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsEnabledKey, false);
    notifyListeners();
  }

  Future<void> setTrackingInterval(Duration interval) async {
    if (interval <= Duration.zero) return;
    _trackingInterval = interval;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefsIntervalKey, interval.inSeconds);

    if (_isTracking) {
      _periodicTimer?.cancel();
      _periodicTimer = Timer.periodic(_trackingInterval, (_) {
        _maybeSendFastLocation();
      });
    }
    notifyListeners();
  }

  void disposeTracking() {
    _positionSubscription?.cancel();
    _positionSubscription = null;
    _periodicTimer?.cancel();
    _periodicTimer = null;
  }

  void _handlePosition(Position position) {
    _currentPosition = position;
    _fastGpsSpeedKmh = position.speed.isFinite && position.speed >= 0
        ? position.speed * 3.6
        : 0.0;
    _updateFastGpsState(position);
    notifyListeners();
  }

  void _updateFastGpsState(Position position) {
    final now = DateTime.now();
    final latE6 = (position.latitude * 1e6).round();
    final lonE6 = (position.longitude * 1e6).round();

    if (!_fastGpsRefValid) {
      _fastGpsAnchorLatE6 = latE6;
      _fastGpsAnchorLonE6 = lonE6;
      _fastGpsRefValid = true;
      _fastGpsIsMoving = false;
      _fastGpsMoveStateSince = null;
      return;
    }

    final anchorLat = _fastGpsAnchorLatE6;
    final anchorLon = _fastGpsAnchorLonE6;
    if (anchorLat == null || anchorLon == null) return;

    final refDist = _distanceE6(anchorLat, anchorLon, latE6, lonE6);
    final movingNow = _fastGpsSpeedKmh >=
        _fastLocationWalkingSpeedMaxMetersPerSecond * 3.6;

    if (_fastGpsIsMoving) {
      if (movingNow || refDist > _fastLocationMoveRadiusMeters) {
        _fastGpsMoveStateSince = null;
        // Track slow GPS bias so cumulative drift never reaches the radius.
        _fastGpsAnchorLatE6 =
            anchorLat + ((latE6 - anchorLat) ~/ 8);
        _fastGpsAnchorLonE6 =
            anchorLon + ((lonE6 - anchorLon) ~/ 8);
      }
    } else {
      if (refDist > _fastLocationMoveRadiusMeters) {
        _fastGpsAnchorLatE6 = latE6;
        _fastGpsAnchorLonE6 = lonE6;
        _fastGpsMoveStateSince = null;
      } else if (_fastGpsMoveStateSince == null) {
        _fastGpsMoveStateSince = now;
      } else if (now.difference(_fastGpsMoveStateSince!) >=
          _fastLocationStopDwell) {
        _fastGpsIsMoving = false;
        _fastGpsAnchorLatE6 = latE6;
        _fastGpsAnchorLonE6 = lonE6;
        _fastGpsMoveStateSince = null;
      }
    }

    if (!_fastGpsIsMoving && movingNow) {
      _fastGpsIsMoving = true;
      _fastGpsMoveStateSince = null;
    }
  }

  /// Decides whether to emit a beacon now, mirroring maybeSendFastGpsUpdate:
  /// moving → speed-tier cadence once past the movement threshold; parked →
  /// flat 9-min keepalive of the stable anchor. Honours the RX hold-off.
  void _maybeSendFastLocation() {
    if (!fastLocationUpdatesEnabled || fastLocationChannelIdx == null) return;
    final position = currentPosition;
    if (position == null) return;
    // No valid anchor yet means no good fix has landed — don't beacon (the
    // firmware likewise bails until it has a usable fix).
    if (!_fastGpsRefValid) return;

    final int reportLatE6;
    final int reportLonE6;
    if (_fastGpsIsMoving) {
      reportLatE6 = (position.latitude * 1e6).round();
      reportLonE6 = (position.longitude * 1e6).round();
    } else {
      // Parked: report the stable anchor, not the wander.
      final anchorLat = _fastGpsAnchorLatE6;
      final anchorLon = _fastGpsAnchorLonE6;
      if (anchorLat == null || anchorLon == null) return;
      reportLatE6 = anchorLat;
      reportLonE6 = anchorLon;
    }

    final now = DateTime.now();
    final lastAt = _lastFastLocationSentAt;
    bool shouldSend = lastAt == null || _lastFastLocationSentLatE6 == null;
    String reason = 'initial';
    if (!shouldSend) {
      final lastLat = _lastFastLocationSentLatE6;
      final lastLon = _lastFastLocationSentLonE6;
      if (lastLat == null || lastLon == null) return;

      if (_fastGpsIsMoving) {
        final distM = _distanceE6(
          lastLat,
          lastLon,
          reportLatE6,
          reportLonE6,
        );
        if (distM > fastLocationMovementThresholdMeters) {
          if (lastAt == null) return;
          final elapsed = now.difference(lastAt);
          final interval = _movingIntervalForSpeedKmh(_fastGpsSpeedKmh);
          shouldSend = elapsed >= interval;
          reason = 'movement';
        }
      } else if (lastAt != null &&
          now.difference(lastAt) >= _fastLocationStationaryInterval) {
        shouldSend = true;
        reason = 'stationary';
      }
    }
    if (!shouldSend) return;

    // Yield the channel briefly after hearing a peer beacon.
    final holdoff = _fastGpsRxHoldoffUntil;
    if (holdoff != null) {
      if (now.isBefore(holdoff)) return;
      _fastGpsRxHoldoffUntil = null;
    }

    _lastFastLocationSentLatE6 = reportLatE6;
    _lastFastLocationSentLonE6 = reportLonE6;
    _lastFastLocationSentAt = now;

    final speedKmh = _fastGpsSpeedKmh < 0
        ? 0
        : (_fastGpsSpeedKmh > 255.0 ? 255 : (_fastGpsSpeedKmh + 0.5).floor());
    onFastLocationUpdate?.call(
      reportLatE6 / 1e6,
      reportLonE6 / 1e6,
      speedKmh,
      reason,
    );
  }

  Duration _movingIntervalForSpeedKmh(double speedKmh) {
    final speedMps = speedKmh / 3.6;
    if (speedMps < _fastLocationIdleSpeedMaxMetersPerSecond) {
      return _fastLocationStationaryInterval;
    }
    if (speedMps < _fastLocationWalkingSpeedMaxMetersPerSecond) {
      return _fastLocationWalkingInterval;
    }
    if (speedMps < 12.0) {
      return _fastLocationRunningInterval;
    }
    return _fastLocationDrivingInterval;
  }

  double _distanceE6(int lat1E6, int lon1E6, int lat2E6, int lon2E6) {
    const earthRadiusM = 6371000.0;
    final lat1 = lat1E6 / 1e6 * math.pi / 180.0;
    final lon1 = lon1E6 / 1e6 * math.pi / 180.0;
    final lat2 = lat2E6 / 1e6 * math.pi / 180.0;
    final lon2 = lon2E6 / 1e6 * math.pi / 180.0;
    final dLat = lat2 - lat1;
    final dLon = lon2 - lon1;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) * math.cos(lat2) *
            math.sin(dLon / 2) * math.sin(dLon / 2);
    return 2 * earthRadiusM * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }

  void setFastLocationRxHoldoff(Duration duration) {
    _fastGpsRxHoldoffUntil = DateTime.now().add(duration);
  }

  MeshCoreService get meshCoreService => _meshCoreService;
}
