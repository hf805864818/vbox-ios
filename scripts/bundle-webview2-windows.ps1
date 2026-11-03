#!/usr/bin/env pwsh
# 随包内置 WebView2 固定版（Fixed Version）运行时，令百度取号离线可用。
#
# 背景：普通百度网盘取 bdstoken 依赖 WebView2 真实浏览器栈（对齐 iOS 的
# WKWebView「系统浏览器永远可用」语义），但 WebView2 是外部组件——精简系统 /
# 云电脑镜像可能未装 Edge WebView2 Evergreen 运行时，导致原生桥在环境检测
# 阶段即返回 ERROR_FILE_NOT_FOUND（「WebView2 运行时不可用」），取号全链路
# 归零。本脚本把 CI 构建机已就位的 WebView2 运行时复制为固定版，随安装包
# 分发（installer.iss 递归打包 Release\* 自动携带 webview2\ 子目录），用户
# 机器无需预装 Edge 即可离线加载。
#
# 流程（与 bundle-node-windows.ps1 同模式）：
#   1. 定位系统 Edge WebView2 Evergreen 安装目录下的最新版本子目录；
#   2. 复制为固定版到 `build/windows/x64/runner/<Config>/webview2/`；
#   3. 校验 msedgewebview2.exe 存在。
#
# 用法：pwsh scripts/bundle-webview2-windows.ps1 [-Config Debug|Release] [-OutDir <dir>]
param(
    [string]$Config = "Release",
    [string]$OutDir = ""
)

$ErrorActionPreference = "Stop"

$root = Split-Path $PSScriptRoot -Parent

# ── 目标目录（installer.iss 递归打包 Release\* 自动携带 webview2\）──
if (-not $OutDir) {
    $OutDir = Join-Path $root "build/windows/x64/runner/$Config"
}
if (-not (Test-Path $OutDir)) {
    throw "目标目录不存在：$OutDir（先 flutter build windows --$Config，或用 -OutDir 指定）"
}
$destDir = Join-Path $OutDir "webview2"

# 已就位且 msedgewebview2.exe 存在则跳过（幂等，避免重复复制 150MB+）
if (Test-Path (Join-Path $destDir "msedgewebview2.exe")) {
    Write-Host "✅ WebView2 固定版已就位，跳过（webview2/）"
    exit 0
}
New-Item -ItemType Directory -Force -Path $destDir | Out-Null

# ── 定位系统 Edge WebView2 Evergreen（windows-latest 预装；含用户级兜底）──
# Evergreen 按版本隔离目录：<root>\Application\<version>\，下面直接是
# msedgewebview2.exe + *.dll + locales/ 等，正是 Fixed Version 需要的结构。
$candidates = @(
    "${env:ProgramFiles(x86)}\Microsoft\EdgeWebView\Application",
    "$env:ProgramFiles\Microsoft\EdgeWebView\Application",
    "$env:LOCALAPPDATA\Microsoft\EdgeWebView\Application"
)
$runtimeRoot = $null
foreach ($c in $candidates) {
    if (Test-Path $c) { $runtimeRoot = $c; break }
}
if (-not $runtimeRoot) {
    # 兜底：部分精简 CI 镜像未预装 WebView2，用官方 Evergreen Bootstrapper
    # 静默安装到系统后重新探测（bootstrapper 仅 ~2MB，安装到 Program Files）。
    Write-Host "未找到系统 Edge WebView2，改用官方 Bootstrapper 静默安装…"
    $bootstrap = Join-Path $env:TEMP "MicrosoftEdgeWebView2Setup.exe"
    Invoke-WebRequest -Uri "https://go.microsoft.com/fwlink/p/?LinkId=2124703" `
        -OutFile $bootstrap
    Start-Process -FilePath $bootstrap -ArgumentList "/silent", "/install" -Wait
    foreach ($c in $candidates) {
        if (Test-Path $c) { $runtimeRoot = $c; break }
    }
    if (-not $runtimeRoot) {
        throw "WebView2 Bootstrapper 安装后仍未找到运行时目录（已尝试: $($candidates -join ' / ')）"
    }
}

# 取「含 msedgewebview2.exe」的最新版本子目录（Edge 版本号恒为四段 x.x.x.x）
$versionDir = Get-ChildItem -Path $runtimeRoot -Directory |
    Where-Object { Test-Path (Join-Path $_.FullName "msedgewebview2.exe") } |
    Sort-Object { [version]$_.Name } -Descending |
    Select-Object -First 1
if (-not $versionDir) {
    throw "系统 Edge WebView2 目录下无含 msedgewebview2.exe 的版本子目录：$runtimeRoot"
}
Write-Host "源运行时：$($versionDir.FullName)"

# ── 复制为固定版（排除安装器残留缓存，减小体积；保留运行时必需文件）──
$excludeDirs = @("Installer", "SetupMetrics")
$sourceRoot = $versionDir.FullName
Get-ChildItem -Path $sourceRoot -Force | ForEach-Object {
    $target = Join-Path $destDir $_.Name
    if ($_.PSIsContainer -and ($excludeDirs -contains $_.Name)) {
        return  # 跳过安装器缓存
    }
    Copy-Item -Path $_.FullName -Destination $target -Recurse -Force
}

# ── 校验 ──
if (-not (Test-Path (Join-Path $destDir "msedgewebview2.exe"))) {
    throw "复制后仍缺少 msedgewebview2.exe（源：$sourceRoot）"
}
$items = Get-ChildItem -Recurse -File $destDir
$count = ($items | Measure-Object).Count
$size = ($items | Measure-Object -Property Length -Sum).Sum
Write-Host ("✅ WebView2 固定版已随目录分发：webview2/（{0} 文件，{1} MB）" -f $count, [math]::Round($size / 1MB, 1))