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
}

// flutter_avif_android 3.1.0 contains the plugin implementation under the
// Kotlin source tree. Make that tree visible as Java/Kotlin source to AGP so
// Flutter's GeneratedPluginRegistrant can resolve FlutterAvifPlugin.
project(":app") {
    afterEvaluate {
        val avifProject = rootProject.findProject(":flutter_avif_android")
        if (avifProject != null) {
            avifProject.afterEvaluate {
                extensions.findByName("android")?.let { ext ->
                    (ext as com.android.build.gradle.BaseExtension)
                        .sourceSets.getByName("main").java
                        .srcDirs("src/main/kotlin")
                }
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}