# 安装器「脏环境」冒烟测试（Windows）
#
# 目的：复现 3.1888 线上故障——旧版运行时进程占着 pyruntime\python.exe，
#       安装器覆盖该文件时 DeleteFile 失败（错误码 5）并回滚。
#       修复后本脚本必须通过：安装器要么杀掉占用进程，要么在复制文件前
#       给出可读提示，绝不能装到一半回滚。
#
# 用法（本地 / CI 均可）：
#   pwsh -File scripts/smoke/win-installer-dirty-env.ps1 -SetupPath .\vbox-setup.exe
#
# 退出码：0 = 通过，1 = 失败（日志会打印关键行）

param(
    [Parameter(Mandatory = $true)][string]$SetupPath,
    [string]$InstallDir = "$env:LOCALAPPDATA\Programs\vbox-smoke",
    [int]$TimeoutSeconds = 600
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $SetupPath)) { throw "找不到安装包：$SetupPath" }

Write-Host "== 1. 清理目标目录 =="
if (Test-Path -LiteralPath $InstallDir) {
    Remove-Item -LiteralPath $InstallDir -Recurse -Force
}

Write-Host "== 2. 用安装包正常装一遍（建立旧版现场） =="
$first = Start-Process -FilePath $SetupPath -ArgumentList @(
    '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOCANCEL', '/SP-', "/DIR=$InstallDir"
) -Wait -PassThru
if ($first.ExitCode -ne 0) { throw "首次安装失败，退出码 $($first.ExitCode)" }

$runtime = Join-Path $InstallDir 'pyruntime\python.exe'
if (-not (Test-Path -LiteralPath $runtime)) { throw "首次安装后缺少 $runtime（安装包结构变化？）" }

Write-Host "== 3. 起一个'旧版常驻进程'锁住运行时（模拟真实现场） =="
$locker = Start-Process -FilePath $runtime -ArgumentList '-c', 'import time;time.sleep(900)' -PassThru
Start-Sleep -Seconds 2

$locked = $false
try {
    $fs = [System.IO.File]::Open($runtime, 'Open', 'ReadWrite', 'None')
    $fs.Close()
} catch {
    $locked = $true
}
if (-not $locked) { throw "未能锁住 $runtime，冒烟测试无效" }
Write-Host "   已锁定（pid=$($locker.Id)）"

Write-Host "== 4. 脏环境下再装一遍（这就是线上失败的场景） =="
$logDir = Join-Path $env:LOCALAPPDATA 'vbox-setup-logs'
$before = @()
if (Test-Path -LiteralPath $logDir) { $before = Get-ChildItem -LiteralPath $logDir -Filter 'vbox-setup-*.log' | Select-Object -ExpandProperty FullName }

$watch = [System.Diagnostics.Stopwatch]::StartNew()
$second = Start-Process -FilePath $SetupPath -ArgumentList @(
    '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOCANCEL', '/SP-', "/DIR=$InstallDir"
) -Wait -PassThru
$watch.Stop()
$code = $second.ExitCode

Write-Host "== 5. 断言 =="
if (-not $locker.HasExited) {
    # 安装器若杀不掉占用者，就必须在复制前中止并给出提示（非 0 退出），
    # 但绝不允许装到一半回滚。这里区分两种情况打印现场。
    Write-Host "   占用进程仍存活（安装器未杀它）"
}

$newLogs = @()
if (Test-Path -LiteralPath $logDir) {
    $newLogs = Get-ChildItem -LiteralPath $logDir -Filter 'vbox-setup-*.log' |
        Where-Object { $before -notcontains $_.FullName } |
        Sort-Object LastWriteTime -Descending
}
if ($newLogs.Count -gt 0) {
    $logText = Get-Content -LiteralPath $newLogs[0].FullName -Raw
    $hits = ($logText -split "`r?`n") | Where-Object {
        $_ -match 'KillVboxProcesses|DeleteFile|Installation process succeeded|Error|Rolling back'
    }
    Write-Host "   日志：$($newLogs[0].FullName)"
    $hits | Select-Object -First 20 | ForEach-Object { "   | $_" }
}

if ($code -eq 0) {
    Write-Host "PASS：脏环境下安装成功（耗时 $([int]$watch.Elapsed.TotalSeconds)s）"
    if (-not $locker.HasExited) { Stop-Process -Id $locker.Id -Force -ErrorAction SilentlyContinue }
    exit 0
}

if ($locker.HasExited) {
    Write-Host "FAIL：占用进程被杀了但安装仍失败（退出码 $code），看上面的日志"
} else {
    Write-Host "FAIL：安装失败（退出码 $code）。若预期是「复制前友好中止」，请人工确认提示文案"
}
Stop-Process -Id $locker.Id -Force -ErrorAction SilentlyContinue
exit 1
