#!/usr/bin/env pwsh
# 批次 G-03-B：编译 quickjs/wrapper.c → vbox_quickjs.dll（Windows JS 引擎）。
#
# QuickJS 源码依赖 GCC 扩展（`__int128` / `__attribute__`，见 libbf.h / cutils.h），
# **MSVC 无法编译** → 用 MSYS2 mingw-w64 gcc（x86_64-w64-mingw32-gcc）。
# 复用跨端脚本 scripts/build_quickjs_wrapper.sh（其 `uname` 分支对 MINGW 产出 .dll）。
#
# 产物（build/vbox-quickjs/）：
#   vbox_quickjs.dll   wrapper（导出 vq_* 十一符号：同步 eval + worker/http 桥）
# 运行时依赖：mingw 侧 -static-libgcc + 静态 winpthread（见 build_quickjs_wrapper.sh），
# 无额外随之分发的 DLL；Dart 侧 DLL 名与 quickjs_ffi.dart 一致（vbox_quickjs.dll）。
#
# 前置（CI）：msys2/setup-msys2 提供 mingw-w64-x86_64-gcc；
# 或本机 MSYS2 默认安装（C:\msys64）。
#
# 用法：pwsh scripts/build-quickjs-windows.ps1 [-OutDir <dir>]
param(
    [string]$OutDir = ""
)

$ErrorActionPreference = "Stop"

