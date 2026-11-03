#!/usr/bin/env pwsh
# 批次 Q · Q-03：把 vbox_jsc.dll + 运行时 DLL 拷入 Flutter Windows 构建目录。
#
# 目标目录与 runner.exe 同目录（Windows 默认按应用程序目录搜索 DLL），
# 安装包（windows/installer/installer.iss 递归打包 Release\*）自动携带，
# 对齐 D28 libmpv-windows-*.dll 的随包分发模式。
#
# 先调用 build-jsc-windows.ps1（fetch + MSVC 编译 + 冒烟），再把
#   vbox_jsc.dll + vendor/*.dll
# 拷入 build/windows/x64/runner/<Config>/。
#
# 用法：pwsh scripts/bundle-jsc-windows.ps1 [-Config Debug|Release] [-OutDir <dir>]
#   -Config  Flutter 构建配置（默认 Release）；-OutDir 显式目标目录（跳过自动定位）
param(
    [string]$Config = "Release",
    [string]$OutDir = ""
)

$ErrorActionPreference = "Stop"

$root = Split-Path $PSScriptRoot -Parent
$build = Join-Path $root "build/vbox-jsc/windows"
$vendor = Join-Path $build "vendor"
$dll = Join-Path $build "vbox_jsc.dll"

# 构建（fetch + MSVC 编译 vbox_jsc.dll + 冒烟）
& (Join-Path $PSScriptRoot "build-jsc-windows.ps1")
if ($LASTEXITCODE -ne 0) { throw "build-jsc-windows.ps1 失败" }

if (-not $OutDir) {
    $OutDir = Join-Path $root "build/windows/x64/runner/$Config"
}
if (-not (Test-Path $OutDir)) {
    throw "目标目录不存在：$OutDir（先 flutter build windows --$Config，或用 -OutDir 指定）"
}

Write-Host "📋 拷贝 JSC 引擎到 $OutDir"
$total = 0
Copy-Item -Force $dll $OutDir
$total += (Get-Item $dll).Length
Get-ChildItem -Path $vendor -Filter *.dll | ForEach-Object {
    Copy-Item -Force $_.FullName (Join-Path $OutDir $_.Name)
    $total += $_.Length
}
Write-Host ("✅ JSC 引擎已随目录分发，运行时体积合计约 {0} MB" -f [math]::Round($total / 1MB, 1))