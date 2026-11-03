# vbox 安装器 · 安装/卸载前清理占用运行时的进程
#
# 由 installer.iss 在 [Code] 里 ExtractTemporaryFile 释放后用
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File <本文件> -AppDir "<安装目录>"
# 调用。
#
# ⚠ 为什么是「脚本文件 + -File」，而不是 -Command：
#   Inno 的 Exec 把参数串原样拼进命令行，PowerShell 会把 -Command 后面的内容
#   当成脚本**重新解析**，那一层会吃掉所有双引号（单引号包着也保不住），
#   于是 `-like "C:\x\*"` 变成 `-like C:\x\*`，直接 ParserError 退出码 1，
#   一个进程都杀不掉。而 -File 走正常 argv 传参，引号不会丢。
#   本文件自身不会被命令行解析，所以里面可以正常写双引号。
#
# ⚠ 退出码不可靠：Get-Process 读个别系统进程的 .Path 会报拒绝访问，
#   PowerShell 因此返回 1，但管道照常跑完。判定成败由 iss 侧的「改名探测」做。
#
# 杀不到不算失败：安装器在复制文件前会自己探测文件是否仍被占用，
# 仍被占用就中止并提示用户手动退出，而不是半路抛 DeleteFile 错误码 5。

param(
    [Parameter(Mandatory = $true)][string]$AppDir
)

$ErrorActionPreference = 'SilentlyContinue'
$prefix = $AppDir.TrimEnd('\')
$names  = @('node.exe', 'python.exe', 'pythonw.exe')

function Test-TargetPath([string]$Path) {
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    if ($Path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($Path -like '*\com.vbox\vbox\*') { return $true }
    return $false
}

$killed = 0

# ── 快路径：Get-Process 的 .Path（安装/覆盖场景，旧 exe 还在，最便宜） ──
Get-Process -Name node, python, pythonw -ErrorAction SilentlyContinue | ForEach-Object {
    $p = $_
    if (-not (Test-TargetPath $p.Path)) { return }
    try {
        Stop-Process -Id $p.Id -Force -ErrorAction Stop
        $script:killed++
        Write-Output ('killed pid=' + $p.Id + ' path=' + $p.Path)
    } catch {
        Write-Output ('failed pid=' + $p.Id + ' path=' + $p.Path + ' err=' + $_.Exception.Message)
    }
}

# ── 慢路径：CIM 的 ExecutablePath（占用进程的 exe 已被卸载/无权限读 .Path 时兜底） ──
foreach ($name in $names) {
    $query = "Name='" + $name + "'"
    Get-CimInstance -ClassName Win32_Process -Filter $query -ErrorAction SilentlyContinue | ForEach-Object {
        $proc = $_
        if (-not (Test-TargetPath $proc.ExecutablePath)) { return }
        try {
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
            $script:killed++
            Write-Output ('killed pid=' + $proc.ProcessId + ' path=' + $proc.ExecutablePath)
        } catch {
            Write-Output ('failed pid=' + $proc.ProcessId + ' path=' + $proc.ExecutablePath + ' err=' + $_.Exception.Message)
        }
    }
}

Write-Output ('done killed=' + $killed)

# 给句柄释放留一点时间（映射文件关闭是异步的）
Start-Sleep -Milliseconds 300
exit 0
