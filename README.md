# vbox - iOS 聚合视频播放器(自用)

基于 Myapp3.1 (TVBox 架构) 逆向分析的 iOS 移植版本。

## 架构

```
┌──────────────────────────────────────┐
│  SwiftUI Views                       │
│  首页 / 搜索 / 详情 / 播放器 / 设置   │
├──────────────────────────────────────┤
│  SpiderRepository (多站点聚合搜索)    │
├──────────────────────────────────────┤
│  JSSpiderEngine (JavaScriptCore)     │
│  ├─ cheerio.min.js (HTML解析)        │
│  ├─ crypto-js.js (加密)              │
│  ├─ 模板.js (TVBox站点模板)          │
│  └─ 蜘蛛脚本 (用户配置)              │
├──────────────────────────────────────┤
│  JSHTTPBridge (原生HTTP桥接)         │
│  AVPlayer (视频播放)                 │
└──────────────────────────────────────┘
```

## GitHub Actions 自动编译

每次 push 到 `main` 分支，GitHub Actions 自动编译出 `.ipa`：

1. Push 代码到 GitHub
2. 打开仓库 → Actions 页面
3. 找到最新一次运行
4. 下载 **vbox-ipa** 工件 → `vbox.ipa`
5. 用 TrollStore 打开安装

## 手动触发编译

在 GitHub Actions 页面点 **Run workflow** 按钮也可手动触发编译。

## 技术栈

- Swift 5 / SwiftUI
- JavaScriptCore (JS引擎)
- AVFoundation (视频播放)
- iOS 15.0+
- arm64 (巨魔)
