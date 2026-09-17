allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

subprojects {
    project.evaluationDependsOn(":app")

    // flutter_avif_android 3.1.0 contains duplicate Java/Kotlin
    // declarations of FlutterAvifPlugin. Keep the Kotlin implementation,
    // which is the implementation registered by the plugin's pubspec.
    // AGP 8.9+ compiles both source trees and otherwise reports a duplicate
    // class declaration. This workaround is required until the package is fixed upstream.
    if (project.name == "flutter_avif_android") {
        project.plugins.withId("com.android.library") {
            project.extensions.configure<com.android.build.gradle.LibraryExtension>("android") {
                sourceSets.getByName("main") {
                    java.setSrcDirs(listOf("src/main/kotlin"))
                }
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
