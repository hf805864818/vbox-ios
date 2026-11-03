#!/usr/bin/env pwsh
# ND-02-desktop：把内置 CPython（python-build-standalone）+ lxml + 纯 py 依赖
# 随 Windows release 目录分发，让桌面端 `.py`（Python 蜘蛛）源可用。
#   1. 下载固定版本 pbs install_only（.python-cache 缓存 + sha256 校验）；
#   2. 解压 python/ → <OutDir>/pyruntime/（python.exe + Lib/ + DLLs/）；
#   3. pip 安装 lxml（官方 cp314 wheel，免编译）；
#   4. 拷 assets/python-stdlib → pyruntime/python-stdlib（base/ + requests 栈，
#      运行时经 PYTHONPATH 注入；桥接脚本已内嵌 Dart，无需 pythonbridge）；
#   5. 裁剪 tkinter/idlelib/turtledemo/ensurepip/tcl/__pycache__/*.pdb 减小体积；
#   6. 冒烟：python.exe 校验解释器 + lxml + base.spider 可导入。
# 用法：pwsh scripts/bundle-python-windows.ps1 [-Config Debug|Release] [-OutDir <dir>]
param([string]$Config = "Release", [string]$OutDir = "")
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent

# ── 锚定 python-build-standalone（astral-sh）tag 20261009 / CPython 3.14.8 ──
# （对齐 iOS 3.14.x；该 tag 内 3.14 仅有 3.14.8，见方案 §3.1 / R2）
$PbsTag = "20261009"
$PythonVersion = "3.14.8"
$Target = "x86_64-pc-windows-msvc"
$Asset = "cpython-$PythonVersion+$PbsTag-$Target-install_only.tar.gz"
$ExpectedSha256 = "6c03535bfa5888dd73b0c0ebd91b76a2fdfa06eedaa411b0c4c9e664db6b4bb4"
# lxml 版本：**不能沿用 iOS 的 5.4.0** —— 5.4.0 仅发到 cp313，CPython 3.14 无 wheel，
# pip 会退化为源码编译并因缺 libxml2 头文件失败；6.0.1 起才提供 cp314 wheel。
$LxmlVersion = "6.1.3"

$cacheDir = Join-Path $root ".python-cache"
New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
$tarball = Join-Path $cacheDir $Asset
if (Test-Path $tarball) {
    $actual = (Get-FileHash -Algorithm SHA256 $tarball).Hash.ToLowerInvariant()
    if ($actual -ne $ExpectedSha256) { Remove-Item -Force $tarball }
}
if (-not (Test-Path $tarball)) {
    $url = "https://github.com/astral-sh/python-build-standalone/releases/download/$PbsTag/$Asset"
    Write-Host "⬇️  下载 $url（内置 CPython，ND-02-desktop）"
    Invoke-WebRequest -Uri $url -OutFile $tarball -UseBasicParsing
}
$actual = (Get-FileHash -Algorithm SHA256 $tarball).Hash.ToLowerInvariant()
if ($actual -ne $ExpectedSha256) { throw "sha256 校验失败：期望 $ExpectedSha256，实际 $actual" }
Write-Host "✅ sha256 校验通过: $actual"

if (-not $OutDir) { $OutDir = Join-Path $root "build/windows/x64/runner/$Config" }
if (-not (Test-Path $OutDir)) { throw "目标目录不存在：$OutDir（先 flutter build windows --$Config，或用 -OutDir 指定）" }

$extract = Join-Path $cacheDir "extract-$PythonVersion"
if (Test-Path $extract) { Remove-Item -Recurse -Force $extract }
New-Item -ItemType Directory -Force -Path $extract | Out-Null
tar -xzf $tarball -C $extract
if ($LASTEXITCODE -ne 0) { throw "解压失败（exit=$LASTEXITCODE）" }
$pythonSrc = Join-Path $extract "python"
if (-not (Test-Path (Join-Path $pythonSrc "python.exe"))) { throw "tar 包内未找到 python/python.exe" }

$runtimeDir = Join-Path $OutDir "pyruntime"
if (Test-Path $runtimeDir) { Remove-Item -Recurse -Force $runtimeDir }
Copy-Item -Recurse -Force $pythonSrc $runtimeDir
$pythonExe = Join-Path $runtimeDir "python.exe"

Write-Host "📦 pip 安装 lxml==$LxmlVersion"
& $pythonExe -m pip install --no-cache-dir --no-warn-script-location --disable-pip-version-check --only-binary=:all: "lxml==$LxmlVersion"
if ($LASTEXITCODE -ne 0) { throw "pip 安装 lxml 失败（exit=$LASTEXITCODE）" }

$stdlibSrc = Join-Path $root "assets/python-stdlib"
if (-not (Test-Path $stdlibSrc)) { throw "未找到 $stdlibSrc（先落盘 assets/python-stdlib）" }
$stdlibDst = Join-Path $runtimeDir "python-stdlib"
Copy-Item -Recurse -Force $stdlibSrc $stdlibDst

# 裁剪：tkinter 系（tkinter/idlelib/turtledemo/tcl）+ ensurepip + 缓存/调试符号
$trimDirs = @("Lib\tkinter", "Lib\idlelib", "Lib\turtledemo", "Lib\ensurepip", "tcl")
foreach ($d in $trimDirs) {
    $p = Join-Path $runtimeDir $d
    if (Test-Path $p) { Remove-Item -Recurse -Force $p }
}
Get-ChildItem -Path $runtimeDir -Recurse -Directory -Filter "__pycache__" -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $runtimeDir -Recurse -File -Include "*.pdb", "*.pyc" -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

$smoke = & $pythonExe -c "import sys, lxml.etree; print('PYOK', sys.version_info[:3])"
if ("$smoke" -notmatch "PYOK") { throw "python 冒烟失败：$smoke" }
Write-Host "✅ python 冒烟通过（$smoke）"
$env:PYTHONPATH = $stdlibDst
$smoke2 = & $pythonExe -c "import base.spider; print('BASEOK')"
if ("$smoke2" -notmatch "BASEOK") { throw "base.spider 冒烟失败：$smoke2" }
Write-Host "✅ base.spider 冒烟通过（PYTHONPATH=pyruntime/python-stdlib）"

$size = (Get-ChildItem -Recurse -File $runtimeDir | Measure-Object -Property Length -Sum).Sum
Write-Host ("✅ 内置 CPython 已随目录分发：pyruntime/（{0} MB）" -f [math]::Round($size / 1MB, 1))
