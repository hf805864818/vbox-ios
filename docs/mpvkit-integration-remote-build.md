# MPVKit.xcframework 远程接入说明

本次改动目标是让没有本地 Xcode 的情况下，也能通过 GitHub Actions 自动完成 MPVKit 接入验证。

## 已完成改动

1. 新增 `scripts/mpv/download-mpvkit-framework.sh`
   - 支持从 `mpvkit-wrapper-*` Release 自动下载 `MPVKit.xcframework.zip`
   - 支持通过 `MPVKIT_SOURCE_URL` 指定直链
   - 自动解压到 `vbox/Libraries/MPV/MPVKit.xcframework`

2. 修改 `.github/workflows/build-ipa.yml`
   - App 编译前自动准备 `MPVKit.xcframework`
   - `workflow_dispatch` 支持填写：
     - `mpvkit_source_url`
     - `mpvkit_release_tag`

3. 修改 `vbox.xcodeproj/project.pbxproj`
   - 添加 `MPVKit.xcframework`
   - 加入 Link Binary With Libraries
   - 加入 Embed Frameworks
   - 添加 `FRAMEWORK_SEARCH_PATHS = $(SRCROOT)/vbox/Libraries/MPV`

4. 新增 MPVKit 最小播放后端
   - `MPVKitPlayerCore.swift`
   - `MPVKitRenderView.swift`
   - `MPVKitMetalLayer.swift`
   - `MPVKitProperty.swift`
   - 改造 `MPVKitBackend.swift`

5. 新增设置页调试入口
   - `MPVKitDebugPlayerView.swift`
   - 设置页 → 网盘播放 → MPVKit 播放调试

## 推荐远程编译流程

### 第一步：生成 MPVKit.xcframework

在 `rebuild-8db3547` 分支运行：

```text
Build MPVKit.xcframework wrapper
```

参数建议：

```text
mpvkit_ref = main
product = MPVKit
publish_release = true
```

成功后会发布类似：

```text
mpvkit-wrapper-xxx
```

Release 里应包含：

```text
MPVKit.xcframework.zip
```

### 第二步：编译 App

在 `feature/mpv-framework-actions` 分支运行：

```text
Build IPA (巨魔安装版)
```

如果已经有 `mpvkit-wrapper-*` Release，可以不填参数，workflow 会自动查找最新的 MPVKit Release。

如果要指定产物，可以填写：

```text
mpvkit_release_tag = mpvkit-wrapper-xxx
```

或者：

```text
mpvkit_source_url = MPVKit.xcframework.zip 的直链
```

## 验收方式

安装 IPA 后进入：

```text
设置 → 网盘播放 → MPVKit 播放调试
```

检查：

```text
MPVKit = 可用
```

点击播放默认测试地址：

```text
https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8
```

成功信号：

```text
MPVKit 初始化完成
MPVKit 加载：MPVKit 调试播放
MPVKit 事件：file-loaded
进度开始变化
```

## 常见失败原因

| 错误 | 可能原因 |
|---|---|
| `no such module 'MPVKit'` | framework 未下载、搜索路径错误、xcframework 模块名不对 |
| `framework not found MPVKit` | Xcode 工程引用或解压路径不对 |
| `dyld: Library not loaded` | Embed Frameworks 未生效 |
| `Undefined symbols` | MPVKit wrapper 没有带齐依赖或模块导出不完整 |
| 播放黑屏 | Metal/MoltenVK 渲染上下文未正确绑定，需要根据 Actions 编译结果继续调 |

## 下一步

等 MPVKit 调试页能播放普通 `m3u8/mp4` 后，再把它接入主播放器 `PlayerViewsV2`，不要一开始直接替换现有 AVPlayer/VLC 播放链路。
