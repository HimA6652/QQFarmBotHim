# ============================================================================
#  提权终止进程（被控制面板调用）
# ============================================================================
#  为什么需要单独一个脚本：
#    NapCat 是通过 UAC 提权启动的（QQ / NapCatWinBootMain 运行在高完整性级别），
#    而控制面板本身是普通权限。Windows 规则是「低完整性进程不能终止高完整性进程」，
#    所以面板里直接 Stop-Process 会抛「拒绝访问」。
#    面板检测到这种情况后，会用 RunAs 调用本脚本（弹一次 UAC），
#    在管理员上下文里把剩下的进程清掉。
#
#  用法：
#    powershell -NoProfile -ExecutionPolicy Bypass -File kill-pids.ps1 -Pids 123,456
#  退出码：
#    0 = 全部成功（或被安全策略跳过）；1 = 有失败（详情写到 -ResultFile 指定的文件）
#
#  白名单（2026-10-17 补）：
#    本脚本以管理员身份运行，不能变成"任意 PID 杀手"。
#    只允许结束 QQ.exe / NapCatWinBootMain.exe / 命令行含 NapCat 的进程；
#    其余一律 SKIP 并记入结果文件。真正的筛选在面板侧（按父进程树算 PID 集合），
#    这里是纵深防御。
# ============================================================================
[CmdletBinding()]
param(
    [string]$Pids = '',
    [string]$ResultFile = ''
)

$results = @()

$ids = @()
if ($Pids) {
    $ids = @($Pids -split ',' | Where-Object { $_.Trim() -ne '' } | ForEach-Object { [int]$_.Trim() })
}

$okCount = 0
$skipCount = 0
$failList = @()

foreach ($id in $ids) {
    try {
        $ci = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction Stop
    }
    catch {
        $ci = $null
    }
    if (-not $ci) {
        $results += "SKIP $id 进程已不存在"
        $skipCount++
        continue
    }

    $name = [string]$ci.Name
    $cmdline = [string]$ci.CommandLine
    $allowed = ($name -match '^(QQ|NapCatWinBootMain)\.exe$') -or ($cmdline -match 'NapCat')
    if (-not $allowed) {
        $results += "SKIP $id 非 NapCat 相关进程（$name），拒绝结束"
        $skipCount++
        continue
    }

    try {
        Stop-Process -Id $id -Force -ErrorAction Stop
        $results += "OK $id"
        $okCount++
    }
    catch {
        $msg = $_.Exception.Message
        $results += "FAIL $id $msg"
        $failList += "$id : $msg"
    }
}

Write-Host ("killed={0} skipped={1} failed={2}" -f $okCount, $skipCount, $failList.Count)
foreach ($f in $failList) { Write-Host ("  " + $f) }

if ($ResultFile) {
    try {
        [System.IO.File]::WriteAllText($ResultFile, ($results -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { }
}

if ($failList.Count -gt 0) { exit 1 }
exit 0
