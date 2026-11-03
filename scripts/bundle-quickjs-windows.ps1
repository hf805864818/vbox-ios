#!/usr/bin/env pwsh
# 批次 G-03-B：把 vbox_quickjs.dll 拷入 Flutter Windows 构建目录（随安装包分发）。
#
# 目标目录与 runner.exe 同目录（Windows 默认按应用程序目录搜索 DLL），
# 安装包（windows/installer/installer.iss 递归打包 Release\*）自动携带，
# 对齐 bundle-jsc-windows.ps1 / bundle-libmpv-windows.ps1 的随包分发模式。
#
# 先调用 build-quickjs-windows.ps1（mingw 编译 + 符号冒烟），再把
#   vbox_quickjs.dll
# 拷入 build/windows/x64/runner/<Config>/（Dart FFI 命中，见 quickjs_ffi.dart）。
#
# 用法：pwsh scripts/bundle-quickjs-windows.ps1 [-Config Debug|Release] [-OutDir <dir>]
param(
    [string]$Config = "Release",
    [string]$OutDir = ""
)

$ErrorActionPreference = "Stop"

$root = Split-Path $PSScriptRoot -Parent
$build = Join-Path $root "build/vbox-quickjs"
$dll = Join-Path $build "vbox_quickjs.dll"

& (Join-Path $PSScriptRoot "build-quickjs-windows.ps1")
if ($LASTEXITCODE -ne 0) { throw "build-quickjs-windows.ps1 失败" }

if (-not $OutDir) {
    $OutDir = Join-Path $root "build/windows/x64/runner/$Config"
}
if (-not (Test-Path $OutDir)) {
    throw "目标目录不存在：$OutDir（先 flutter build windows --$Config，或用 -OutDir 指定）"
}

Copy-Item -Force $dll $OutDir
$sizeMB = [math]::Round((Get-Item $dll).Length / 1MB, 2)
Write-Host "✅ QuickJS 引擎已随目录分发：vbox_quickjs.dll（$sizeMB MB）"