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
    id("com.android.application") version "9.1.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
    // Wave G · RT-运1：Chaquopy Python 运行时（Android 侧）
    // 17.0 支持 AGP 7.3–9.2（本工程 AGP 9.1.0 命中区间）与 minSdk 24；
    // 解析自 pluginManagement.repositories 的 mavenCentral()。
    id("com.chaquo.python") version "17.0.0" apply false
}

include(":app")
