# Android 依赖兼容清单（minSdk 24）

> 契约层文件 · `contract/docs/android-compat.md`
> **依据**：D12 定稿（Android 7.0 / API 24）
> **更新日期**：2026-09-29

---

## 1. 结论：minSdk 24 无需依赖锁版

经联网查证（Flutter 官方支持矩阵 3.47 + apilevels.com），**API 24 下所有现代依赖可用**，无需锁版。

| 项 | API 21（原方案） | **API 24（当前）** |
|----|-----------------|-------------------|
| 官方支持 | ❌ `Unsupported: 23 and earlier` | ✅ Supported 24-37, CI tested 24-36 |
| 多 Dex | 必需 | ✅ **不需要** |
| Java 8 脱糖 | 必需 | ✅ **不需要** |
| Impeller | 需回退 Skia | ✅ **可正常使用** |
| 依赖锁版 | 3 项强制锁版 | ✅ **无** |
| CI 守卫脚本 | 必需 | ✅ **不需要** |
| 覆盖率 | 99.8% | **96.6%**（放弃 3.4%） |

---

## 2. 依赖清单（无版本限制）

| 依赖 | 用途 | 版本要求 |
|------|------|---------|
| `flutter` | 框架 | 3.24.x+（锁 stable） |
| `riverpod` / `flutter_riverpod` | 状态管理 | 2.x |
| `go_router` | 路由 | 14.x |
| `sqflite` | SQLite | 最新稳定 |
| `drift`（可选） | SQLite ORM | 最新稳定 |
| `dio` | 网络 | 5.x |
| `freezed` + `json_serializable` | 模型 | 最新稳定 |
| `path_provider` | 路径 | 最新稳定 |
| `file_picker` | 文件选择 | **最新稳定**（原 8.x 限制已解除） |
| `cryptography` | AES-GCM + PBKDF2 | 最��稳定 |
| `flutter_secure_storage` | 安全存储 | **最新稳定**（原锁 9.2.4 已解除） |
| `permission_handler` | 权限 | **最新稳定**（原锁 11.4.0 已解除） |
| `wakelock_plus` | 唤醒锁 | **最新稳定**（原锁 1.2.10 已解除） |
| `shared_preferences` | 键值存储 | 最新稳定 |
| `media_kit` | 桌面播放器（libmpv） | 最新稳定 |
| `video_player` | 移动播放器 | 最新稳定 |
| `audio_service` | 后台音频 | 最新稳定 |

---

## 3. Android 原生依赖

```gradle
android {
    compileSdk 36
    ndkVersion "25.1.8937393"

    defaultConfig {
        applicationId "com.vbox.player"
        minSdk 24              // Android 7.0
        targetSdk 36
        ndk { abiFilters 'armeabi-v7a', 'arm64-v8a', 'x86_64' }
    }

    compileOptions {
        sourceCompatibility JavaVersion.VERSION_17
        targetCompatibility JavaVersion.VERSION_17
        // ⚠️ 不需要 coreLibraryDesugaring（minSdk 24）
    }
    kotlinOptions { jvmTarget = '17' }

    buildTypes {
        release {
            minifyEnabled true
            shrinkResources true
            proguardFiles getDefaultProguardFile('proguard-android-optimize.txt'), 'proguard-rules.pro'
        }
    }

    splits {
        abi {
            enable true
            reset()
            include 'armeabi-v7a', 'arm64-v8a', 'x86_64'
            universalApk true    // 同时产出通用包，便于测试
        }
    }
}

dependencies {
    // ⚠️ 不需要 androidx.multidex（minSdk 24）
    implementation 'androidx.media3:media3-exoplayer:1.3.1'
    implementation 'androidx.media3:media3-exoplayer-hls:1.3.1'
    implementation 'androidx.media3:media3-ui:1.3.1'
    implementation 'org.videolan.android:libvlc-all:3.6.0'
}
```

**已移除项**（相比 API 21 方案）：
- ❌ `coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.0.4'`
- ❌ `implementation 'androidx.multidex:multidex:2.0.1'`
- ❌ `coreLibraryDesugaringEnabled true`
- ❌ `multiDexEnabled true`
- ❌ `<meta-data android:name="io.flutter.embedding.android.EnableImpeller" android:value="false" />`

---

## 4. AndroidManifest 要点（API 24）

