# vbox MPVKit.xcframework

基于 Myapp3.1 (TVBox 架构) 逆向分析的 iOS 移植版本。

## 架构

```
┌──────────────────────────────────────┐
MPVKit.xcframework 下载地址
```

## GitHub Actions 自动构建

本分支的 `.github/workflows/mpv-build.yml` 会在 `rebuild-8db3547` 分支 push 时自动运行。

默认构建：

```text
来源：https://github.com/mpvkit/MPVKit.git
分支：main
产品：MPVKit
平台：iOS 真机 + iOS Simulator
产物：MPVKit.xcframework.zip
```

构建流程：

```text
1. 克隆 mpvkit/MPVKit
2. 生成本地 MPVKit wrapper Swift Package
3. wrapper 内部 @_exported import _MPVKit
4. archive iOS 真机 MPVKit.framework
5. archive iOS Simulator MPVKit.framework
6. xcodebuild -create-xcframework 合成 MPVKit.xcframework
7. 上传 MPVKit.xcframework.zip artifact
```

如果需要手动运行，可以在 Actions 里选择：

```text
Build MPVKit.xcframework
```

参数：

```text
mpvkit_ref = main
product = MPVKit
publish_release = false
```
