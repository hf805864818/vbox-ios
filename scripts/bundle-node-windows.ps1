#!/usr/bin/env pwsh
# ND-02-desktop：把 Node 引擎（node.exe）随 Windows release 目录分发。
#
# 对齐 iOS「引擎随包内置、零外部依赖」语义：桌面端 ProcessNodeHost 探测链
# ② `<exeDir>/noderuntime/node.exe` 是为随包内置预留的落点（见
# lib/platform/node/node_host.dart），本脚本把 nodejs.org 官方 x64 引擎
# 拷入该落点 → 用户免装 Node.js，Node 常驻系统开箱即用。
#
# 流程（与 bundle-libmpv-windows.ps1 同模式）：
#   1. 下载固定版本官方 node.exe（.node-cache 缓存 + sha256 校验）；
#   2. 拷入 `build/windows/x64/runner/<Config>/noderuntime/node.exe`
#      （installer.iss 递归打包 Release\* 自动携带）；
#   3. 冒烟：`node.exe -p "21*2"` 期望输出 42。
#
# 用法：pwsh scripts/bundle-node-windows.ps1 [-Config Debug|Release] [-OutDir <dir>]
param(
    [string]$Config = "Release",
    [string]$OutDir = ""
)

$ErrorActionPreference = "Stop"

$root = Split-Path $PSScriptRoot -Parent

# ── 引擎版本（固定 LTS + 官方 SHASUMS256 登记值）──
$NodeVersion = "v22.14.0"
$ExpectedSha256 = "33b1bc1a8aca11fd5a4f2699e51019c63c0af30cf437701d07af69be7706771b"

$cacheDir = Join-Path $root ".node-cache"
New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
$downloaded = Join-Path $cacheDir "node-$NodeVersion-win-x64.exe"

# ── 下载（已缓存且校验通过则复用）──
if (Test-Path $downloaded) {
    $actual = (Get-FileHash -Algorithm SHA256 $downloaded).Hash.ToLowerInvariant()
    if ($actual -ne $ExpectedSha256) {
        Remove-Item -Force $downloaded
    }
}
if (-not (Test-Path $downloaded)) {
    $url = "https://nodejs.org/dist/$NodeVersion/win-x64/node.exe"
    Write-Host "⬇️  下载 $url（ND-02-desktop 引擎内置）"
    Invoke-WebRequest -Uri $url -OutFile $downloaded -UseBasicParsing
}
$actual = (Get-FileHash -Algorithm SHA256 $downloaded).Hash.ToLowerInvariant()
if ($actual -ne $ExpectedSha256) {
    throw "sha256 校验失败：期望 $ExpectedSha256，实际 $actual"
}
Write-Host "✅ sha256 校验通过: $actual"

# ── 目标目录 ──
if (-not $OutDir) {
    $OutDir = Join-Path $root "build/windows/x64/runner/$Config"
}
if (-not (Test-Path $OutDir)) {
    throw "目标目录不存在：$OutDir（先 flutter build windows --$Config，或用 -OutDir 指定）"
}
$runtimeDir = Join-Path $OutDir "noderuntime"
New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null

# ── 拷入 noderuntime/node.exe（探测链 ② 落点）──
Copy-Item -Force $downloaded (Join-Path $runtimeDir "node.exe")
$size = (Get-Item (Join-Path $runtimeDir "node.exe")).Length
Write-Host ("✅ Node 引擎已随目录分发：noderuntime/node.exe（{0} MB）" -f [math]::Round($size / 1MB, 1))

# ── 冒烟 ──
$smoke = & (Join-Path $runtimeDir "node.exe") -p "21*2"
if ("$smoke" -ne "42") {
    throw "node.exe 冒烟失败：21*2 → '$smoke'（期望 42）"
}
Write-Host "✅ node.exe 冒烟通过（21*2 → 42）"
