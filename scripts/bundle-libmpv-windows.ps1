#!/usr/bin/env pwsh
# 批次 C · C-11：把 libmpv 运行时（mpv-2.dll + 其硬依赖 vulkan-1.dll）拷入
# Flutter Windows 构建目录。
#
# 对齐 D28（scripts/fetch_libmpv.sh + libmpv_external_dependencies.json）：
#   · Windows 资产为单一自包含 dll：libmpv-windows-x86_64-0.0.1.dll
#     （GitHub Release q2787244398/vbox-deps@libmpv-deps-0.0.1，直链免鉴权）；
#   · 拉取校验后改名 mpv-2.dll（libmpv 标准运行库名，player_plugin.cpp
#     LoadLibraryW("mpv-2.dll") 的解析目标）拷入 runner.exe 同目录；
#   · 随包分发（Windows 默认按应用目录搜索 DLL），安装包
#     windows/installer/installer.iss 递归打包 Release\* 自动携带，
#     （同 bundle-jsc-windows.ps1 的 vbox_jsc.dll 分发模式）。
#
# 用法：pwsh scripts/bundle-libmpv-windows.ps1 [-Config Debug|Release] [-OutDir <dir>]
#   -Config  Flutter 构建配置（默认 Release）；-OutDir 显式目标目录（跳过自动定位）
param(
    [string]$Config = "Release",
    [string]$OutDir = ""
)

$ErrorActionPreference = "Stop"

$root = Split-Path $PSScriptRoot -Parent

# ── 资产定位（D28 登记表 libmpv_external_dependencies.json 的唯一真相源）──
$registry = Get-Content (Join-Path $PSScriptRoot "libmpv_external_dependencies.json") -Raw | ConvertFrom-Json
$asset = $registry.assets | Where-Object { $_.os -eq "windows" -and $_.arch -eq "x86_64" } | Select-Object -First 1
if (-not $asset) { throw "libmpv_external_dependencies.json 缺 windows/x86_64 资产登记" }

$ver = $registry.version
$repo = "q2787244398/vbox-deps"
$tag = "libmpv-deps-0.0.1"
$assetName = $asset.file
$expectedSha256 = $asset.sha256

$cacheDir = Join-Path $root ".mpv-cache"
New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
$downloaded = Join-Path $cacheDir $assetName
$targetName = "mpv-2.dll"

# ── 下载（已缓存且校验通过则复用）──
if (Test-Path $downloaded) {
    $actual = (Get-FileHash -Algorithm SHA256 $downloaded).Hash.ToLowerInvariant()
    if ($expectedSha256 -and $actual -ne $expectedSha256.ToLowerInvariant()) {
        Remove-Item -Force $downloaded
    }
}
if (-not (Test-Path $downloaded)) {
    $url = "https://github.com/$repo/releases/download/$tag/$assetName"
    Write-Host "⬇️  下载 $assetName（D28）"
    Invoke-WebRequest -Uri $url -OutFile $downloaded -UseBasicParsing
}
$actual = (Get-FileHash -Algorithm SHA256 $downloaded).Hash.ToLowerInvariant()
if ($expectedSha256 -and $actual -ne $expectedSha256.ToLowerInvariant()) {
    throw "sha256 校验失败：期望 $expectedSha256，实际 $actual"
}
Write-Host "✅ sha256 校验通过: $actual"

# ── 目标目录 ──
if (-not $OutDir) {
    $OutDir = Join-Path $root "build/windows/x64/runner/$Config"
}
if (-not (Test-Path $OutDir)) {
    throw "目标目录不存在：$OutDir（先 flutter build windows --$Config，或用 -OutDir 指定）"
}

# ── 改名拷入 runner 同目录 ──
Copy-Item -Force $downloaded (Join-Path $OutDir $targetName)
$size = (Get-Item (Join-Path $OutDir $targetName)).Length
Write-Host ("✅ libmpv 已随目录分发：{0}（{1} MB）" -f $targetName, [math]::Round($size / 1MB, 1))

# ── vulkan-1.dll：mpv-2.dll 的硬依赖（GPU 驱动安装，非系统保证预装）──
# 无独显驱动 / 虚拟机缺失该 loader → LoadLibraryW("mpv-2.dll") 报 ERROR_MOD_NOT_FOUND
# → 桌面端大量视频播不出（E_BACKEND_UNAVAILABLE）。随包分发 LunarG Vulkan Runtime
# 内的 x64 vulkan-1.dll，与 mpv-2.dll 同目录（exe 目录属默认 DLL 搜索路径）。
$vk = $registry.windows_vulkan_loader
if (-not $vk) { throw "libmpv_external_dependencies.json 缺 windows_vulkan_loader 登记" }

$vkZip = Join-Path $cacheDir $vk.file
if (Test-Path $vkZip) {
    $z = (Get-FileHash -Algorithm SHA256 $vkZip).Hash.ToLowerInvariant()
    if ($vk.sha256_zip -and $z -ne $vk.sha256_zip.ToLowerInvariant()) { Remove-Item -Force $vkZip }
}
if (-not (Test-Path $vkZip)) {
    Write-Host "⬇️  下载 Vulkan Runtime 组件（$($vk.version)）"
    Invoke-WebRequest -Uri $vk.url -OutFile $vkZip -UseBasicParsing
}
$z = (Get-FileHash -Algorithm SHA256 $vkZip).Hash.ToLowerInvariant()
if ($vk.sha256_zip -and $z -ne $vk.sha256_zip.ToLowerInvariant()) {
    throw "Vulkan Runtime zip sha256 校验失败：期望 $($vk.sha256_zip)，实际 $z"
}
Write-Host "✅ Vulkan Runtime zip sha256 校验通过: $z"

$vkDir = Join-Path $cacheDir "vulkan-loader"
if (Test-Path $vkDir) { Remove-Item -Recurse -Force $vkDir }
Expand-Archive -Path $vkZip -DestinationPath $vkDir -Force
# 官方 zip 内路径带版本号（VulkanRT-X64-<ver>-Components/x64/vulkan-1.dll），按 glob 定位
$vkDll = Get-ChildItem -Path $vkDir -Recurse -Filter "vulkan-1.dll" |
    Where-Object { $_.FullName -match '[\\/]x64[\\/]' } | Select-Object -First 1
if (-not $vkDll) { throw "Vulkan Runtime zip 内未找到 x64/vulkan-1.dll" }
$vd = (Get-FileHash -Algorithm SHA256 $vkDll.FullName).Hash.ToLowerInvariant()
if ($vk.sha256_dll -and $vd -ne $vk.sha256_dll.ToLowerInvariant()) {
    throw "vulkan-1.dll sha256 校验失败：期望 $($vk.sha256_dll)，实际 $vd"
}
Copy-Item -Force $vkDll.FullName (Join-Path $OutDir "vulkan-1.dll")
$vsize = (Get-Item (Join-Path $OutDir "vulkan-1.dll")).Length
Write-Host ("✅ vulkan-1.dll 已随目录分发（{0} MB，mpv-2.dll 硬依赖）" -f [math]::Round($vsize / 1MB, 2))