| 属性 | API 24 行为 |
|------|-----------|
| `android:banner` | ✅ 可用（API 21+） |
| `foregroundServiceType` | API 29+ 引入（API 24 忽略，无害） |
| `FOREGROUND_SERVICE_MEDIA_PLAYBACK` | API 34+（API 24 忽略） |
| `usesCleartextTraffic` | ✅ API 23+ 生效，API 24 读取 |
| **FileProvider** | ✅ **API 24 原生可用**（自更新依赖） |
| `REQUEST_INSTALL_PACKAGES` | API 26+ 需要（API 24-25 直接安装） |
| `network_security_config.xml` | ✅ API 24+ 读取 |

### 4.1 双形态入口（D2）

```xml
<!-- 关键：双向兼容 -->
<uses-feature android:name="android.hardware.touchscreen"  android:required="false" />
<uses-feature android:name="android.software.leanback"     android:required="false" />

<activity android:name=".MainActivity" android:exported="true">
    <!-- 手机入口 -->
    <intent-filter>
        <action android:name="android.intent.action.MAIN" />
        <category android:name="android.intent.category.LAUNCHER" />
    </intent-filter>
    <!-- TV 入口 -->
    <intent-filter>
        <action android:name="android.intent.action.MAIN" />
        <category android:name="android.intent.category.LEANBACK_LAUNCHER" />
    </intent-filter>
</activity>
```

---

## 5. 播放器策略（API 24）

```kotlin
object CodecCapability {
    fun supportsHevcHardware(): Boolean {
        val list = MediaCodecList(MediaCodecList.REGULAR_CODECS)
        return list.codecInfos.any { info ->
            !info.isEncoder && info.supportedTypes.any { it.equals("video/hevc", true) }
        }
    }

    fun selectBackend(url: String): PlayerBackend {
        val ext = url.substringAfterLast('.', "").lowercase()
        return when {
            ext == "mkv"                           -> PlayerBackend.LIBVLC
            isHevc(url) && !supportsHevcHardware() -> PlayerBackend.LIBVLC
            else                                   -> PlayerBackend.MEDIA3
        }
    }
    private fun isHevc(url: String) = url.contains("hevc", true) || url.contains("h265", true)
}
```

---

## 6. 覆盖率依据（已查证）

| 来源 | 数据 |
|------|------|
| Flutter 官方（docs.flutter.dev，3.47） | Android Supported **24 → 37**；Unsupported **23 and earlier** |
| Flutter 引擎源码 | `minSdkVersionInt = 24` |
| Flutter Gradle 插件 | `val minSdkVersion: Int = 24` |
| apilevels.com（2026-04 数据） | **API 24 累积覆盖 96.6%** |
| apilevels.com | Jetpack/AndroidX 自 2025-06 起要求 minSdk ≥ 23 |
| apilevels.com | Google Play Services 自 2024-07 起要求 API ≥ 23 |

**放弃设备（3.4%）**：Android 5.0/5.1/6.0

---

## 7. 测试设备矩阵

| 类型 | Android | 优先级 |
|------|---------|--------|
| **最低版本真机** | **7.0/7.1** | **P0（必须）** |
| 中端盒子 | 8.1/9.0 | P0 |
| 高端设备 | 10+ | P1 |
| 模拟器 | API 24 | P0（基线） |

**最低要求**：4 台真机，至少 1 台 Android 7.x。

---

## 8. CI 检查项

```yaml
# .github/workflows/ci.yml 要点
- name: 校验 minSdk
  run: |
    grep -q 'minSdk 24\|minSdkVersion 24' android/app/build.gradle \
      || (echo "❌ minSdk 必须为 24" && exit 1)
    echo "✅ minSdk 24 校验通过"

- name: 校验无冗余配置
  run: |
    ! grep -q 'coreLibraryDesugaring' android/app/build.gradle \
      || (echo "❌ minSdk 24 不应有 desugaring" && exit 1)
    ! grep -q 'multiDexEnabled' android/app/build.gradle \
      || (echo "❌ minSdk 24 不应启用多 Dex" && exit 1)
    echo "✅ 无冗余配置"
```

---

## 9. 若未来需降级到 API 21

参考 `vbox_flutter_migration_plan.md` 第「二之补二」章（A21.1-A21.8），需恢复：
- 多 Dex + 脱糖 + Impeller 回退
- 3 项依赖锁版 + CI 守卫
- 长期维护 API 21 测试设备

**成本**：约 +3 周，覆盖仅增加 3.2%。
