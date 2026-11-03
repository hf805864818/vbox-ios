import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Wave G · RT-运1：Chaquopy Python 运行时（Android 侧）。
    // Android 无 `python3` 可执行文件（Dart `Process.start('python3')` 不可用），
    // 9 个 `y_*` Python 蜘蛛站点因此不可用；本插件把 CPython 解释器随 APK 打包，
    // 由 PythonPlugin 在**进程内**运行蜘蛛脚本（对齐 iOS 的 Python 运行时语义）。
    id("com.chaquo.python")
}

// G-09 P4：本地 release 构建签名。
// 密钥路径与密码只写在 android/key.properties（已被 .gitignore 排除，不入库、不进 CI）。
// 该文件不存在时（CI 环境）回退 debug 签名，由 build-release-assets.yml 用 apksigner 重签。
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
val hasReleaseSigning = keystorePropertiesFile.exists()
if (hasReleaseSigning) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

// Wave G · RT-运1：Chaquopy 需 `ndk.abiFilters` 非空；而 AGP 9 禁止其与 `splits.abi`
// （Flutter `--split-per-abi` 会设置）并存 → 改为「分 ABI 多次构建」产出分 ABI 包：
//   `-PvboxAbi=arm64-v8a`（或逗号分隔的多个 ABI），不传则回退三 ABI（flutter-check debug / 本地）。
val vboxAbis: List<String> =
    (project.findProperty("vboxAbi") as String?)
        ?.split(",")
        ?.map { it.trim() }
        ?.filter { it.isNotEmpty() }
        ?.takeIf { it.isNotEmpty() }
        ?: listOf("armeabi-v7a", "arm64-v8a", "x86_64")

android {
    namespace = "com.vbox.player"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.vbox.player"
        // D12：TV 最低版本锁定 Android 7.0 (API 24)，显式写死以免随 Flutter 默认值漂移。
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Wave G · RT-运1：Chaquopy 的 CPython 解释器是原生组件，须显式声明 ABI
        // （Chaquopy 强制要求 ndk.abiFilters 非空）。Python 选 3.11（见下 chaquopy 块）
        // 以保留 32 位 armeabi-v7a 支持。
        //
        // 分 ABI 打包：AGP 9 禁止 `splits.abi`（Flutter `--split-per-abi` 会设置）与
        // `ndk.abiFilters` 并存，而 Chaquopy 又强制要求 abiFilters，二者不可兼得。
        // 故改为「分 ABI 多次构建」：由 `-PvboxAbi=<abi>[,<abi>]` 指定本次构建的 ABI
        // （见文件顶部 vboxAbis 解析）；不传时回退三 ABI。构建脚本须同时传
        // `-Pdisable-abi-filtering=true`，阻止 Flutter Gradle 插件在非 split 构建中
        // 覆写本处 abiFilters（FlutterPlugin.configureAbiWithoutSplits）。
        ndk {
            abiFilters += vboxAbis
        }

        // 批次 I · ND-01-native：nodejs-mobile 的 libnode.so 以 libc++_shared 构建
        // （官方 Android 集成口径），须向 CMake 传 ANDROID_STL=c++_shared 以匹配 STL ABI。
        externalNativeBuild {
            cmake {
                arguments += "-DANDROID_STL=c++_shared"
            }
        }
    }

    // G-09 P4：有 key.properties 时使用固定 release keystore（本地发布构建），否则回退 debug。
    // 修复「国产电视（KKTV/康佳系）安装提示应用未安装」：minSdk=24 时 AGP 默认关闭
    // v1（JAR）签名、只打 v2/v3，而国产电视魔改 PackageManager/自带安装器常只认 v1
    // 签名 → 显式开启 v1 + v2 双签名，兼容老安装器与原生新系统（云手机）两侧。
    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                enableV1Signing = true
                enableV2Signing = true
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }

    // 批次 Q · Q-02：JSC 引擎原生模块（NDK + CMake）。
    // 编译 jsc/wrapper.c → libvbox_jsc.so（ABI 形状对齐 libvbox_quickjs 的 vq_*）。
    // 前置：scripts/fetch-jsc-android.sh 就位四 ABI libjsc.so（jniLibs，AGP 随 APK 打包）。
    // ABI 由 defaultConfig.ndk.abiFilters 收敛（RT-运1 引入，供 Chaquopy 声明；分 ABI 构建见顶部 vboxAbis）。
    externalNativeBuild {
        cmake {
            path = file("src/main/jni/CMakeLists.txt")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

// Wave G · RT-运1：Chaquopy 配置。
//  · version 3.11：3.11 及更早保留 32 位 ABI 支持（Chaquopy 17 默认 3.10）；
//  · 无 pip 构建依赖：纯 Python 库直接 vendor 在 src/main/python/
//    （base.spider / Crypto / pyaes / requests / urllib3 / idna / certifi /
//    charset_normalizer，对齐 iOS site-packages 的纯 Python 部署），避免
//    构建机 Python 版本（buildPython 须与 3.11 同 minor）与网络依赖；
//  · pyc.src = false：不要求构建机安装同 minor 版本 Python（CI 免额外前置），
//    源码 .py 直接入 APK，首次运行由设备端编译（仅影响首启耗时，不影响正确性）。
//  蜘蛛脚本桥：src/main/python/vbox_python_bridge.py（v2 对象调用模型，
//  对齐 iOS PythonBridge.m）。
chaquopy {
    defaultConfig {
        version = "3.11"
        pyc {
            src = false
        }
    }
}

// G-02-A：播放器插件依赖（纯 Gradle 依赖，零 NDK）。
//   · androidx.media3: Media3 主后端（ExoPlayer + HLS）
//   · androidx.media3:media3-session: MediaSessionService 宿主（G-02-C 前台媒体服务）
//   · org.videolan.android:libvlc-all: libVLC 回退（aar 自带原生库，minSdk 21+；实现在 G-02-B/C）
dependencies {
    implementation("androidx.media3:media3-exoplayer:1.5.1")
    implementation("androidx.media3:media3-exoplayer-hls:1.5.1")
    implementation("androidx.media3:media3-session:1.5.1")
    implementation("org.videolan.android:libvlc-all:3.6.0")
    // E-04：直播源导出分享 FileProvider（androidx.core.content.FileProvider）。
    implementation("androidx.core:core-ktx:1.13.1")
}

flutter {
    source = "../.."
}
