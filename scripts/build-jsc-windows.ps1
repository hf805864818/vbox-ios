#!/usr/bin/env pwsh
# 批次 Q · Q-03：MSVC 编译 jsc/wrapper.c → vbox_jsc.dll（Windows JSC 主引擎）。
#
# 前置：cl.exe / lib.exe / dumpbin.exe 已在 PATH（CI 由 ilammy/msvc-dev-cmd 提供）。
# 产物（build/vbox-jsc/windows/）：
#   vbox_jsc.dll        wrapper，仅导出 vj_* 六符号，链 JavaScriptCore.lib
#   JavaScriptCore.lib  由 windows/runner/jsc/JavaScriptCore.def 重建的导入库
#   smoke_test.exe      语义冒烟（eval / 异常前缀 / 生命周期，静态链 wrapper.c）
# 运行时依赖（vendor/，由 fetch-jsc-windows.ps1 就位，不入 git）：
#   JavaScriptCore.dll + icudt*/icuin*/icuuc*（ICU）+ msvcp*/vcruntime*（MSVC 运行时）
#
# 语义对齐 macOS（build-jsc-macos.sh）与 Android（jni/CMakeLists.txt）的 vj_* ABI。
#
# 用法：pwsh scripts/build-jsc-windows.ps1
$ErrorActionPreference = "Stop"

$root = Split-Path $PSScriptRoot -Parent
$build = Join-Path $root "build/vbox-jsc/windows"
$vendor = Join-Path $build "vendor"
$def = Join-Path $root "windows/runner/jsc/JavaScriptCore.def"
$inc = Join-Path $root "jsc/include"
$symList = @("vj_create_runtime", "vj_create_context", "vj_free_runtime",
             "vj_free_context", "vj_eval", "vj_free_string")

# ① 就位 vendor DLL（幂等）
& (Join-Path $PSScriptRoot "fetch-jsc-windows.ps1")
if ($LASTEXITCODE -ne 0) { throw "fetch-jsc-windows.ps1 失败" }
if (-not (Test-Path (Join-Path $vendor "JavaScriptCore.dll"))) {
    throw "缺 $(Join-Path $vendor 'JavaScriptCore.dll')"
}

New-Item -ItemType Directory -Force -Path $build | Out-Null
Push-Location $build
try {
    # ② 生成导入库（Playwright 的 JavaScriptCore.dll 未附 .lib）
    Write-Host "🔗 生成导入库 JavaScriptCore.lib"
    & lib.exe /nologo "/def:$def" /machine:x64 /out:JavaScriptCore.lib
    if ($LASTEXITCODE -ne 0) { throw "lib.exe 生成导入库失败" }

    # ③ 编译 vbox_jsc.dll（/LD 动态库；wrapper.h 的 VJ_EXPORT=__declspec(dllexport) 导出 vj_*）
    Write-Host "🏗️  编译 vbox_jsc.dll"
    & cl.exe /nologo /utf-8 /O2 /LD "/I$inc" "$root\jsc\wrapper.c" `
        /link /OUT:vbox_jsc.dll JavaScriptCore.lib
    if ($LASTEXITCODE -ne 0) { throw "cl.exe 编译 vbox_jsc.dll 失败" }

    # ④ 语义冒烟：smoke_test.c + wrapper.c 静态链（等价 macOS 冒烟）
    Write-Host "🧪 编译并运行 smoke_test（vj_* ABI 语义）"
    & cl.exe /nologo /utf-8 /O2 "/I$inc" `
        "$root\jsc\smoke_test.c" "$root\jsc\wrapper.c" `
        /link /OUT:smoke_test.exe JavaScriptCore.lib
    if ($LASTEXITCODE -ne 0) { throw "cl.exe 编译 smoke_test 失败" }
    # 运行期解析 JavaScriptCore.dll + ICU：vendor 置于 PATH 最前
    $env:PATH = "$vendor;$env:PATH"
    & .\smoke_test.exe
    if ($LASTEXITCODE -ne 0) { throw "smoke_test 失败（vj_* 语义不符）" }

    # ⑤ 符号级校验（对齐 Android「vj_* 六符号 + 链 JavaScriptCore」口径）
    Write-Host "🔎 符号校验（vj_* 六导出 + 链 JavaScriptCore.dll）"
    $exports = (& dumpbin.exe /exports vbox_jsc.dll) -join "`n"
    $imports = (& dumpbin.exe /imports vbox_jsc.dll) -join "`n"
    $missing = @()
    foreach ($sym in $symList) {
        if ($exports -notmatch ("\b" + [regex]::Escape($sym) + "\b")) { $missing += $sym }
    }
    if ($missing.Count -gt 0) { throw "缺导出符号：$($missing -join ', ')" }
    if ($imports -notmatch "JavaScriptCore.dll") { throw "vbox_jsc.dll 未链 JavaScriptCore.dll" }
    Write-Host "✅ vj_* 六符号 ✓ · 链 JavaScriptCore.dll ✓"
} finally {
    Pop-Location
}

Write-Host "✅ 构建完成：$build\vbox_jsc.dll"