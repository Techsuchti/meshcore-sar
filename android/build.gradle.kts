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
    // flutter_avif_android 3.1.0 ships duplicate Java and Kotlin copies of
    // FlutterAvifPlugin. With newer Android Gradle Plugin versions the Java
    // copy causes a redeclaration/registration problem. Keep the Kotlin
    // implementation as the plugin's Java source root so the Android library
    // exposes FlutterAvifPlugin correctly to the app.
    afterEvaluate {
        if (project.name == "flutter_avif_android") {
            extensions.findByName("android")?.let { ext ->
                (ext as com.android.build.gradle.BaseExtension)
                    .sourceSets.getByName("main").java
                    .setSrcDirs(listOf("src/main/kotlin"))
            }
        }
    }
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
