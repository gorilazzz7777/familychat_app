// Use Android Studio JBR when JAVA_HOME is unset (common on Windows CLI builds).
if (System.getProperty("org.gradle.java.home").isNullOrBlank()) {
    val envHome = System.getenv("JAVA_HOME")?.trim().orEmpty()
    if (envHome.isEmpty()) {
        val isWindows = System.getProperty("os.name").contains("Windows", ignoreCase = true)
        val candidates = listOf(
            "C:/Program Files/Android/Android Studio/jbr",
            "${System.getProperty("user.home")}/AppData/Local/Programs/Android Studio/jbr",
            "/Applications/Android Studio.app/Contents/jbr/Contents/Home",
        )
        for (path in candidates) {
            val dir = java.io.File(path)
            val javaBin = java.io.File(dir, if (isWindows) "bin/java.exe" else "bin/java")
            if (javaBin.isFile) {
                System.setProperty("org.gradle.java.home", dir.absolutePath)
                break
            }
        }
    }
}

pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
    id("com.google.gms.google-services") version "4.4.4" apply false
    // Auto-download JDK 17 toolchains for plugins such as flutter_callkit_incoming.
    id("org.gradle.toolchains.foojay-resolver-convention") version "0.9.0"
}

include(":app")
