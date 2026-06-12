# feature/mpvkit-link-validation

这个分支用来验证 `MPVKit.xcframework` + 8 个核心依赖在 CI 上能否被正确 Link/Embed，并通过 archive 不闪退。
**整条链路全脚本化，因为本地无 Xcode。**

## 3.150 已完成

```text
1. FRAMEWORK_SEARCH_PATHS 追加 vbox/Libraries/MPV/MPVKitDependencies
2. MPVKitBackend 加 canImport(MPVKit) 软探针，输出 MPVKit-imported / MPVKit-missing
3. MPVIntegrationStatus.moduleProbeResult 桥接给上层调试位
4. scripts/configure_mpvkit_link.rb 用 xcodeproj gem 在 CI 中临时注入 Link + Embed
5. .github/workflows/build-ipa-debug.yml 在 archive 前依次执行：
     fetch_mpv_dependencies.sh → check → configure_mpvkit_link.rb → pod install → archive
```

## 关键设计

```text
1. main 的 vbox.xcodeproj/project.pbxproj 不包含 9 个 framework 的 Link/Embed 引用
2. CI 在每次构建时由 Ruby 脚本"临时"注入，构建后丢弃
3. 验证通过后，再考虑是否把 Link/Embed 固化进 main 的 pbxproj
4. configure_mpvkit_link.rb 是幂等的，可重复执行
```

## 注入清单

```text
MPVKit.xcframework
MPVKitDependencies/Libmpv.xcframework
MPVKitDependencies/Libavcodec.xcframework
MPVKitDependencies/Libavdevice.xcframework
MPVKitDependencies/Libavfilter.xcframework
MPVKitDependencies/Libavformat.xcframework
MPVKitDependencies/Libavutil.xcframework
MPVKitDependencies/Libswresample.xcframework
MPVKitDependencies/Libswscale.xcframework
```

不包含 `Freedom/` 目录任何文件。

## CI 验证流程

```text
1. 推送本分支到 GitHub
2. Actions 页面手动触发 "Build IPA (Debug)"
3. 关键观察点：
   - 步骤 🎬 Fetch MPVKit dependencies 是否通过
   - 步骤 🔗 Inject MPVKit Link & Embed 是否输出"已注入 Link + Embed: ..."
   - 步骤 🏗️ Build with Verbose Output 是否成功
   - build.log 是否出现 MPVKit / Libmpv 相关的 link / dyld 错误
```

## 验证结果分流

| 结果 | 后续动作 |
|---|---|
| archive 成功，无链接错误 | 准备 3.151，固化 Link/Embed 进 main 或保留 CI 注入 |
| 链接错误 (Undefined symbols) | 在 configure_mpvkit_link.rb 调整顺序/系统 framework |
| dyld 加载错误 | 收集 archive 后产物，回到依赖排查 |

## 不在本分支做的事

```text
1. PlayerViewsV2 主播放链路改造
2. 切片资源、网盘资源播放
3. 弹幕系统
4. 播放器 UI 重构
5. Freedom/ 自由度独立内核
6. 真实 mpv_handle 创建
```
