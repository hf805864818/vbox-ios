#!/usr/bin/env pwsh
# 批次 Q · Q-03：获取 Windows JSC 运行时 DLL（JavaScriptCore + ICU + MSVC 运行时）。
#
# 来源：Playwright 持续重建的 WebKit Win64 产物
#   https://playwright.download.prss.microsoft.com/dbazure/download/playwright/builds/webkit/<rev>/webkit-win64.zip
# 背景（docs/评估_JSC_Windows可行性.md §2）：Apple 官方 WinCairo buildbot 已停
# （最后 Windows 包 2024-09），WebKit 当前唯一的 Windows 二进制来源是 Playwright。
# 其 zip 内的 JavaScriptCore.dll（32 MB，导出完整 JSC C API）运行时依赖
# icuin*/icuuc*（ICU）+ icudt*（ICU 数据）+ msvcp*/vcruntime*（MSVC 运行时）。
#
# 产物（不入 git，同 D28 libmpv 分发决策）：build/vbox-jsc/windows/vendor/
#   JavaScriptCore.dll / icudt*.dll / icuin*.dll / icuuc*.dll / msvcp*.dll / vcruntime*.dll
# 本脚本幂等；本地构建或 CI（build-jsc.yml / build-release-assets.yml）前置执行，
# build-jsc-windows.ps1 亦会内联调用本脚本。
#
# 用法：pwsh scripts/fetch-jsc-windows.ps1 [-Force]
# 环境变量：JSC_WINDOWS_WEBKIT_REV  覆盖 Playwright WebKit revision（默认自动解析）
param(
    [string]$Rev = $env:JSC_WINDOWS_WEBKIT_REV,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$root = Split-Path $PSScriptRoot -Parent
$vendor = Join-Path $root "build/vbox-jsc/windows/vendor"
$browsersUrl = "https://raw.githubusercontent.com/microsoft/playwright/main/packages/playwright-core/browsers.json"
$defaultRev = "2367"

# 幂等：JavaScriptCore.dll 已就位则退出（-Force 强制重取）
$jscDll = Join-Path $vendor "JavaScriptCore.dll"
if ((Test-Path $jscDll) -and -not $Force) {
    Write-Host "✅ Windows JSC 运行时已存在，跳过（-Force 强制重取）"
    exit 0
}

# 解析 revision：优先自动读 Playwright 官方 browsers.json，失败回退 pinned rev
if (-not $Rev) {
    try {
        $browsers = Invoke-RestMethod -Uri $browsersUrl -TimeoutSec 30
        $Rev = ($browsers.browsers | Where-Object { $_.name -eq "webkit" } |
                Select-Object -First 1).revision
    } catch {
        Write-Host "⚠️  解析 browsers.json 失败，回退默认 rev $defaultRev：$($_.Exception.Message)"
        $Rev = $defaultRev
    }
}
if (-not $Rev) { $Rev = $defaultRev }

$url = "https://playwright.download.prss.microsoft.com/dbazure/download/playwright/builds/webkit/$Rev/webkit-win64.zip"
New-Item -ItemType Directory -Force -Path $vendor | Out-Null

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("webkit-win64-" + [guid]::NewGuid().ToString("N") + ".zip")
try {
    Write-Host "⬇️  下载 Playwright WebKit JSC 运行时（rev $Rev）"
    & curl.exe -fsSL --retry 3 -o $work $url
    if ($LASTEXITCODE -ne 0) { throw "curl 下载失败：$url" }

    Write-Host "📦 提取 JSC + ICU + MSVC 运行时 DLL"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($work)
    try {
        $count = 0
        foreach ($entry in $zip.Entries) {
            $name = $entry.Name
            $match = ($name -eq "JavaScriptCore.dll") -or
                     ($name -like "icudt*.dll") -or
                     ($name -like "icuin*.dll") -or
                     ($name -like "icuuc*.dll") -or
                     ($name -like "msvcp*.dll") -or
                     ($name -like "vcruntime*.dll")
            if (-not $match) { continue }
            $dest = Join-Path $vendor $name
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
            $sizeMib = [math]::Round($entry.Length / 1MB, 2)
            Write-Host "  → vendor/$name（$sizeMib MB）"
            $count++
        }
        if ($count -eq 0) { throw "zip 中未找到任何 JSC/ICU/MSVC 运行时 DLL" }
    } finally {
        $zip.Dispose()
    }
} finally {
    if (Test-Path $work) { Remove-Item -Force $work }
}

Write-Host "✅ Windows JSC 运行时 DLL 就位：$vendor"