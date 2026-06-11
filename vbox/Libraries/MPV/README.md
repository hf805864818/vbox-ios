# MPV framework 放置说明

这个目录用于放置后续接入的 MPV 相关 `.xcframework`。

## 推荐文件

优先放置：

```text
vbox/Libraries/MPV/MPVKit.xcframework
```

后续如果要接“自由度”内核，再放置：

```text
vbox/Libraries/MPV/libmpv.xcframework
```

## UI 命名

```text
MPV    = MPVKit.xcframework
自由度 = libmpv.xcframework
```

## 架构要求

必须包含：

```text
ios-arm64
```

推荐包含：

```text
ios-arm64-simulator
```

如果 framework 不支持模拟器，可以先只用真机测试。

## 接入规则

在真实 framework 放入本目录之前，不要提前把不存在的 framework 加入 Xcode 的 `Link Binary With Libraries` 或 `Embed Frameworks`，否则 GitHub Actions 可能会因为找不到文件而失败。

真实接入时需要确认：

```text
1. framework 的模块名
2. Info.plist 支持的架构 slice
3. 是否需要 Embed & Sign
4. 是否需要额外系统 Framework
5. GitHub Actions 是否能获取 framework
```

## 体积建议

如果 `.xcframework` 很大，建议使用 Git LFS 或构建时从 Release 下载，不建议直接普通提交超大二进制。

## 冲突提醒

不要随意同时放入多个都内置 FFmpeg/libmpv 的大型 framework。`MPVKit.xcframework` 可能已经包含 `libmpv` 和 FFmpeg，如果再同时接入 `libmpv.xcframework`，可能出现重复符号或运行时冲突。需要确认无冲突后再同时启用。