$root = Split-Path $PSScriptRoot -Parent
if (-not $OutDir) {
    $OutDir = Join-Path $root "build/vbox-quickjs"
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# ── 定位 MSYS2 根（含 mingw-w64 gcc）──
# 关键：msys2/setup-msys2 把 MSYS2 解压到**动作私有目录**（如
# D:\a\_temp\setup-msys2\msys64），与镜像自带的 C:\msys64 **不是同一个根**（后者
# 无 gcc）—— 只按常见路径挑 bash 会挑到无 gcc 的根，报
# 「x86_64-w64-mingw32-gcc: command not found」。
# 优先级：① workflow 用 `shell: msys2 {0}` 探测并写入的 MSYS2_ROOT
# （cygpath -w /）；② PATH 里的 MSYS2 目录（usr\bin / mingw64\bin 的父目录）；
# ③ 常见位置；④ MSYS2_BASH 反推。
# 逐个校验「该根下存在 mingw64\bin\x86_64-w64-mingw32-gcc.exe」，命中即编译根。
function Test-MsysRoot([string]$r) {
    return [bool]($r) -and (Test-Path (Join-Path $r "mingw64\bin\x86_64-w64-mingw32-gcc.exe"))
}
$rootCandidates = New-Object System.Collections.Generic.List[string]
if ($env:MSYS2_ROOT) { $rootCandidates.Add($env:MSYS2_ROOT) }
foreach ($p in ($env:PATH -split ';')) {
    if (-not $p) { continue }
    if ($p.TrimEnd('\') -match '^(?<root>.+[\\/]msys64)[\\/](usr[\\/]bin|mingw64[\\/]bin)$') {
        $rootCandidates.Add($matches['root'])
    }
}
foreach ($c in @("C:\msys64", "C:\tools\msys64")) { $rootCandidates.Add($c) }
if ($env:MSYS2_BASH) {
    $rootCandidates.Add((Split-Path (Split-Path (Split-Path $env:MSYS2_BASH -Parent) -Parent) -Parent))
}
$msysRoot = $null
foreach ($r in $rootCandidates) {
    if (Test-MsysRoot $r) { $msysRoot = $r; break }
}
if (-not $msysRoot) {
    $uniq = (@($rootCandidates) | Select-Object -Unique) -join '; '
    throw "未找到含 mingw-w64 gcc 的 MSYS2 根（候选：$uniq）。CI 需 msys2/setup-msys2 安装 mingw-w64-x86_64-gcc，并在其前用 ``shell: msys2 {0}`` 步骤写入 MSYS2_ROOT。"
}
$bash = Join-Path $msysRoot "usr\bin\bash.exe"
Write-Host "🧰 MSYS2 根：$msysRoot"

# Windows 路径 → MSYS2 POSIX 路径（C:\a\b → /c/a/b）
function ConvertTo-MsysPath([string]$p) {
    $q = $p -replace '\\', '/'
    if ($q -match '^([A-Za-z]):(.*)$') { return "/" + $matches[1].ToLower() + $matches[2] }
    return $q
}
$rootPosix = ConvertTo-MsysPath $root
$outPosix = ConvertTo-MsysPath $OutDir
$msysRootPosix = ConvertTo-MsysPath $msysRoot

Write-Host "🏗️  编译 vbox_quickjs.dll（mingw-w64 gcc）"
# 注意（两处转义坑）：
#   1) PowerShell 双引号串内转义 `$` 须用**反引号**（`` `$ ``），反斜杠无效 ——
#      原 `\$PATH` 会被解析为字面 `\` + 展开空变量 → bash 收到
#      `export PATH=/mingw64/bin:\; cd '...'`（`\;` 吞掉分号）→
#      报「export: '/d/a/...': not a valid identifier」。
#   2) MSYS2 PATH 项可能含空格（如 `/c/Program Files/...`），故 PATH 赋值整体加
#      双引号（PowerShell 侧写作 `` `" ``）。
# MSYSTEM=MINGW64 + 显式前置该根下的 mingw64/bin：避免 login shell 的 profile
# 在非 MINGW64 会话下不注入工具链路径。
& $bash -lc "set -euo pipefail; export MSYSTEM=MINGW64; export PATH=`"$msysRootPosix/mingw64/bin:$msysRootPosix/usr/bin:`$PATH`"; cd '$rootPosix'; CC=x86_64-w64-mingw32-gcc bash scripts/build_quickjs_wrapper.sh '$outPosix'"
if ($LASTEXITCODE -ne 0) { throw "build_quickjs_wrapper.sh 失败（$LASTEXITCODE）" }

# Dart 侧 quickjs_ffi.dart 按 Windows 约定加载 `vbox_quickjs.dll`（无 lib 前缀）
$built = Join-Path $OutDir "libvbox_quickjs.dll"
$dll = Join-Path $OutDir "vbox_quickjs.dll"
if (-not (Test-Path $built)) { throw "未产出 $built" }
Move-Item -Force $built $dll

# ── 符号级冒烟：vq_* 十一导出（同步 + 宿主桥）──
Write-Host "🔎 符号校验（vq_* 十一导出）"
$symList = @(
    "vq_create_runtime", "vq_create_context", "vq_free_runtime", "vq_free_context",
    "vq_eval", "vq_free_string", "vq_free_buffer", "vq_set_host_bridge",
    "vq_eval_submit", "vq_eval_take_result", "vq_http_complete"
)
# 经 MSYS2 bash 调 nm：复用与编译**完全相同**的 PATH。
# 关键：MSYS2 的 mingw-w64 binutils 里 nm **没有 target 前缀**（就是
# /mingw64/bin/nm.exe），与 gcc 包提供的驱动程序 x86_64-w64-mingw32-gcc 不同 ——
# 写死 x86_64-w64-mingw32-nm 会 command not found（前几轮即踩此坑）。故在
# mingw64/bin 就位后按候选表探测：优先带前缀名（部分环境提供符号链接），
# 回退裸名 nm，命中即用。
$dllPosix = ConvertTo-MsysPath $dll
$symScript = @"
export MSYSTEM=MINGW64
export PATH="$msysRootPosix/mingw64/bin:$msysRootPosix/usr/bin:`$PATH"
for c in x86_64-w64-mingw32-nm nm; do
  if command -v "`$c" >/dev/null 2>&1; then "`$c" -g --defined-only "$dllPosix"; exit 0; fi
done
echo "__NO_NM__" >&2
exit 127
"@
$exports = (& $bash -lc $symScript 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0) { throw "符号校验失败：MSYS2 内未找到可用 nm（mingw-w64 binutils）。原始输出：$exports" }
$missing = @()
foreach ($sym in $symList) {
    if ($exports -notmatch ("\b" + [regex]::Escape($sym) + "\b")) { $missing += $sym }
}
if ($missing.Count -gt 0) { throw "缺导出符号：$($missing -join ', ')" }
$sizeMB = [math]::Round((Get-Item $dll).Length / 1MB, 2)
Write-Host "✅ vq_* 十一符号 ✓ · vbox_quickjs.dll（$sizeMB MB）"