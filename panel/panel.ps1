<#
    QQ 农场助手（活动自动化版）· 控制面板
    ------------------------------------------------------------------
    部署根目录: 与 panel 同级（路径由脚本自身位置推导，整个文件夹可以整体搬走）
      core\              主程序（Web 面板 :3007）
      napcat\            QQ 协议端（WebUI :6099 / OneBot :3000）
      runtime\node       自包含 Node 运行时
      data\              账号与配置数据
      panel              本控制面板

    与原版的区别：不再需要 qq-miniapp-auth 授权服务（新版内置 NapCat 扫码链路）。

    用法:
      powershell -ExecutionPolicy Bypass -File panel.ps1                 打开图形控制面板
      powershell -ExecutionPolicy Bypass -File panel.ps1 -Action web     以网页形式监听端口（局域网可访问）
      powershell -ExecutionPolicy Bypass -File panel.ps1 -Action web -WebPort 3100 -WebBind 0.0.0.0
      powershell -ExecutionPolicy Bypass -File panel.ps1 -Action start   启动主程序
      powershell -ExecutionPolicy Bypass -File panel.ps1 -Action stop    停止主程序
      powershell -ExecutionPolicy Bypass -File panel.ps1 -Action restart 重启主程序
      powershell -ExecutionPolicy Bypass -File panel.ps1 -Action status  查看服务状态
      powershell -ExecutionPolicy Bypass -File panel.ps1 -Action update  同步更新上游仓库
      powershell -ExecutionPolicy Bypass -File panel.ps1 -Action build   重新构建（前端+后端）
      powershell -ExecutionPolicy Bypass -File panel.ps1 -Action shortcut 重建桌面快捷方式
      powershell -ExecutionPolicy Bypass -File panel.ps1 -Action selftest 自检：构建并显示一次面板后自动关闭
      powershell -ExecutionPolicy Bypass -File panel.ps1 -Action prepscan 准备 QQ 扫码登录（NapCat 注销）
      powershell -ExecutionPolicy Bypass -File panel.ps1 -Action checkversion 检测上游版本

    说明:
      - GUI 线程里绝不做网络 IO：版本检测由独立进程执行，结果落盘后由界面读取。
      - NapCat 启动走上游原版 napcat\launcher-win10.bat（隐藏窗口；QQ 路径取自注册表 Uninstall\QQ）。
      - 端口: 主程序 3007 / NapCat WebUI 6099 / NapCat OneBot 3000
#>
[CmdletBinding()]
param(
    [ValidateSet('gui', 'start', 'stop', 'restart', 'status', 'update', 'build', 'shortcut', 'selftest', 'prepscan', 'checkversion', 'stopnapcat', 'startnapcat', 'upstreamdiff', 'syncupstream', 'web')]
    [string]$Action = 'gui',
    [switch]$NoPause,
    # 启动 NapCat 时自动关闭桌面版 QQ（同一账号不能重复登录）
    [switch]$CloseDesktopQq,
    # 同步上游必须显式带这个开关，防止误触/脚本误调
    [switch]$ConfirmSync,
    # Web 控制面板：监听地址与端口。0.0.0.0 = 本机所有网卡（局域网可访问）
    [string]$WebBind = '0.0.0.0',
    [int]$WebPort = 3100
)

$ErrorActionPreference = 'Continue'
$PanelDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $PanelDir
$RunDir = Join-Path $PanelDir 'run'
$LogDir = Join-Path $PanelDir 'logs'
$script:SelfTestMode = ($Action -eq 'selftest')
if (-not (Test-Path -LiteralPath $RunDir)) { New-Item -ItemType Directory -Force -Path $RunDir | Out-Null }
if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }

# Windows PowerShell 5.1 默认按 ANSI 读无 BOM 的 UTF-8 文件（中文全乱），
# 本脚本一律写成 UTF-8 + BOM；这里再兜底一次，防止手工保存时丢了 BOM。
if ($MyInvocation.MyCommand.Path) {
    $bytes = [System.IO.File]::ReadAllBytes($MyInvocation.MyCommand.Path)
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) {
        Write-Host "  [警告] panel.ps1 缺少 UTF-8 BOM，中文可能显示为乱码。请用「另存为 → UTF-8 带 BOM」保存。" -ForegroundColor Yellow
    }
}

# GitHub 加速镜像（直连被墙，且 Clash 把 github 判进 DIRECT 不走代理）
$Mirrors = @(
    'https://gh-proxy.com/',
    'https://ghfast.top/',
    'https://ghproxy.net/'
)

# ================= 被管理的服务 =================
#   farm    主程序（由 launch.ps1 设置环境变量后拉起，端口 3007）
#   napcat  QQ 协议端（WebUI 6099 / OneBot 3000）
$Services = @(
    [pscustomobject]@{ Key = 'farm'; Name = 'QQ 农场主程序'; Ports = @(3007); PidFile = "$RunDir\farm.pid" },
    [pscustomobject]@{ Key = 'napcat'; Name = 'NapCat QQ协议端'; Ports = @(6099, 3000); PidFile = "$RunDir\napcat.pid" }
)

# ================= 版本检测 / 更新用的仓库 =================
# 新版只有一个仓库，默认分支是 main（原版是 master，别搞混）
$Repos = @(
    [pscustomobject]@{
        Key = 'bot'; Name = 'QQ 农场主程序'; Owner = 'muyuewang'; Repo = 'qq-farm-bot-404'
        Dir = $Root; Branch = 'main'; PkgRel = 'core/package.json'
    }
)

$VersionIntervals = [ordered]@{
    '手动' = 0; '15 分钟' = 15; '30 分钟' = 30; '1 小时' = 60
    '3 小时' = 180; '6 小时' = 360; '12 小时' = 720; '24 小时' = 1440
}

$VersionStateFile = Join-Path $RunDir 'version-check.json'
$VersionLockFile = Join-Path $RunDir 'version-check.lock'
$GuiLogPath = Join-Path $LogDir 'panel.gui.log'
$PanelConfigFile = Join-Path $PanelDir 'panel.config.json'

# ------------------------------------------------------------------ 基础工具
function Write-GuiLog {
    param([string]$Line)
    try {
        $stamp = (Get-Date).ToString('HH:mm:ss')
        [System.IO.File]::AppendAllText($GuiLogPath, "[$stamp] $Line`r`n", (New-Object System.Text.UTF8Encoding($false)))
        # 日志轮转：每写 200 行检查一次大小，超过 2 MB 滚成 .1（只保留一份历史）。
        # 面板是常驻进程，不轮转会无限增长。
        $script:guiLogWrites++
        if ($script:guiLogWrites -ge 200) {
            $script:guiLogWrites = 0
            $fi = Get-Item -LiteralPath $GuiLogPath -ErrorAction SilentlyContinue
            if ($fi -and $fi.Length -gt 2MB) {
                $old = "$GuiLogPath.1"
                if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue }
                Move-Item -LiteralPath $GuiLogPath -Destination $old -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch { }
}

function Repair-ProcessEnvironment {
    # 本机同时存在大小写不同的 http_proxy / https_proxy 变量，Start-Process 会抛
    # "已添加项。不能在集合中拥有相同大小的项"，必须先清掉重复的那个。
    foreach ($name in @('http_proxy', 'https_proxy', 'all_proxy')) {
        $upper = $name.ToUpper()
        $lower = $name.ToLower()
        if ($upper -eq $lower) { continue }
        if ([Environment]::GetEnvironmentVariable($upper, 'Process') -and
            [Environment]::GetEnvironmentVariable($lower, 'Process')) {
            [Environment]::SetEnvironmentVariable($upper, $null, 'Process')
        }
    }
}

function Resolve-GitPath {
    # 本机没有独立安装的 Git（用户 PATH 里的 .dsh\bin\git\cmd 是失效路径），
    # 唯一的 git 在 WorkBuddy 自带的 PortableGit 里。必须自己找，不能依赖 PATH。
    $glob = Get-ChildItem -Path (Join-Path $env:USERPROFILE '.workbuddy\binaries\PortableGit\versions\*\cmd\git.exe') -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
    if ($glob) { return $glob.FullName }
    $cands = @(
        (Join-Path $env:ProgramFiles 'Git\cmd\git.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Git\cmd\git.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe'),
        (Join-Path $env:USERPROFILE '.dsh\bin\git\cmd\git.exe')
    )
    foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    $cmd = Get-Command git -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-ListeningPortSet {
    # 一次枚举监听表，别逐个连端口探测——本机连未监听端口会吃满超时（400ms+），
    # 而枚举监听表只要 1~18ms。
    $set = New-Object 'System.Collections.Generic.HashSet[int]'
    try {
        $props = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
        foreach ($ep in $props.GetActiveTcpListeners()) { [void]$set.Add($ep.Port) }
    }
    catch { }
    return $set
}

function Test-PortOpen {
    param([int]$Port)
    $set = Get-ListeningPortSet
    return $set.Contains($Port)
}

function Get-ServiceStatus {
    <#  -ResolvePid：是否反查监听端口的 PID。
        Get-NetTCPConnection 在本机 300~1600 ms/次，绝不能在 4 秒定时器里调用
        （脚本原先就是每轮询都调，导致界面周期性卡顿）。
        定时器走监听表 + pid 文件；只有用户手动刷新/操作后才反查一次。  #>
    param($Service, $PortSet, [switch]$ResolvePid)
    $running = $false
    $pidFound = 0
    foreach ($p in $Service.Ports) {
        if ($PortSet.Contains($p)) { $running = $true; break }
    }
    if ($running -and $ResolvePid) {
        try {
            foreach ($p in $Service.Ports) {
                $conns = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue
                foreach ($c in $conns) { if ($c.OwningProcess -gt 0) { $pidFound = $c.OwningProcess; break } }
                if ($pidFound -gt 0) { break }
            }
        }
        catch { }
    }
    if ($running -and $pidFound -le 0) {
        # 端口在听但拿不到 PID（可能非本用户进程），退回读 PID 文件
        try {
            if (Test-Path -LiteralPath $Service.PidFile) {
                $parts = (Get-Content -LiteralPath $Service.PidFile -Raw).Trim() -split '\|'
                $rec = [int]$parts[0]
                $ticks = if ($parts.Count -gt 1) { [int64]$parts[1] } else { 0 }
                $proc = Get-Process -Id $rec -ErrorAction SilentlyContinue
                if ($proc) {
                    $now = [int64](Get-Date).Ticks
                    if ($ticks -le 0 -or $proc.StartTime.Ticks -eq $ticks) { $pidFound = $rec }
                }
            }
        }
        catch { }
    }
    $portText = ($Service.Ports | ForEach-Object {
        $on = if ($PortSet.Contains($_)) { '已监听' } else { '未监听' }
        "$_ $on"
    }) -join ' / '
    return [pscustomobject]@{ Running = $running; Pid = $pidFound; PortText = $portText }
}

function Show-StatusTable {
    $portSet = Get-ListeningPortSet
    Write-Line ''
    foreach ($s in $Services) {
        $st = Get-ServiceStatus -Service $s -PortSet $portSet -ResolvePid
        if ($st.Running) {
            $pidText = if ($st.Pid -gt 0) { " (PID $($st.Pid))" } else { '' }
            Write-Line ("  {0,-20} 运行中{1}  端口: {2}" -f $s.Name, $pidText, $st.PortText) 'Green'
        }
        else {
            Write-Line ("  {0,-20} 已停止     端口: {1}" -f $s.Name, $st.PortText) 'Gray'
        }
    }
    Write-Line ''
    Write-Line '  主程序 Web 面板: http://127.0.0.1:3007' 'Gray'
    Write-Line '  NapCat WebUI  : http://127.0.0.1:6099/webui/' 'Gray'
}

function Write-Line {
    param([string]$Text, [string]$Color = 'Gray')
    $map = @{ Gray = 'Gray'; Green = 'Green'; Red = 'Red'; Yellow = 'Yellow'; Cyan = 'Cyan'; White = 'White'; DarkGray = 'DarkGray' }
    $c = 'Gray'
    if ($map.ContainsKey($Color)) { $c = $map[$Color] }
    Write-Host $Text -ForegroundColor $c
    # GUI 已打开时同步进日志框：否则「启动主程序」的实际结果（成功/失败原因）
    # 只写进 panel.gui.log，界面上只看到一句"启动主程序"，无法判断。
    if ($script:GuiLogSink) {
        try { & $script:GuiLogSink $Text } catch { }
    }
    else {
        Write-GuiLog $Text
    }
}

# ------------------------------------------------------------------ 本地 HTTP
function Invoke-LocalJsonPost {
    <#  本地 HTTP POST。用 HttpWebRequest 并显式关掉代理——
        本机系统代理是 Clash，走代理访问 127.0.0.1 会失败。  #>
    param([string]$Uri, [hashtable]$Headers = @{}, [string]$Body = '{}', [int]$TimeoutSec = 30)
    try {
        $req = [System.Net.HttpWebRequest]::Create($Uri)
        $req.Proxy = $null
        $req.Method = 'POST'
        $req.ContentType = 'application/json'
        $req.Timeout = $TimeoutSec * 1000
        $req.ReadWriteTimeout = $TimeoutSec * 1000
        foreach ($k in $Headers.Keys) { $req.Headers.Add($k, $Headers[$k]) }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $req.ContentLength = $bytes.Length
        $stream = $req.GetRequestStream()
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Close()
        $resp = $req.GetResponse()
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $text = $reader.ReadToEnd()
        $reader.Close(); $resp.Close()
        return $text
    }
    catch {
        return "ERROR: $($_.Exception.Message)"
    }
}

function Invoke-LocalHttpGet {
    param([string]$Uri, [hashtable]$Headers = @{}, [int]$TimeoutSec = 15)
    try {
        $req = [System.Net.HttpWebRequest]::Create($Uri)
        $req.Proxy = $null
        $req.Method = 'GET'
        $req.Timeout = $TimeoutSec * 1000
        $req.ReadWriteTimeout = $TimeoutSec * 1000
        foreach ($k in $Headers.Keys) { $req.Headers.Add($k, $Headers[$k]) }
        $resp = $req.GetResponse()
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $text = $reader.ReadToEnd()
        $reader.Close(); $resp.Close()
        return $text
    }
    catch {
        return "ERROR: $($_.Exception.Message)"
    }
}

function Invoke-RemoteText {
    <#  纯 HTTP GET。必须显式 Proxy = $null —— 本机系统代理是 Clash，
        走代理访问这些镜像/本地地址都会失败。  #>
    param([string]$Uri, [int]$TimeoutSec = 25)
    try {
        $req = [System.Net.HttpWebRequest]::Create($Uri)
        $req.Proxy = $null
        $req.Method = 'GET'
        $req.Timeout = $TimeoutSec * 1000
        $req.ReadWriteTimeout = $TimeoutSec * 1000
        $req.UserAgent = 'QQFarmBot-Panel'
        $req.Accept = 'application/json, text/plain, */*'
        $resp = $req.GetResponse()
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
        $text = $reader.ReadToEnd()
        $reader.Close(); $resp.Close()
        return $text
    }
    catch {
        return $null
    }
}

function Get-ServiceByKey {
    param([string]$Key)
    foreach ($s in $Services) { if ($s.Key -eq $Key) { return $s } }
    return $null
}

# ------------------------------------------------------------------ 启停：主程序
function Start-FarmService {
    $launcher = Join-Path $Root 'launch.ps1'
    if (-not (Test-Path -LiteralPath $launcher)) {
        Write-Line "  [主程序] 缺少启动器：$launcher" 'Red'
        return $false
    }
    # 先删旧 pid：真实 PID 由 launch.ps1 在拉起 node 后写入（它才拿得到 node 的 PID，
    # 面板这里拿到的永远是中间那个 powershell 的 PID，写进来只会误导停止逻辑）。
    Remove-Item -LiteralPath (Join-Path $RunDir 'farm.pid') -Force -ErrorAction SilentlyContinue
    try {
        # -Hidden：由 launch.ps1 设置好环境变量后无窗口拉起 node
        Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launcher, '-Hidden') `
            -WorkingDirectory $Root -WindowStyle Hidden | Out-Null
        Write-Line "  [主程序] 已请求后台启动（无窗口），端口 3007" 'Green'
        Write-Line '  [主程序] 启动约需 10~30 秒，之后点「刷新状态」或直接使用。' 'DarkGray'
        Write-Line '  [主程序] 输出在 data\logs\combined-*.log' 'DarkGray'
        return $true
    }
    catch {
        Write-Line "  [主程序] 启动失败：$($_.Exception.Message)" 'Red'
        return $false
    }
}

function Test-FarmProcess {
    <#  确认某个 PID 真的是本项目的主程序：命令行里必须有 core\client.js。
        停止逻辑靠它避免"端口被别的程序占用时误杀"。  #>
    param([int]$ProcessId)
    try {
        $ci = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
        if (-not $ci) { return $false }
        return ([string]$ci.CommandLine -match 'core[\\/]client\.js')
    }
    catch { return $false }
}

function Stop-FarmService {
    <#  只结束「本项目主程序」，两条判据都要求命令行匹配 core\client.js：
        1) pid 文件里的 PID（再叠加启动时间校验，防 PID 复用）
        2) 监听 3007 的进程（兜底）
        端口被别的程序占用时只提示、不杀 —— 旧版按端口一律 Stop-Process 会误杀。  #>
    $stopped = 0
    $skipped = 0
    $pidFile = Join-Path $RunDir 'farm.pid'

    if (Test-Path -LiteralPath $pidFile) {
        try {
            $parts = (Get-Content -LiteralPath $pidFile -Raw).Trim() -split '\|'
            $rec = [int]$parts[0]
            $ticks = if ($parts.Count -gt 1) { [int64]$parts[1] } else { 0 }
            $proc = Get-Process -Id $rec -ErrorAction SilentlyContinue
            if ($proc) {
                $sameStart = ($ticks -le 0) -or ($proc.StartTime.Ticks -eq $ticks)
                if (-not $sameStart) {
                    Write-Line '  [主程序] PID 已被系统复用，跳过（不误杀）。' 'Yellow'
                }
                elseif (Test-FarmProcess -ProcessId $rec) {
                    Stop-Process -Id $rec -Force -ErrorAction SilentlyContinue
                    $stopped++
                }
                else {
                    Write-Line "  [主程序] PID $rec 存在但不是本项目主程序，跳过。" 'Yellow'
                    $skipped++
                }
            }
        }
        catch { }
    }

    $conns = @(Get-NetTCPConnection -LocalPort 3007 -State Listen -ErrorAction SilentlyContinue)
    foreach ($c in $conns) {
        $op = [int]$c.OwningProcess
        if ($op -le 0) { continue }
        if ($op -eq $PID) { continue }
        if (-not (Get-Process -Id $op -ErrorAction SilentlyContinue)) { continue }
        if (Test-FarmProcess -ProcessId $op) {
            try { Stop-Process -Id $op -Force -ErrorAction Stop; $stopped++ } catch { }
        }
        else {
            Write-Line ("  [主程序] 3007 被 PID {0} 占用，但命令行不是本项目主程序 —— 不动它。" -f $op) 'Yellow'
            $skipped++
        }
    }

    if ($stopped -gt 0) { Write-Line "  [主程序] 已停止（共 $stopped 个进程）。" 'Green' }
    elseif ($skipped -gt 0) { Write-Line '  [主程序] 未结束任何进程（原因见上）。' 'Yellow' }
    else { Write-Line '  [主程序] 本来就没有在运行。' 'DarkGray' }
}

# ------------------------------------------------------------------ 启停：NapCat
function Get-QqMainProcesses {
    <#  列出所有 QQ 主进程（命令行不含 --type= 的那些），带父进程与启动参数特征。
        用普通数组累加（generic List 在 PS 5.1 里经 @() 返回会抛"参数类型不匹配"）。  #>
    $out = @()
    $all = @(Get-CimInstance Win32_Process -Filter "Name='QQ.exe'" -ErrorAction SilentlyContinue)
    if ($all.Count -eq 0) { return $out }
    $byPid = @{}
    foreach ($p in $all) { $byPid[[int]$p.ProcessId] = $p }
    foreach ($p in $all) {
        $cl = [string]$p.CommandLine
        if ($cl -match '--type=') { continue }
        $ppid = [int]$p.ParentProcessId
        $parentName = ''
        if ($byPid.ContainsKey($ppid)) { $parentName = 'QQ.exe' }
        else {
            $par = Get-CimInstance Win32_Process -Filter "ProcessId=$ppid" -ErrorAction SilentlyContinue
            if ($par) { $parentName = [string]$par.Name }
        }
        $started = ''
        try { $started = ([datetime]$p.CreationDate).ToString('HH:mm:ss') } catch { }
        $out += [pscustomobject]@{
            Pid           = [int]$p.ProcessId
            ParentPid     = $ppid
            ParentName    = $parentName
            EnableLogging = [bool]($cl -match '--enable-logging')
            StartedAt     = $started
        }
    }
    return $out
}

function Get-DesktopQqProcesses {
    <#  桌面版 QQ = 不是 NapCatWinBootMain 的后代，也不带 --enable-logging。
        它们会占用同一个 QQ 号的会话，导致 NapCat 报「当前账号已登录，无法重复登录」，
        进而 coreReady=false、插件全部 503、扫码点确认后毫无反应。  #>
    $mains = @(Get-QqMainProcesses)
    return @($mains | Where-Object { $_.ParentName -ne 'NapCatWinBootMain.exe' -and -not $_.EnableLogging })
}

function Format-DesktopQqHint {
    param([array]$Desktops)
    if (-not $Desktops -or $Desktops.Count -eq 0) { return '' }
    $parts = @()
    foreach ($d in $Desktops) {
        $parts += ("PID {0}（{1} 启动）" -f $d.Pid, $(if ($d.StartedAt) { $d.StartedAt } else { '?' }))
    }
    return ($parts -join '、')
}

function Stop-DesktopQqProcesses {
    <#  结束桌面版 QQ 的整棵进程树。只在用户明确同意后调用。  #>
    $mains = @(Get-DesktopQqProcesses)
    if ($mains.Count -eq 0) { return 0 }
    $roots = @($mains | ForEach-Object { $_.Pid })
    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $childMap = @{}
    foreach ($p in $all) {
        $ppid = [int]$p.ParentProcessId
        if (-not $childMap.ContainsKey($ppid)) { $childMap[$ppid] = New-Object System.Collections.Generic.List[int] }
        $childMap[$ppid].Add([int]$p.ProcessId)
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[int]'
    $stack = New-Object 'System.Collections.Generic.Stack[int]'
    foreach ($r in $roots) { $stack.Push($r) }
    while ($stack.Count -gt 0) {
        $cur = $stack.Pop()
        if (-not $seen.Add($cur)) { continue }
        if ($childMap.ContainsKey($cur)) { foreach ($c in $childMap[$cur]) { $stack.Push($c) } }
    }
    $killed = 0
    foreach ($id in @($seen)) {
        try { Stop-Process -Id $id -Force -ErrorAction Stop; $killed++ } catch { }
    }
    return $killed
}

function Get-UpstreamQqInfo {
    <#  与上游 launcher-win10.bat 保持一致：QQ 路径来自注册表
        HKLM\SOFTWARE\WOW6432Node\...\Uninstall\QQ 的 UninstallString 所在目录。
        找不到时回退到 napcat\qqpath.txt（若存在）与常见安装位置。  #>
    $result = @{ path = ''; version = ''; source = '' }
    try {
        $key = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\QQ'
        $item = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if ($item -and $item.UninstallString) {
            $uninst = ([string]$item.UninstallString).Trim('"')
            $dir = Split-Path -Parent $uninst
            $exe = Join-Path $dir 'QQ.exe'
            if (Test-Path -LiteralPath $exe) {
                $result.path = $exe
                $result.source = '注册表 Uninstall\QQ'
                try {
                    $ver = @(Get-ChildItem -LiteralPath (Join-Path $dir 'versions') -Directory -ErrorAction SilentlyContinue |
                        Sort-Object Name -Descending)[0]
                    if ($ver) { $result.version = $ver.Name }
                }
                catch { }
            }
        }
    }
    catch { }
    if (-not $result.path) {
        $qqFile = Join-Path $Root 'napcat\qqpath.txt'
        if (Test-Path -LiteralPath $qqFile) {
            $p = (Get-Content -LiteralPath $qqFile -Raw).Trim()
            if ($p -and (Test-Path -LiteralPath $p)) {
                $result.path = $p
                $result.source = 'napcat\qqpath.txt'
            }
        }
    }
    if (-not $result.path) {
        foreach ($c in @("$env:ProgramFiles\Tencent\QQNT\QQ.exe", 'D:\ProgramData\QQ\QQ.exe',
            "$env:ProgramFiles\Tencent\QQ\QQ.exe")) {
            if (Test-Path -LiteralPath $c) { $result.path = $c; $result.source = '常见安装位置'; break }
        }
    }
    return $result
}

function Get-NapCatVersion {
    <#  上游把核心版本编译进 napcat.mjs，这里从 bundle 里取版本字面量（只读一次）。  #>
    if ($script:NapCatVersion) { return $script:NapCatVersion }
    $script:NapCatVersion = ''
    try {
        $mjs = Join-Path (Join-Path $Root 'napcat') 'napcat.mjs'
        if (Test-Path -LiteralPath $mjs) {
            $fs = [System.IO.File]::Open($mjs, [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                $len = [int][Math]::Min($fs.Length, 1000000)
                $buf = New-Object byte[] $len
                [void]$fs.Seek(0, [System.IO.SeekOrigin]::Begin)
                [void]$fs.Read($buf, 0, $len)
                $txt = [System.Text.Encoding]::UTF8.GetString($buf)
                $m = [regex]::Match($txt, '&& "(\d+\.\d+\.\d+)"')
                if ($m.Success) { $script:NapCatVersion = $m.Groups[1].Value }
            }
            finally { $fs.Close() }
        }
    }
    catch { }
    return $script:NapCatVersion
}

function Start-NapCatService {
    param([switch]$CloseDesktopQq)
    # 启动入口：项目根目录的 napcat-launcher.bat —— 内部原样调用上游
    # napcat\launcher-win10.bat，仅额外把控制台输出留档到 napcat-launch.log
    # （napcat\ 目录保持 100% 上游，不放任何自研文件）
    $bat = Join-Path $Root 'napcat-launcher.bat'
    if (-not (Test-Path -LiteralPath $bat)) {
        Write-Line "  [NapCat] 缺少启动包装器：$bat" 'Red'
        return $false
    }
    # 启动前先报告：如果已经有 NapCat 相关进程在跑，说明上次没停干净，
    # 这次启动会与残留实例抢同一个 QQ 会话（扫码会报"已登录无法重复登录"）。
    try {
        $tree = @(Get-NapCatProcessTree)
        if ($tree.Count -gt 0) {
            Write-Line "  [NapCat] 检测到 $($tree.Count) 个 NapCat 相关进程仍在运行（上次未停干净）。" 'Yellow'
            Write-Line '  [NapCat] 这会导致 QQ 会话残留，扫码时报"已登录无法重复登录"。' 'Yellow'
            Write-Line '  [NapCat] 建议先点「停止 NapCat」，等提示结束后再启动。' 'Yellow'
        }
    }
    catch { }

    # 桌面版 QQ 必须关掉：它和 NapCat 的 QQ 抢同一个账号的会话。
    # 症状就是 NapCat 控制台报「当前账号已登录，无法重复登录」，
    # 进而 coreReady=false、插件全 503、手机点确认后毫无反应。
    $desktops = @(Get-DesktopQqProcesses)
    if ($desktops.Count -gt 0) {
        Write-Line "  [NapCat] ⚠ 检测到桌面版 QQ 正在运行：$(Format-DesktopQqHint $desktops)" 'Yellow'
        Write-Line '  [NapCat]   它会占用同一个 QQ 号的会话，导致 NapCat 登录被拒、扫码点确认后无响应。' 'Yellow'
        if ($CloseDesktopQq) {
            $n = Stop-DesktopQqProcesses
            Write-Line "  [NapCat]   已按你的确认关闭桌面版 QQ（$n 个进程）。" 'Green'
        }
        else {
            Write-Line '  [NapCat]   请先退出桌面版 QQ 再启动 NapCat（或勾选「自动关闭桌面版 QQ」）。' 'Yellow'
            Write-Line '  [NapCat] 已中止启动，避免产生半死状态。' 'Yellow'
            return $false
        }
    }

    # QQ 路径：与上游一致，从注册表 Uninstall\QQ 解析
    $qqInfo = Get-UpstreamQqInfo
    $qq = $qqInfo.path
    if (-not $qq) {
        Write-Line '  [NapCat] 未检测到 QQ.exe（注册表 Uninstall\QQ 缺失）。' 'Yellow'
        Write-Line '            上游启动器同样会因此退出，请重装 QQ 或修复注册表。' 'Yellow'
    }
    else {
        Write-Line ("  [NapCat] QQ 路径：{0}（来源：{1}{2}）" -f $qq, $qqInfo.source,
            $(if ($qqInfo.version) { "，版本 $($qqInfo.version)" } else { '' })) 'DarkGray'
    }
    try {
        # 上游 launcher-win10.bat 是前台控制台程序，这里用隐藏窗口跑。
        # 关键：面板本身已经提权时（计划任务 QQFarmBot-Panel 启动的实例），
        # 再加 -Verb RunAs 会让 ShellExecute 走一遍 consent 流程而起不来，
        # 因此只有非提权时才用 RunAs。
        $spArgs = @{
            FilePath         = (Join-Path $env:SystemRoot 'System32\cmd.exe')
            ArgumentList     = @('/c', "`"`"$bat`"")
            WorkingDirectory = (Join-Path $Root 'napcat')
            WindowStyle      = 'Hidden'
            PassThru         = $true
        }
        if (-not (Test-IsElevated)) { $spArgs['Verb'] = 'RunAs' }
        $proc = Start-Process @spArgs
        $ticks = 0
        try { $ticks = $proc.StartTime.Ticks } catch { $ticks = 0 }
        Set-Content -LiteralPath (Join-Path $RunDir 'napcat.pid') -Value "$($proc.Id)|$ticks" -Encoding ascii
        Write-Line '  [NapCat] 已请求启动（上游 launcher-win10.bat，需要 UAC 授权，无窗口）。' 'Green'
        Write-Line '  [NapCat] 启动约需 10~30 秒。' 'DarkGray'
        Write-Line '  [NapCat] 日志在 napcat\logs\*.log（登录成功后生成），面板「NapCat 日志」窗口实时读取。' 'DarkGray'
        Write-Line '  [NapCat] 需要看实时控制台时，双击 napcat\launcher-win10.bat（可见窗口）' 'DarkGray'
        return $true
    }
    catch {
        Write-Line "  [NapCat] 启动失败（可能取消了 UAC 授权）：$($_.Exception.Message)" 'Red'
        return $false
    }
}

function Get-QqProcessIds {
    try { return @(Get-Process -Name 'QQ' -ErrorAction SilentlyContinue | ForEach-Object { $_.Id }) }
    catch { return @() }
}

function Get-NapCatProcessTree {
    <#  返回「属于 NapCat 的进程 PID 集合」，不依赖 PID 基线。

        判据（任一命中即为 NapCat 的）：
          1) 祖先是 NapCatWinBootMain.exe           —— 本次启动的正常链路
          2) QQ 主进程（无 --type=）且命令行含 --enable-logging
             且父进程已消失（孤儿）                  —— 上次没清干净留下的残留

        用户自己开的桌面版 QQ：既不是 NapCatWinBootMain 的后代，
        也不带 --enable-logging，所以永远不会被选中。  #>
    $procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return @() }

    $byPid = @{}
    $childMap = @{}
    foreach ($p in $procs) {
        $id = [int]$p.ProcessId
        $ppid = [int]$p.ParentProcessId
        $byPid[$id] = $p
        if (-not $childMap.ContainsKey($ppid)) {
            $childMap[$ppid] = New-Object System.Collections.Generic.List[int]
        }
        $childMap[$ppid].Add($id)
    }

    $roots = New-Object System.Collections.Generic.List[int]
    foreach ($p in $procs) {
        if ($p.Name -eq 'NapCatWinBootMain.exe') { $roots.Add([int]$p.ProcessId) }
    }
    # 孤儿 NapCat QQ：主进程 + --enable-logging + 父进程不存在
    foreach ($p in $procs) {
        if ($p.Name -ne 'QQ.exe') { continue }
        $cl = [string]$p.CommandLine
        if ($cl -notmatch '--enable-logging') { continue }
        if ($cl -match '--type=') { continue }          # 只认主进程
        $ppid = [int]$p.ParentProcessId
        if (-not $byPid.ContainsKey($ppid)) { $roots.Add([int]$p.ProcessId) }
    }

    $seen = New-Object 'System.Collections.Generic.HashSet[int]'
    $stack = New-Object 'System.Collections.Generic.Stack[int]'
    foreach ($r in $roots) { $stack.Push($r) }
    while ($stack.Count -gt 0) {
        $cur = $stack.Pop()
        if (-not $seen.Add($cur)) { continue }
        if ($childMap.ContainsKey($cur)) {
            foreach ($c in $childMap[$cur]) { $stack.Push($c) }
        }
    }
    return @($seen)
}

function Test-IsElevated {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

function Invoke-ElevatedKill {
    <#  用管理员上下文终止指定 PID（弹一次 UAC）。
        NapCat 是 UAC 提权启动的，普通权限的 Stop-Process 会「拒绝访问」。  #>
    param([int[]]$Pids)
    if (-not $Pids -or $Pids.Count -eq 0) { return $false }
    $helper = Join-Path $PanelDir 'kill-pids.ps1'
    if (-not (Test-Path -LiteralPath $helper)) {
        Write-Line "  [NapCat] 缺少提权辅助脚本：$helper" 'Red'
        Write-Line '  [NapCat] 请改用管理员身份运行控制面板。' 'Red'
        return $false
    }
    $resultFile = Join-Path $RunDir 'napcat-kill-result.txt'
    Remove-Item -LiteralPath $resultFile -Force -ErrorAction SilentlyContinue
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    try {
        $proc = Start-Process -FilePath $psExe `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $helper,
            '-Pids', ($Pids -join ','), '-ResultFile', $resultFile) `
            -Verb RunAs -WindowStyle Hidden -PassThru -Wait
        Write-Line ("  [NapCat] 提权终止完成（退出码 {0}）。" -f $proc.ExitCode) 'Green'
        if (Test-Path -LiteralPath $resultFile) {
            foreach ($l in (Get-Content -LiteralPath $resultFile -Encoding UTF8)) {
                if ($l -like 'FAIL*' -or $l -like 'SKIP*') { Write-Line ("  [NapCat]   " + $l) 'Yellow' }
            }
        }
        return ($proc.ExitCode -eq 0)
    }
    catch {
        Write-Line "  [NapCat] 提权被取消或失败：$($_.Exception.Message)" 'Yellow'
        Write-Line '  [NapCat] 如需强制停止，请以管理员身份运行控制面板。' 'Yellow'
        return $false
    }
}

function Stop-NapCatService {
    <#  结束「NapCat 的整棵进程树」。

        两个关键点：
          1) 判据用「父进程 + --enable-logging」，不用 PID 基线
             （基线法会把残留孤儿当成"用户的 QQ"永久跳过）；
          2) NapCat 是 UAC 提权启动的，普通权限杀不掉 —— 直接杀失败时
             自动走一次提权（弹 UAC），并把每个失败原因打印出来。  #>
    $tree = @(Get-NapCatProcessTree)
    if ($tree.Count -eq 0) {
        Write-Line '  [NapCat] 没有发现 NapCat 相关进程（桌面版 QQ 未被触碰）。' 'DarkGray'
        return
    }

    $elevated = Test-IsElevated
    Write-Line ("  [NapCat] 待结束进程 {0} 个；当前面板{1}管理员权限。" -f `
            $tree.Count, $(if ($elevated) { '已具备' } else { '不具备' })) 'DarkGray'

    $okCount = 0
    $failMsg = @{}
    foreach ($id in $tree) {
        if (-not (Get-Process -Id $id -ErrorAction SilentlyContinue)) { continue }
        try {
            Stop-Process -Id $id -Force -ErrorAction Stop
            $okCount++
        }
        catch {
            $failMsg[$id] = $_.Exception.Message
        }
    }

    if ($failMsg.Count -gt 0) {
        Write-Line ("  [NapCat] 直接结束成功 {0} 个，失败 {1} 个。" -f $okCount, $failMsg.Count) 'Yellow'
        $shown = 0
        foreach ($k in $failMsg.Keys) {
            Write-Line ("  [NapCat]   PID {0} -> {1}" -f $k, $failMsg[$k]) 'Yellow'
            $shown++
            if ($shown -ge 5) { Write-Line '  [NapCat]   …（其余同类失败略）' 'DarkGray'; break }
        }
        $denied = @($failMsg.Keys | Where-Object { $failMsg[$_] -match '拒绝访问|Access is denied|not have sufficient|权限' })
        if ($denied.Count -gt 0 -and -not $elevated) {
            Write-Line '  [NapCat] NapCat 是提权启动的，普通权限无法结束它。' 'Yellow'
            Write-Line '  [NapCat] 正在请求管理员权限（会弹 UAC，请点"是"）…' 'Yellow'
            [void](Invoke-ElevatedKill -Pids $denied)
        }
        elseif ($denied.Count -gt 0 -and $elevated) {
            Write-Line '  [NapCat] 已是管理员仍被拒，可能是进程处于内核等待态，请稍后重试。' 'Red'
        }
    }
    else {
        Write-Line ("  [NapCat] 已结束 {0} 个 NapCat 相关进程（含渲染/GPU 子进程）。" -f $okCount) 'Green'
    }

    # 以「实际进程状态」为准做最终判定，而不是靠计数推测
    Start-Sleep -Milliseconds 800
    $remain = @(Get-NapCatProcessTree)
    $portFree = -not (Test-PortOpen -Port 6099)
    if ($remain.Count -eq 0) {
        Write-Line '  [NapCat] ✓ 已完全停止（无残留进程）。' 'Green'
    }
    else {
        Write-Line ("  [NapCat] ✗ 仍有 {0} 个进程在运行：{1}" -f $remain.Count, ($remain -join ', ')) 'Red'
        Write-Line '  [NapCat] 建议：右键「以管理员身份运行」控制面板后再试。' 'Yellow'
    }
    if ($portFree) {
        Write-Line '  [NapCat] 6099 端口已释放。' 'Green'
    }
    else {
        Write-Line '  [NapCat] 6099 仍被占用。' 'Red'
    }
}

# ------------------------------------------------------------------ 扫码登录前置
function Read-NapCatToken {
    <#  读 NapCat 的令牌。WebUI 与插件用的是同一个值（已对齐），
        以 napcat\config\webui.json 为准（launch.ps1 也是读它）。  #>
    $p = Join-Path $Root 'napcat\config\webui.json'
    if (-not (Test-Path -LiteralPath $p)) { return '' }
    try { return [string]((Get-Content -LiteralPath $p -Raw | ConvertFrom-Json).token) } catch { return '' }
}

function Get-PluginToken {
    $cfg = Join-Path $Root 'napcat\config\plugins\qq-miniapp-openauth\config.json'
    if (-not (Test-Path -LiteralPath $cfg)) { return $null }
    try { return (Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json).token } catch { return $null }
}

function Invoke-NapCatQqLogout {
    <#  让 NapCat 退出当前 QQ 登录。
        为什么需要它：扫码登录要求 NapCat 处于未登录状态才能拿到登录二维码；
        如果 NapCat 已经登录了某个 QQ，界面会显示「二维码不可用」，
        再点就报「登录工作流繁忙」。  #>
    $token = Get-PluginToken
    if (-not $token) {
        Write-Line '  [NapCat] 找不到插件 token（napcat\config\plugins\qq-miniapp-openauth\config.json）。' 'Red'
        return $false
    }
    $url = 'http://127.0.0.1:6099/plugin/qq-miniapp-openauth/api/logout'
    $text = Invoke-LocalJsonPost -Uri $url -Headers @{ Authorization = "Bearer $token" } -Body '{}'
    if ($text -like 'ERROR:*') {
        Write-Line "  [NapCat] 注销请求失败：$($text.Substring(7))" 'Red'
        return $false
    }
    try {
        $obj = $text | ConvertFrom-Json
        if ($obj.ok) {
            Write-Line "  [NapCat] 已退出 QQ 登录（方式：$($obj.method)）。" 'Green'
            return $true
        }
        Write-Line "  [NapCat] 注销被拒绝：$($obj.error)" 'Red'
        return $false
    }
    catch {
        Write-Line "  [NapCat] 注销响应无法解析：$text" 'Red'
        return $false
    }
}

function Test-PluginReady {
    <#  探测 NapCat 插件是否可用。
        返回 @{ Ok=..; Message=..; Methods=.. }
        /status 返回 503 且 message 含 "OneBot context" 时，说明 NapCat 核心没起来
        （通常是 QQ 会话残留 / 未登录），此时所有插件调用都会失败，
        扫码必然"点确认后没反应"。  #>
    $token = Get-PluginToken
    if (-not $token) { return [pscustomobject]@{ Ok = $false; Message = '找不到插件令牌'; Methods = @() } }
    $url = 'http://127.0.0.1:6099/plugin/qq-miniapp-openauth/api/status'
    $text = Invoke-LocalHttpGet -Uri $url -Headers @{ Authorization = "Bearer $token" } -TimeoutSec 8
    if ($text -like 'ERROR:*') {
        return [pscustomobject]@{ Ok = $false; Message = ('插件不可达：' + $text.Substring(7)); Methods = @() }
    }
    try {
        $o = $text | ConvertFrom-Json
        if ($o.ok -eq $true -and $o.ready -eq $true) {
            return [pscustomobject]@{ Ok = $true; Message = '插件就绪'; Methods = @($o.methods) }
        }
        return [pscustomobject]@{ Ok = $false; Message = ('插件未就绪（ready=false）：' + ($o.message -join ' ')); Methods = @() }
    }
    catch {
        # 503 时返回的是 {code:-1,message:"OneBot context not available"}
        $msg = $text
        try { $msg = [string]($text | ConvertFrom-Json).message } catch { }
        return [pscustomobject]@{ Ok = $false; Message = $msg; Methods = @() }
    }
}

function Reset-QqScanLogin {
    <#  扫码前的环境准备，并做「能不能真的扫码」的前置判断。
        新版（上游）的插件只有 QQ 已登录、NapCat 核心就绪时才可用；
        如果核心没起来，扫码点确认后不会有任何反应 —— 这里提前把原因讲清楚。  #>
    Write-Line '============ 准备 QQ 扫码登录 ============' 'Cyan'

    if (-not (Test-PortOpen -Port 6099)) {
        Write-Line '  NapCat 未运行（6099 未监听）。' 'Yellow'
        Write-Line '  请先在控制面板点「启动 NapCat」。' 'Yellow'
        return $false
    }

    # 先查最可能的元凶：桌面版 QQ 还开着
    $desktops = @(Get-DesktopQqProcesses)
    if ($desktops.Count -gt 0) {
        Write-Line "  ⚠ 桌面版 QQ 正在运行：$(Format-DesktopQqHint $desktops)" 'Yellow'
        Write-Line '    它会占用同一个 QQ 号的会话，NapCat 登录时 QQ 会直接回' 'Yellow'
        Write-Line '    「当前账号已登录，无法重复登录」——此时手机点确认不会有任何反应。' 'Yellow'
        Write-Line ''
        Write-Line '  ⇒ 请先完全退出桌面版 QQ（右下角托盘也要退出），然后：' 'White'
        Write-Line '      1) 点「停止 NapCat」' 'White'
        Write-Line '      2) 点「启动 NapCat」' 'White'
        Write-Line '      3) 再去「添加账号 → QQ扫码」' 'White'
        return $false
    }

    $ready = Test-PluginReady
    if (-not $ready.Ok) {
        Write-Line "  [1/2] 插件状态：$($ready.Message)" 'Yellow'
        # 有残留 QQ 是最常见的原因
        $tree = @(Get-NapCatProcessTree)
        if ($tree.Count -gt 0) {
            Write-Line "        检测到 $($tree.Count) 个 NapCat 相关进程仍在运行。" 'Yellow'
            Write-Line '        这通常意味着上次没停干净，QQ 会话残留。' 'Yellow'
        }
        Write-Line ''
        Write-Line '  ⇒ 请按这个顺序操作：' 'White'
        Write-Line '      1) 点「停止 NapCat」（会清掉整棵进程树）' 'White'
        Write-Line '      2) 等 3~5 秒，确认面板上 NapCat 变成「已停止」' 'White'
        Write-Line '      3) 点「启动 NapCat」，等它变「运行中」' 'White'
        Write-Line '      4) 再去「添加账号 → QQ扫码」' 'White'
        return $false
    }

    Write-Line '  [1/2] 插件就绪 ✓' 'Green'
    Write-Line '  [2/2] 让 NapCat 退出当前 QQ 登录…' 'Gray'
    $ok = Invoke-NapCatQqLogout
    Write-Line ''
    if ($ok) {
        Write-Line '  完成。现在去「添加账号 → QQ扫码」刷新二维码即可。' 'Green'
    }
    else {
        Write-Line '  注销未成功。若随后扫码报"已登录无法重复登录"，' 'Yellow'
        Write-Line '  请「停止 NapCat」→ 等几秒 → 再「启动 NapCat」做一次干净重启。' 'Yellow'
    }
    Write-Line '  提示：扫码取到 Code 后 NapCat 会自动注销。' 'DarkGray'
    return $ok
}

# ------------------------------------------------------------------ 依赖与构建
function Invoke-WorkspaceInstall {
    param($Repo)
    $pnpm = Join-Path $Root 'runtime\node\pnpm.cmd'
    if (-not (Test-Path -LiteralPath $pnpm)) {
        Write-Line '  [构建] 找不到自带 pnpm（runtime\node\pnpm.cmd）。' 'Red'
        return 1
    }
    Write-Line '  [构建] 安装依赖（国内镜像 registry.npmmirror.com）…' 'Gray'
    Push-Location $Repo.Dir
    $env:PATH = "$(Join-Path $Root 'runtime\node');$env:PATH"
    $env:COREPACK_ENABLE_DOWNLOAD_PROMPT = '0'
    & $pnpm install -r --registry=https://registry.npmmirror.com/
    $code = $LASTEXITCODE
    Pop-Location
    if ($code -ne 0) { Write-Line "  [构建] 依赖安装失败（返回码 $code）。" 'Red' }
    return $code
}

function Invoke-WorkspaceBuild {
    $pnpm = Join-Path $Root 'runtime\node\pnpm.cmd'
    if (-not (Test-Path -LiteralPath $pnpm)) {
        Write-Line '  [构建] 找不到自带 pnpm。' 'Red'
        return 1
    }
    Write-Line '  [构建] 构建前端（Vite，约 30 秒）…' 'Gray'
    Push-Location $Root
    $env:PATH = "$(Join-Path $Root 'runtime\node');$env:PATH"
    $env:COREPACK_ENABLE_DOWNLOAD_PROMPT = '0'
    & $pnpm build:web
    $code = $LASTEXITCODE
    Pop-Location
    if ($code -eq 0) { Write-Line '  [构建] 前端构建完成。' 'Green' }
    else { Write-Line "  [构建] 前端构建失败（返回码 $code）。" 'Red' }
    return $code
}

# ------------------------------------------------------------------ 更新上游
function Update-UpstreamRepos {
    Write-Line '================ 同步更新上游仓库 ================' 'Cyan'
    $git = Resolve-GitPath
    if (-not $git) {
        Write-Line '  找不到 git 可执行文件，无法更新。' 'Red'
        Write-Line '  本机没有独立安装的 Git；若 WorkBuddy 的 PortableGit 也被移除，' 'Yellow'
        Write-Line '  请自行安装 Git for Windows 后重试。' 'Yellow'
        return
    }
    Write-Line "  git: $git" 'DarkGray'
    Write-Line '先停止正在运行的服务（避免更新时文件被占用）…' 'Gray'
    Invoke-StopAll | Out-Null
    Start-Sleep -Milliseconds 600

    $changed = @()
    foreach ($repo in $Repos) {
        Write-Line "--- $($repo.Name)  ($($repo.Dir))" 'White'
        if (-not (Test-Path -LiteralPath (Join-Path $repo.Dir '.git'))) {
            Write-Line '  跳过：该目录不是 git 工作副本。' 'Yellow'
            continue
        }
        $before = ''
        try { $before = (& $git -C $repo.Dir rev-parse HEAD 2>$null) } catch { }
        if ($before) { $before = ([string]$before).Trim() }

        $fetched = $false
        foreach ($mirror in $Mirrors) {
            $url = "$mirror" + "https://github.com/$($repo.Owner)/$($repo.Repo).git"
            Write-Line "  尝试镜像: $mirror  分支: $($repo.Branch)" 'DarkGray'
            & $git fetch --depth 1 $url $repo.Branch 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $fetched = $true; break }
        }
        if (-not $fetched) {
            Write-Line '  所有镜像均不可用，本次跳过。' 'Red'
            continue
        }
        $after = ''
        try { $after = (& $git -C $repo.Dir rev-parse FETCH_HEAD 2>$null) } catch { }
        if ($after) { $after = ([string]$after).Trim() }

        if ($after -and $before -and $after -eq $before) {
            Write-Line "  已是最新版本（$($before.Substring(0, 8))）。" 'Green'
            continue
        }
        # ---- 本机补丁保护：reset --hard 会把唯一的补丁（store.js）一起覆盖 ----
        $storeRel = 'core/src/models/store.js'
        $storePath = Join-Path $repo.Dir $storeRel
        $patchFile = Join-Path $RunDir 'local-store.patch'
        $backupFile = Join-Path $RunDir 'store.js.before-update.bak'
        $hadPatch = $false
        if (Test-Path -LiteralPath $storePath) {
            try { $hadPatch = ((Get-Content -LiteralPath $storePath -Raw) -match '本机定制补丁') } catch { }
        }
        if ($hadPatch) {
            Copy-Item -LiteralPath $storePath -Destination $backupFile -Force -ErrorAction SilentlyContinue
            # 让 git 自己写文件：PowerShell 的 > 重定向会写成 UTF-16，git apply 读不了
            & $git -C $repo.Dir diff "--output=$patchFile" -- $storeRel 2>&1 | Out-Null
            Write-Line '  已备份本机补丁（store.js + local-store.patch）' 'DarkGray'
        }

        & $git reset --hard FETCH_HEAD 2>&1 | Out-Null
        $shortBefore = ''
        $shortAfter = ''
        if ($before) { $shortBefore = $before.Substring(0, 8) }
        if ($after) { $shortAfter = $after.Substring(0, 8) }
        Write-Line "  已更新：$shortBefore -> $shortAfter" 'Green'

        if ($hadPatch) {
            $now = ''
            try { $now = Get-Content -LiteralPath $storePath -Raw } catch { }
            if ($now -match '本机定制补丁') {
                Write-Line '  ✓ 本机补丁仍在（上游未改动该文件）' 'Green'
            }
            elseif ((Test-Path -LiteralPath $patchFile) -and (Get-Item -LiteralPath $patchFile).Length -gt 0) {
                & $git -C $repo.Dir apply --3way $patchFile 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Line '  ✓ 已自动重打本机补丁（store.js）' 'Green'
                    Remove-Item -LiteralPath $patchFile -Force -ErrorAction SilentlyContinue
                }
                else {
                    Write-Line '  ✗ 补丁重打失败：上游可能也改了 store.js，需要人工合并' 'Red'
                    Write-Line ("     备份：{0}" -f $backupFile) 'Yellow'
                    Write-Line ("     补丁：{0}" -f $patchFile) 'Yellow'
                    Write-Line '     未合并前「允许 QQ 扫码登录」开关重启后会回退。' 'Yellow'
                }
            }
            else {
                Write-Line '  ⚠ 没生成补丁文件，无法自动重打；请从备份恢复后手工核对' 'Yellow'
            }
        }
        $changed += $repo
    }

    if ($changed.Count -gt 0) {
        Write-Line ''
        Write-Line '================ 重新安装依赖并重建 ================' 'Cyan'
        foreach ($repo in $changed) {
            Write-Line "--- $($repo.Name)" 'White'
            Invoke-WorkspaceInstall -Repo $repo | Out-Null
            Invoke-WorkspaceBuild | Out-Null
        }
    }
    else {
        Write-Line '仓库已是线上最新版本，跳过重建。' 'Cyan'
    }

    Write-Line ''
    Write-Line '================ 重新启动服务 ================' 'Cyan'
    Invoke-StartAll | Out-Null
    Write-Line '更新流程结束。' 'Cyan'
}

# ------------------------------------------------------------------ 版本检测
$VersionRepos = @(
    [pscustomobject]@{
        Key = 'bot'; Name = 'QQ 农场主程序'; Owner = 'muyuewang'; Repo = 'qq-farm-bot-404'
        Dir = $Root; Branch = 'main'; PkgRel = 'core/package.json'
    }
)

function Get-PanelConfigHash {
    $h = @{}
    if (Test-Path -LiteralPath $PanelConfigFile) {
        try {
            $o = Get-Content -LiteralPath $PanelConfigFile -Raw | ConvertFrom-Json
            foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = $p.Value }
        }
        catch { }
    }
    return $h
}

function Save-PanelConfigHash {
    param([hashtable]$Hash)
    try {
        # PS 5.1 的 Set-Content -Encoding UTF8 会写 BOM，别的工具读了会报错
        $json = ($Hash | ConvertTo-Json -Depth 6)
        [System.IO.File]::WriteAllText($PanelConfigFile, $json, (New-Object System.Text.UTF8Encoding($false)))
        return $true
    }
    catch {
        Write-GuiLog "保存 panel.config.json 失败: $($_.Exception.Message)"
        return $false
    }
}

function Convert-IsoToLocal {
    param([string]$Iso)
    if (-not $Iso) { return '' }
    try { return ([datetime]::Parse($Iso)).ToLocalTime().ToString('yyyy-MM-dd HH:mm') }
    catch { return $Iso }
}

# ------------------------------------------------------------------ 版本溯源
# 固化后本地 HEAD 是自有提交，不能再用「本地 SHA ≠ 上游 SHA = 有更新」来判断，
# 否则永远显示"有新版本"。baseline.json 记录"我们基于哪个上游提交构建"，
# 只有「上游最新 ≠ 基线」才算上游有新版本。

$BaselineFile = Join-Path $Root 'baseline.json'

# 本机改动过的上游文件：生成差异报告时用来标「可能与自有改动冲突」
$LocalTouchedFiles = @(
    'core/client.js',
    'core/src/models/store.js',
    'core/src/models/user-store.js',
    'core/src/runtime/data-provider.js',
    'core/src/core/worker.js',
    'core/src/services/activity.js',
    'core/src/controllers/admin.js',
    'core/src/controllers/admin-session-manager.js',
    'core/src/controllers/admin-napcat-login-routes.js',
    'core/src/controllers/admin-user-routes.js',
    'core/src/controllers/admin-account-routes.js',
    'core/src/controllers/admin-public-info-routes.js'
)

function Get-Baseline {
    $def = [pscustomobject]@{
        schema      = 1
        upstream    = [pscustomobject]@{ owner = 'muyuewang'; repo = 'qq-farm-bot-404'; branch = 'main'; url = 'https://github.com/muyuewang/qq-farm-bot-404' }
        base        = [pscustomobject]@{ sha = ''; shortSha = ''; version = ''; date = ''; message = '' }
        local       = [pscustomobject]@{ version = ''; commit = ''; frozenAt = ''; changes = @() }
        syncHistory = @()
    }
    if (-not (Test-Path -LiteralPath $BaselineFile)) { return $def }
    try {
        $j = Get-Content -LiteralPath $BaselineFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $j.upstream) { $j | Add-Member -NotePropertyName upstream -NotePropertyValue $def.upstream -Force }
        if (-not $j.base) { $j | Add-Member -NotePropertyName base -NotePropertyValue $def.base -Force }
        if (-not $j.local) { $j | Add-Member -NotePropertyName local -NotePropertyValue $def.local -Force }
        if (-not $j.syncHistory) { $j | Add-Member -NotePropertyName syncHistory -NotePropertyValue @() -Force }
        return $j
    }
    catch {
        return $def
    }
}

function Get-BaselineRepo {
    $b = Get-Baseline
    return [pscustomobject]@{
        Key    = 'bot'
        Name   = 'QQ 农场主程序'
        Owner  = [string]$b.upstream.owner
        Repo   = [string]$b.upstream.repo
        Branch = [string]$b.upstream.branch
        Dir    = $Root
        PkgRel = 'core/package.json'
    }
}

function Format-ShortSha {
    param([string]$Sha)
    if (-not $Sha) { return '—' }
    if ($Sha.Length -ge 8) { return $Sha.Substring(0, 8) }
    return $Sha
}

function Update-BaselineAfterSync {
    <#  同步成功后回写来源记录：基线指向新提交，历史追加一条。  #>
    param(
        [string]$NewSha,
        [string]$NewVersion,
        [string]$LocalVersion,
        [string]$Method,
        [string]$Note = ''
    )
    $b = Get-Baseline
    $hist = @()
    foreach ($h in @($b.syncHistory)) { if ($h) { $hist += $h } }
    $hist += [pscustomobject]@{
        syncedAt     = (Get-Date).ToString('o')
        fromSha      = [string]$b.base.sha
        toSha        = $NewSha
        toVersion    = $NewVersion
        localVersion = $LocalVersion
        method       = $Method
        note         = $Note
    }
    $obj = [pscustomobject]@{
        schema   = 1
        upstream = $b.upstream
        base     = [pscustomobject]@{
            sha      = $NewSha
            shortSha = Format-ShortSha $NewSha
            version  = $NewVersion
            date     = (Get-Date).ToString('o')
            message  = 'synced from upstream'
        }
        local    = [pscustomobject]@{
            version   = $LocalVersion
            commit    = [string]$b.local.commit
            frozenAt  = [string]$b.local.frozenAt
            changes   = @($b.local.changes)
        }
        syncHistory = $hist
    }
    $json = $obj | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($BaselineFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    return $obj
}

function Show-UpstreamDiff {
    <#  拉取「基线..上游最新」的差异，生成 panel\run\upstream-diff.md。
        只读：不 fetch、不改代码、不动 git 状态。  #>
    param([switch]$OpenReport)
    $b = Get-Baseline
    $repo = Get-BaselineRepo
    $baseSha = [string]$b.base.sha

    Write-Line '============ 上游差异（基线 → 最新） ============' 'Cyan'
    Write-Line ("  基线：{0}  v{1}  {2}" -f (Format-ShortSha $baseSha), $b.base.version, $b.base.date) 'Gray'

    $head = Get-RemoteVersionInfo -Repo $repo
    if (-not $head.ShaFull) {
        Write-Line '  ✗ 取不到上游最新提交（网络或镜像不可用）' 'Red'
        return 2
    }
    Write-Line ("  上游：{0}  v{1}  {2}" -f (Format-ShortSha $head.ShaFull), $head.Version, $head.Date) 'Gray'

    if ($baseSha -and $head.ShaFull -eq $baseSha) {
        Write-Line '  ✓ 上游自基线以来没有新提交，无需同步' 'Green'
        return 0
    }

    $cmp = $null
    foreach ($m in $Mirrors) {
        $api = "$m" + "https://api.github.com/repos/$($repo.Owner)/$($repo.Repo)/compare/$baseSha...$($head.ShaFull)"
        $txt = Invoke-RemoteText -Uri $api -TimeoutSec 30
        if (-not $txt) { continue }
        try { $cmp = $txt | ConvertFrom-Json; break } catch { }
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('# 上游差异报告')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine(('- 生成时间：' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')))
    [void]$sb.AppendLine(('- 基线：`' + $baseSha + '`  v' + $b.base.version + '  ' + $b.base.date))
    [void]$sb.AppendLine(('- 上游最新：`' + $head.ShaFull + '`  v' + $head.Version + '  ' + $head.Date))
    [void]$sb.AppendLine(('- 本地版本：v' + $b.local.version))
    [void]$sb.AppendLine('')

    $commitCount = 0
    $riskKnown = $false
    if ($cmp -and $cmp.commits) {
        $commitCount = @($cmp.commits).Count
        $riskKnown = [bool]($cmp.files)
        [void]$sb.AppendLine('## 新增提交（' + $commitCount + ' 个）')
        [void]$sb.AppendLine('')
        foreach ($c in @($cmp.commits)) {
            $msg = ([string]$c.commit.message) -split "`n"
            [void]$sb.AppendLine(('- `' + ([string]$c.sha).Substring(0, 7) + '`  ' + (Convert-IsoToLocal ([string]$c.commit.committer.date)) + '  ' + $msg[0]))
        }
        [void]$sb.AppendLine('')
    }
    else {
        [void]$sb.AppendLine('> ⚠ compare 接口不可用（可能镜像不支持 api.github.com），**拿不到提交列表与文件清单**。')
        [void]$sb.AppendLine('> 只有一个上游最新提交：')
        [void]$sb.AppendLine('>')
        [void]$sb.AppendLine('> `' + $head.ShaFull + '`  ' + $head.Message)
        [void]$sb.AppendLine('>')
        [void]$sb.AppendLine('> 这种情况下**不要**直接同步：请先在浏览器打开上游仓库，人工对比后再决定。')
        [void]$sb.AppendLine('')
    }

    $risk = @()
    if ($cmp -and $cmp.files) {
        $files = @($cmp.files)
        [void]$sb.AppendLine('## 变更文件（' + $files.Count + ' 个）')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('| 文件 | 变更 | +/- | 与自有改动重叠 |')
        [void]$sb.AppendLine('|---|---|---|---|')
        foreach ($f in $files) {
            $name = [string]$f.filename
            $overlap = $LocalTouchedFiles -contains $name
            if ($overlap) { $risk += $name }
            $mark = if ($overlap) { '⚠ **是**' } else { '否' }
            [void]$sb.AppendLine(('| `' + $name + '` | ' + $f.status + ' | +' + $f.additions + '/-' + $f.deletions + ' | ' + $mark + ' |'))
        }
        [void]$sb.AppendLine('')
    }

    [void]$sb.AppendLine('## 同步建议')
    [void]$sb.AppendLine('')
    if (-not $riskKnown) {
        [void]$sb.AppendLine('⚠ **未能获取文件清单**，无法判断是否会与自有改动冲突。')
        [void]$sb.AppendLine('建议先人工比对上游仓库，再决定是否同步。')
        [void]$sb.AppendLine('')
    }
    elseif ($risk.Count -gt 0) {
        [void]$sb.AppendLine('以下文件**同时被上游与本机改过**，同步时极可能冲突，必须人工确认：')
        [void]$sb.AppendLine('')
        foreach ($r in $risk) { [void]$sb.AppendLine('- `' + $r + '`') }
        [void]$sb.AppendLine('')
    }
    else {
        [void]$sb.AppendLine('上游改动与自有改动没有文件级重叠，冲突风险低。')
        [void]$sb.AppendLine('')
    }
    [void]$sb.AppendLine('> 同步只会执行 `git apply --3way`（上游补丁），**不会** reset / checkout 覆盖自有改动；')
    [void]$sb.AppendLine('> 一旦冲突会立即回滚到同步前的备份 tag。')

    $diffPath = Join-Path $RunDir 'upstream-diff.md'
    [System.IO.File]::WriteAllText($diffPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    Write-Line ("  ✓ 差异报告：$diffPath") 'Green'
    if ($riskKnown) {
        Write-Line ("     新增提交 $commitCount 个；重叠风险文件 $($risk.Count) 个") 'Gray'
    }
    else {
        Write-Line ("     新增提交 $commitCount 个；重叠风险：**无法判断**（compare 接口不可用）") 'Yellow'
        Write-Line '     不要直接同步：先人工比对上游仓库。' 'Yellow'
    }
    if ($risk.Count -gt 0) {
        foreach ($r in $risk) { Write-Line ("     ⚠ " + $r) 'Yellow' }
    }
    if ($OpenReport) { Start-Process notepad.exe $diffPath }
    return 0
}

function Invoke-UpstreamSync {
    <#  受控同步：上游补丁 git apply --3way，冲突立即回滚。
        三条硬约束：
          1) 必须显式 -ConfirmSync（面板按钮会再弹一次确认）；
          2) 必须先生成 24 小时内的差异报告（强制"先看再同步"）；
          3) 工作树必须干净；失败一律 reset 回备份 tag，绝不覆盖自有改动。  #>
    param([switch]$ConfirmSync)
    if (-not $ConfirmSync) {
        Write-Line '  [拒绝] 同步需要显式确认：-Action syncupstream -ConfirmSync' 'Red'
        return 3
    }
    $b = Get-Baseline
    $repo = Get-BaselineRepo
    $baseSha = [string]$b.base.sha
    if (-not $baseSha) {
        Write-Line '  [拒绝] baseline.json 里没有基线提交，无法同步' 'Red'
        return 3
    }

    $git = Resolve-GitPath
    if (-not $git) { Write-Line '  [拒绝] 找不到 git 可执行文件' 'Red'; return 2 }

    $diffFile = Join-Path $RunDir 'upstream-diff.md'
    if (-not (Test-Path -LiteralPath $diffFile)) {
        Write-Line '  [拒绝] 还没有差异报告。请先点「查看差异」，确认后再同步。' 'Red'
        return 3
    }
    if ((Get-Item -LiteralPath $diffFile).LastWriteTime -lt (Get-Date).AddHours(-24)) {
        Write-Line '  [拒绝] 差异报告超过 24 小时，可能已过期。请重新点「查看差异」。' 'Red'
        return 3
    }

    $dirty = @(& $git -C $Root status --porcelain --untracked-files=no 2>$null)
    if ($dirty.Count -gt 0) {
        Write-Line '  [拒绝] 工作树有未提交改动，先提交或还原：' 'Red'
        $dirty | Select-Object -First 8 | ForEach-Object { Write-Line ('         ' + $_) 'Yellow' }
        return 3
    }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backupTag = "pre-sync-$stamp"
    & $git -C $Root tag $backupTag 2>&1 | Out-Null
    Write-Line ("  ✓ 备份 tag：$backupTag（出问题用它回滚）") 'Green'

    $fetched = $false
    foreach ($m in $Mirrors) {
        $url = "$m" + "https://github.com/$($repo.Owner)/$($repo.Repo).git"
        Write-Line ("  拉取上游：$m") 'Gray'
        & $git -C $Root fetch --depth 1 $url $repo.Branch 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $fetched = $true; break }
    }
    if (-not $fetched) {
        Write-Line '  ✗ 所有镜像都拉取失败，未做任何改动' 'Red'
        return 2
    }

    $newSha = [string]((& $git -C $Root rev-parse FETCH_HEAD 2>$null)).Trim()
    if (-not $newSha) { Write-Line '  ✗ 取不到上游提交' 'Red'; return 2 }
    if ($newSha -eq $baseSha) {
        Write-Line '  ✓ 上游就是基线，无需同步' 'Green'
        return 0
    }
    Write-Line ("  上游最新：$(Format-ShortSha $newSha)（基线 $(Format-ShortSha $baseSha)）") 'Gray'

    # 生成补丁（只取上游改动，不含自有提交）
    $patchFile = Join-Path $RunDir "upstream-sync-$stamp.patch"
    & $git -C $Root diff --binary $baseSha $newSha > $patchFile 2>$null
    if (-not (Test-Path -LiteralPath $patchFile)) {
        Write-Line '  ✗ 生成补丁失败' 'Red'
        return 2
    }
    $patchSize = (Get-Item -LiteralPath $patchFile).Length
    Write-Line ("  补丁：$patchFile（$([math]::Round($patchSize/1MB,2)) MB）") 'Gray'
    if ($patchSize -le 0) {
        Write-Line '  ✓ 上游没有实际文件变更' 'Green'
        return 0
    }

    # 预检：有冲突就停，不写工作树
    & $git -C $Root apply --check --3way $patchFile 2>&1 | ForEach-Object { Write-Line ('    ' + $_) 'Yellow' }
    if ($LASTEXITCODE -ne 0) {
        Write-Line '  ✗ 预检发现冲突，已停止（工作树未被修改）' 'Red'
        Write-Line '     请按差异报告手工合并后重试。' 'Yellow'
        return 4
    }

    & $git -C $Root apply --3way $patchFile 2>&1 | ForEach-Object { Write-Line ('    ' + $_) 'Gray' }
    if ($LASTEXITCODE -ne 0) {
        Write-Line '  ✗ 应用失败，回滚到备份 tag（未覆盖自有改动）' 'Red'
        & $git -C $Root reset --hard $backupTag 2>&1 | Out-Null
        return 4
    }

    # 版本号：上游版本 + local.N
    $newBaseVersion = if ($head = Get-RemoteVersionInfo -Repo $repo) { [string]$head.Version } else { '' }
    if (-not $newBaseVersion) { $newBaseVersion = [string]$b.base.version }
    $n = 1
    if ([string]$b.local.version -match '-local\.(\d+)$') { $n = [int]$Matches[1] + 1 }
    $newLocalVersion = "$newBaseVersion-local.$n"

    # 写回版本号（保持 JSON 缩进格式）
    foreach ($rel in @('core/package.json', 'web/package.json')) {
        $p = Join-Path $Root $rel
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $raw = [System.IO.File]::ReadAllText($p)
        $raw = [regex]::Replace($raw, '("version"\s*:\s*")[^"]+(")', ('${1}' + $newLocalVersion + '${2}'), 1)
        [System.IO.File]::WriteAllText($p, $raw, (New-Object System.Text.UTF8Encoding($false)))
    }

    Update-BaselineAfterSync -NewSha $newSha -NewVersion $newBaseVersion -LocalVersion $newLocalVersion -Method 'git apply --3way' -Note 'upstream patch applied on top of local commits' | Out-Null

    & $git -C $Root add -A 2>&1 | Out-Null
    & $git -C $Root commit -q -m "chore(release): sync upstream to $(Format-ShortSha $newSha) ($newLocalVersion)" 2>&1 | Out-Null
    & $git -C $Root tag "local-sync-$stamp" 2>&1 | Out-Null

    Write-Line '' 
    Write-Line ("  ✓ 同步完成：基线 $(Format-ShortSha $baseSha) → $(Format-ShortSha $newSha)") 'Green'
    Write-Line ("     本地版本：$newLocalVersion") 'Green'
    Write-Line ("     已记录到 baseline.json；备份 tag $backupTag 保留") 'Gray'
    Write-Line '     需要重启主程序让代码生效（面板「重启主程序」）。' 'Yellow'
    return 0
}

function Get-LocalVersionInfo {
    param($Repo)
    $info = [pscustomobject]@{
        Version = ''; Sha = ''; ShaFull = ''; Date = ''; Dirty = $null
    }
    try {
        $pkg = Join-Path $Repo.Dir $Repo.PkgRel
        if (Test-Path -LiteralPath $pkg) {
            $info.Version = [string](Get-Content -LiteralPath $pkg -Raw | ConvertFrom-Json).version
        }
    }
    catch { }
    # 提交号：优先直接读 .git 的松散 ref（不需要 git 命令）
    try {
        $gitDir = Join-Path $Repo.Dir '.git'
        $headFile = Join-Path $gitDir 'HEAD'
        if (Test-Path -LiteralPath $headFile) {
            $head = ([System.IO.File]::ReadAllText($headFile)).Trim()
            if ($head -like 'ref:*') {
                $refRel = $head.Substring(4).Trim()
                $refFile = Join-Path $gitDir ($refRel -replace '/', '\')
                if (Test-Path -LiteralPath $refFile) {
                    $sha = ([System.IO.File]::ReadAllText($refFile)).Trim()
                    if ($sha) { $info.ShaFull = $sha }
                }
            }
            elseif ($head.Length -ge 40) {
                $info.ShaFull = $head
            }
        }
    }
    catch { }
    $git = Resolve-GitPath
    if ($git) {
        if (-not $info.ShaFull) {
            try {
                $s = (& $git -C $Repo.Dir rev-parse HEAD 2>$null)
                if ($s) { $info.ShaFull = ([string]$s).Trim() }
            }
            catch { }
        }
        try {
            $d = (& $git -C $Repo.Dir log -1 --format=%cI 2>$null)
            if ($d) { $info.Date = Convert-IsoToLocal ([string]$d).Trim() }
        }
        catch { }
        try {
            # --untracked-files=no：只看已跟踪文件有没有本地改动
            $st = @(& $git -C $Repo.Dir status --porcelain --untracked-files=no 2>$null)
            $info.Dirty = ($st.Count -gt 0)
        }
        catch { }
    }
    if ($info.ShaFull -and $info.ShaFull.Length -ge 8) { $info.Sha = $info.ShaFull.Substring(0, 8) }
    return $info
}

function Get-RemoteVersionInfo {
    param($Repo)
    $info = [pscustomobject]@{
        Version = ''; Sha = ''; ShaFull = ''; Date = ''; Message = ''; Url = ''; Source = ''
    }
    $gotCommit = $false
    foreach ($m in $Mirrors) {
        $api = "$m" + "https://api.github.com/repos/$($Repo.Owner)/$($Repo.Repo)/commits/$($Repo.Branch)"
        $txt = Invoke-RemoteText -Uri $api -TimeoutSec 20
        if (-not $txt) { continue }
        try {
            $j = $txt | ConvertFrom-Json
            if ($j.sha) {
                $info.ShaFull = [string]$j.sha
                if ($info.ShaFull.Length -ge 8) { $info.Sha = $info.ShaFull.Substring(0, 8) }
                $info.Date = Convert-IsoToLocal ([string]$j.commit.committer.date)
                $info.Message = (([string]$j.commit.message) -split "`n")[0]
                $info.Url = [string]$j.html_url
                $info.Source = 'api'
                $gotCommit = $true
                break
            }
        }
        catch { }
    }
    if (-not $gotCommit) {
        $git = Resolve-GitPath
        if ($git) {
            foreach ($m in $Mirrors) {
                $url = "$m" + "https://github.com/$($Repo.Owner)/$($Repo.Repo).git"
                $out = @(& $git ls-remote --heads $url $Repo.Branch 2>$null | Select-Object -First 1)
                if ($out.Count -gt 0) {
                    $sha = ([string]$out[0]).Split("`t")[0].Trim()
                    if (-not $sha) { $sha = (([string]$out[0]) -split '\s+')[0] }
                    if ($sha) {
                        $info.ShaFull = $sha
                        if ($sha.Length -ge 8) { $info.Sha = $sha.Substring(0, 8) }
                        $info.Source = 'ls-remote'
                        break
                    }
                }
            }
        }
    }
    foreach ($m in $Mirrors) {
        $raw = "$m" + "https://raw.githubusercontent.com/$($Repo.Owner)/$($Repo.Repo)/$($Repo.Branch)/$($Repo.PkgRel)"
        $txt = Invoke-RemoteText -Uri $raw -TimeoutSec 20
        if (-not $txt) { continue }
        try {
            $v = [string](($txt | ConvertFrom-Json).version)
            if ($v) { $info.Version = $v; break }
        }
        catch { }
    }
    return $info
}

function Update-VersionCheck {
    <#  真正干活的函数，由 `-Action checkversion` 在独立进程里执行，
        结果写到 run\version-check.json，GUI 只读文件 —— 避免网络请求阻塞 UI 线程。  #>
    if (Test-Path -LiteralPath $VersionLockFile) {
        $age = (Get-Date) - (Get-Item -LiteralPath $VersionLockFile).LastWriteTime
        if ($age.TotalSeconds -lt 300) {
            Write-Line '  已有一个版本检测在进行中，本次跳过。' 'DarkGray'
            return
        }
    }
    Set-Content -LiteralPath $VersionLockFile -Value (Get-Date).ToString('o') -Encoding ascii
    try {
        $entries = @()
        foreach ($r in $VersionRepos) {
            Write-Line "  检测 $($r.Name) …" 'Gray'
            $lv = Get-LocalVersionInfo -Repo $r
            $rv = $null
            $err = $null
            try { $rv = Get-RemoteVersionInfo -Repo $r }
            catch { $err = $_.Exception.Message }

            # 版本溯源：比较的是「上游最新 vs 基线」，而不是「上游 vs 本地 HEAD」。
            # 固化后本地 HEAD 是自有提交（cc683547…），拿它比会永远显示"有更新"。
            $baseline = Get-Baseline
            $baseSha = [string]$baseline.base.sha
            $baseVersion = [string]$baseline.base.version
            $behind = $false
            if ($rv -and $rv.ShaFull) {
                if ($baseSha) {
                    $behind = ($rv.ShaFull -ne $baseSha)
                }
                else {
                    $err = 'baseline.json 缺少 base.sha，无法判断上游是否有新版本'
                }
            }
            if ($err -or -not ($rv -and $rv.ShaFull)) {
                $behind = $false
                if (-not $err) { $err = '未能获取上游信息（网络或镜像不可用）' }
            }

            $entries += [pscustomobject]@{
                key = $r.Key; name = $r.Name
                localVersion = $lv.Version; localSha = $lv.Sha; localDate = $lv.Date; localDirty = $lv.Dirty
                baseVersion = $baseVersion
                baseSha = (Format-ShortSha $baseSha)
                baseDate = [string]$baseline.base.date
                remoteVersion = $(if ($rv) { $rv.Version } else { '' })
                remoteSha = $(if ($rv) { $rv.Sha } else { '' })
                remoteDate = $(if ($rv) { $rv.Date } else { '' })
                remoteMessage = $(if ($rv) { $rv.Message } else { '' })
                remoteUrl = $(if ($rv) { $rv.Url } else { '' })
                source = $(if ($rv) { $rv.Source } else { '' })
                behind = $behind
                error = $err
            }
            if ($behind) { Write-Line "    -> 上游有新版本（基线 $(Format-ShortSha $baseSha) → 上游 $($rv.Sha)）" 'Yellow' }
            elseif ($err) { Write-Line "    -> $err" 'Red' }
            else { Write-Line '    -> 已与基线一致（无上游更新）' 'Green' }
        }
        $payload = [pscustomobject]@{
            startedAt = (Get-Date).ToString('o')
            finishedAt = (Get-Date).ToString('o')
            hasUpdate = (@($entries | Where-Object { $_.behind }).Count -gt 0)
            anyError = (@($entries | Where-Object { $_.error }).Count -gt 0)
            repos = $entries
        }
        # 无 BOM 的 UTF-8
        $json = ($payload | ConvertTo-Json -Depth 8)
        [System.IO.File]::WriteAllText($VersionStateFile, $json, (New-Object System.Text.UTF8Encoding($false)))
        Write-Line '  版本检测完成。' 'Green'
    }
    finally {
        Remove-Item -LiteralPath $VersionLockFile -Force -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------------ 汇总动作
function Invoke-StartAll {
    Write-Line '================ 启动主程序 ================' 'Cyan'
    Start-FarmService | Out-Null
    Write-Line ''
    Show-StatusTable
}

function Invoke-StopAll {
    # 本机定制：只停主程序，**不碰 NapCat / QQ 进程**。
    # NapCat 注入在 QQ.exe 里运行，结束它会连带结束 QQ；用户明确要求
    # 「停止」按钮不得停掉正在运行的 QQ。要停 NapCat 请用单独的按钮。
    Write-Line '================ 停止主程序 ================' 'Cyan'
    Stop-FarmService
}

function New-DesktopShortcut {
    <#  在桌面创建「控制面板」快捷方式 —— 只打开本面板，不启动任何服务。
        （启动服务用的快捷方式由安装器创建，指向 启动-静默.vbs，是另一个文件。）  #>
    $desktop = [Environment]::GetFolderPath('Desktop')
    if (-not $desktop) { $desktop = Join-Path $env:USERPROFILE 'Desktop' }
    $lnkPath = Join-Path $desktop 'QQ农场助手（活动自动化版）· 控制面板.lnk'
    $panelPath = Join-Path $PanelDir 'panel.ps1'
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    try {
        $shell = New-Object -ComObject WScript.Shell
        $lnk = $shell.CreateShortcut($lnkPath)
        $lnk.TargetPath = $psExe
        $lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + $panelPath + '"'
        $lnk.WorkingDirectory = $Root
        $ico = Join-Path $PanelDir 'panel.ico'
        if (Test-Path -LiteralPath $ico) { $lnk.IconLocation = "$ico,0" }
        $lnk.Description = '打开 QQ农场助手控制面板（不启动服务）'
        $lnk.Save()
        Write-Line "  已创建「控制面板」快捷方式：$lnkPath" 'Green'
        Write-Line '  （它只打开面板；启动服务请用桌面的启动快捷方式）' 'DarkGray'
    }
    catch {
        Write-Line "  创建快捷方式失败：$($_.Exception.Message)" 'Red'
    }
}

# ================= Web 控制面板（监听端口，局域网可访问） =================
#  设计要点：
#   1) 用 TcpListener 自己实现极简 HTTP/1.1，而不用 HttpListener ——
#      HttpListener 绑定非 localhost 需要 URL ACL（管理员 netsh http add urlacl），
#      否则普通用户启动直接 AccessDenied；TcpListener 无此限制。
#   2) 只做进程启停与状态展示，不复刻 WinForms 面板的全部功能（版本同步/构建等
#      高危操作仍只在主机本地 GUI 里）。
#   3) 启停动作交给子进程 panel.ps1 -Action xxx 执行，Web 主循环不被阻塞
#      （Start-NapCatService 会等 UAC，可能阻塞几十秒）。

function Get-PanelAddressList {
    $out = @()
    try {
        foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($ni.OperationalStatus -ne 'Up') { continue }
            if ($ni.NetworkInterfaceType -eq 'Loopback') { continue }
            $props = $ni.GetIPProperties()
            foreach ($ua in $props.UnicastAddresses) {
                if ($ua.Address.AddressFamily -ne 'InterNetwork') { continue }
                $ip = $ua.Address.ToString()
                if ($ip.StartsWith('169.254.')) { continue }
                $out += $ip
            }
        }
    }
    catch { }
    return $out
}

function Test-PrivateIp {
    <#  只接受回环与 RFC1918 私网地址。面板会启停进程，绝不能因为
        误绑公网/端口映射就变成公网可操作。  #>
    param([string]$Ip)
    if (-not $Ip) { return $false }
    if ($Ip -eq '::1' -or $Ip -eq '127.0.0.1') { return $true }
    if ($Ip.StartsWith('::ffff:')) { $Ip = $Ip.Substring(7) }
    $parts = $Ip -split '\.'
    if ($parts.Count -ne 4) { return $false }
    $a = 0; $b = 0
    try { $a = [int]$parts[0]; $b = [int]$parts[1] } catch { return $false }
    if ($a -eq 127) { return $true }
    if ($a -eq 10) { return $true }
    if ($a -eq 192 -and $b -eq 168) { return $true }
    if ($a -eq 172 -and $b -ge 16 -and $b -le 31) { return $true }
    return $false
}

function Get-WebLogTail {
    <#  必须用 .NET 读，不能 Get-Content：
        Get-Content 返回的字符串带 PSPath / PSDrive / PSProvider 等 NoteProperty，
        ConvertTo-Json 会把整条 PowerShell Provider 对象图一起序列化 ——
        实测每行膨胀到 25 KB，59 行日志变成 22 MB 且耗时 5 秒以上。  #>
    param([int]$Lines = 120)
    if (-not (Test-Path -LiteralPath $GuiLogPath)) { return @() }
    $fs = $null
    $sr = $null
    try {
        $fs = New-Object System.IO.FileStream($GuiLogPath,
            [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        $all = New-Object 'System.Collections.Generic.List[string]'
        while ($null -ne ($line = $sr.ReadLine())) { $all.Add($line) }
        $take = [Math]::Min($Lines, $all.Count)
        if ($take -le 0) { return @() }
        return @($all.GetRange($all.Count - $take, $take))
    }
    catch { return @() }
    finally {
        if ($sr) { try { $sr.Close() } catch { } }
        if ($fs) { try { $fs.Close() } catch { } }
    }
}


function Get-NapCatLogTail {
    <#  NapCat 日志窗口用：取最新一份日志的尾部。
        用 .NET FileStream 直接从文件尾读（FileShare=ReadWrite），绕开
        Get-Content -Tail 在“文件正被其它进程写入”时的不确定行为。  #>
    param([int]$Lines = 120)
    $dir = Join-Path (Join-Path $Root 'napcat') 'logs'
    $best = $null
    try {
        $cands = @(Get-ChildItem -LiteralPath $dir -Filter '*.log' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'launcher-console.log' })
        $launchLog = Join-Path $Root 'napcat-launch.log'
        if (Test-Path -LiteralPath $launchLog) {
            $cands += @(Get-Item -LiteralPath $launchLog)
        }
        $best = @($cands | Sort-Object LastWriteTime -Descending)[0]
    }
    catch { }
    if (-not $best) { return @{ file = ''; lines = @() } }
    $out = @()
    try {
        $share = [System.IO.FileShare]([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        $fs = [System.IO.File]::Open($best.FullName,
            [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
        try {
            $len = [int][Math]::Min($best.Length, 65536)
            $buf = New-Object byte[] $len
            if ($len -gt 0) {
                [void]$fs.Seek(-$len, [System.IO.SeekOrigin]::End)
                [void]$fs.Read($buf, 0, $len)
            }
            $text = [System.Text.Encoding]::UTF8.GetString($buf)
            $all = @($text -split "`r?`n" | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_.Trim() -ne '' })
            if ($all.Count -gt $Lines) { $all = $all[($all.Count - $Lines)..($all.Count - 1)] }
            $out = $all
        }
        finally { $fs.Close() }
    }
    catch {
        $out = @('（读取 NapCat 日志失败：' + $_.Exception.Message + '）')
    }
    return @{ file = $best.Name; lines = $out }
}

function Get-WebStatusObject {
    param([string]$Bind, [int]$Port, [datetime]$StartedAt)
    $portSet = Get-ListeningPortSet
    $svcOut = [ordered]@{}
    foreach ($s in $Services) {
        $running = $false
        $ports = @()
        foreach ($p in $s.Ports) {
            $on = $portSet.Contains($p)
            if ($on) { $running = $true }
            $ports += [ordered]@{ port = $p; listening = $on }
        }
        $procId = 0
        $uptime = $null
        if (Test-Path -LiteralPath $s.PidFile) {
            try {
                $parts = (Get-Content -LiteralPath $s.PidFile -Raw).Trim() -split '\|'
                $rec = [int]$parts[0]
                $proc = Get-Process -Id $rec -ErrorAction SilentlyContinue
                if ($proc) {
                    $procId = $rec
                    try { $uptime = [int]((Get-Date) - $proc.StartTime).TotalSeconds } catch { }
                }
            }
            catch { }
        }
        $svcOut[$s.Key] = [ordered]@{
            name = $s.Name; running = $running; pid = $procId; uptimeSec = $uptime; ports = $ports
        }
    }

    $accounts = @()
    $accFile = Join-Path (Join-Path $Root 'data') 'accounts.json'
    if (Test-Path -LiteralPath $accFile) {
        try {
            $raw = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $accFile -Raw -Encoding UTF8)
            if ($raw -and $raw.accounts) {
                foreach ($a in $raw.accounts) {
                    $accounts += [ordered]@{
                        id = [string]$a.id; name = [string]$a.name; platform = [string]$a.platform
                    }
                }
            }
        }
        catch { }
    }

    $version = ''
    try {
        $corePkg = ConvertFrom-Json -InputObject (Get-Content -LiteralPath (Join-Path $Root 'core\package.json') -Raw -Encoding UTF8)
        $version = [string]$corePkg.version
    }
    catch { }

    $addrList = @(Get-PanelAddressList)
    $logLines = @(Get-WebLogTail -Lines 120)
    $up = 0
    try { $up = [int]((Get-Date) - $StartedAt).TotalSeconds } catch { $up = 0 }
    # 主程序 Web 面板端口：给前端拼「打开主程序面板」按钮的地址
    $mainUiPort = 3007
    $farmSvc = Get-ServiceByKey -Key 'farm'
    if ($farmSvc -and $farmSvc.Ports.Count -gt 0) { $mainUiPort = [int]$farmSvc.Ports[0] }
    # NapCat WebUI 接入信息（端口 / 令牌读自 napcat\config\webui.json）
    $ncPort = 6099
    $ncToken = ''
    $ncHost = '127.0.0.1'
    $webuiCfg = Join-Path (Join-Path $Root 'napcat') 'config\webui.json'
    if (Test-Path -LiteralPath $webuiCfg) {
        try {
            $nc = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $webuiCfg -Raw -Encoding UTF8)
            if ($nc.port) { $ncPort = [int]$nc.port }
            if ($nc.token) { $ncToken = [string]$nc.token }
            if ($nc.host) { $ncHost = [string]$nc.host }
        }
        catch { }
    }
    $ncListening = $portSet.Contains($ncPort)
    $ncLogInfo = Get-NapCatLogTail -Lines 120
    $qqInfo = Get-UpstreamQqInfo
    $ncCoreVersion = Get-NapCatVersion

    return [ordered]@{
        ok       = $true
        server   = [ordered]@{
            host       = $env:COMPUTERNAME
            version    = $version
            bind       = $Bind
            port       = $Port
            mainUiPort = $mainUiPort
            addresses  = $addrList
            localUrl   = "http://127.0.0.1:$Port"
            uptimeSec  = $up
            time       = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        }
        services = $svcOut
        napcat   = [ordered]@{
            webuiPort  = $ncPort
            token      = $ncToken
            host       = $ncHost
            listening  = $ncListening
            logFile    = [string]$ncLogInfo.file
            log        = @($ncLogInfo.lines)
            qqPath     = [string]$qqInfo.path
            qqVersion  = [string]$qqInfo.version
            coreVersion = [string]$ncCoreVersion
        }
        accounts = $accounts
        logPath  = $GuiLogPath
        log      = $logLines
    }
}

function Read-HttpRequest {
    param($Stream)
    $buf = New-Object byte[] 8192
    $ms = New-Object System.IO.MemoryStream
    $deadline = (Get-Date).AddSeconds(8)
    $headerEnd = -1
    while ($headerEnd -lt 0) {
        if ((Get-Date) -gt $deadline) { break }
        if (-not $Stream.DataAvailable) { Start-Sleep -Milliseconds 20; continue }
        $n = $Stream.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
        $ms.Write($buf, 0, $n)
        $arr0 = $ms.ToArray()
        for ($i = 3; $i -lt $arr0.Length; $i++) {
            if ($arr0[$i - 3] -eq 13 -and $arr0[$i - 2] -eq 10 -and $arr0[$i - 1] -eq 13 -and $arr0[$i] -eq 10) {
                $headerEnd = $i + 1; break
            }
        }
        if ($ms.Length -gt 262144) { break }
    }
    if ($headerEnd -lt 0) { return $null }

    $all = $ms.ToArray()
    $headText = [System.Text.Encoding]::ASCII.GetString($all, 0, $headerEnd)
    $lines = $headText -split "`r`n"
    $reqLine = $lines[0] -split ' '
    if ($reqLine.Length -lt 2) { return $null }

    $headers = @{}
    for ($i = 1; $i -lt $lines.Length; $i++) {
        $ln = $lines[$i]
        if (-not $ln) { continue }
        $idx = $ln.IndexOf(':')
        if ($idx -le 0) { continue }
        $headers[$ln.Substring(0, $idx).Trim().ToLower()] = $ln.Substring($idx + 1).Trim()
    }

    $bodyLen = 0
    if ($headers.ContainsKey('content-length')) {
        try { $bodyLen = [int]$headers['content-length'] } catch { $bodyLen = 0 }
    }
    $bodyText = ''
    if ($bodyLen -gt 0) {
        $bodyBytes = New-Object byte[] $bodyLen
        $have = $all.Length - $headerEnd
        $read = [Math]::Min($have, $bodyLen)
        if ($read -gt 0) { [Array]::Copy($all, $headerEnd, $bodyBytes, 0, $read) }
        while ($read -lt $bodyLen) {
            if ((Get-Date) -gt $deadline) { break }
            if (-not $Stream.DataAvailable) { Start-Sleep -Milliseconds 20; continue }
            $n = $Stream.Read($bodyBytes, $read, $bodyLen - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        $bodyText = [System.Text.Encoding]::UTF8.GetString($bodyBytes)
    }

    $rawUrl = $reqLine[1]
    $path = $rawUrl
    $query = @{}
    $qi = $rawUrl.IndexOf('?')
    if ($qi -ge 0) {
        $path = $rawUrl.Substring(0, $qi)
        foreach ($pair in ($rawUrl.Substring($qi + 1) -split '&')) {
            if (-not $pair) { continue }
            $kv = $pair -split '=', 2
            $k = [System.Uri]::UnescapeDataString($kv[0])
            $v = ''
            if ($kv.Length -gt 1) { $v = [System.Uri]::UnescapeDataString($kv[1]) }
            $query[$k] = $v
        }
    }

    return [pscustomobject]@{
        Method = $reqLine[0].ToUpper(); Path = $path; Query = $query; Headers = $headers; Body = $bodyText
    }
}

function Write-HttpText {
    param($Stream, [int]$Status, [string]$ContentType, [string]$Text, [string[]]$ExtraHeaders = @())
    $body = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $reasonMap = @{
        200 = 'OK'; 202 = 'Accepted'; 400 = 'Bad Request'; 401 = 'Unauthorized'
        403 = 'Forbidden'; 404 = 'Not Found'; 405 = 'Method Not Allowed'
        429 = 'Too Many Requests'; 500 = 'Internal Server Error'
    }
    $reason = 'OK'
    if ($reasonMap.ContainsKey($Status)) { $reason = $reasonMap[$Status] }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("HTTP/1.1 $Status $reason`r`n")
    [void]$sb.Append("Content-Type: $ContentType`r`n")
    [void]$sb.Append("Content-Length: $($body.Length)`r`n")
    [void]$sb.Append("Cache-Control: no-store`r`n")
    [void]$sb.Append("Connection: close`r`n")
    foreach ($h in $ExtraHeaders) { [void]$sb.Append("$h`r`n") }
    [void]$sb.Append("`r`n")
    $hb = [System.Text.Encoding]::ASCII.GetBytes($sb.ToString())
    $Stream.Write($hb, 0, $hb.Length)
    if ($body.Length -gt 0) { $Stream.Write($body, 0, $body.Length) }
    $Stream.Flush()
}

function Send-HttpJson {
    param($Stream, [int]$Status, $Object, [string[]]$ExtraHeaders = @())
    # -InputObject 而不是管道：管道会把字典拆成 DictionaryEntry 序列化。
    $json = ConvertTo-Json -InputObject $Object -Depth 8 -Compress
    Write-HttpText -Stream $Stream -Status $Status -ContentType 'application/json; charset=utf-8' -Text $json -ExtraHeaders $ExtraHeaders
}

function Start-WebPanel {
    param([string]$Bind, [int]$Port)

    $indexPath = Join-Path (Join-Path $PanelDir 'web') 'index.html'
    if (-not (Test-Path -LiteralPath $indexPath)) {
        Write-Line "  [Web] 缺少页面文件：$indexPath" 'Red'
        return 1
    }

    $ipAddr = $null
    if ($Bind -eq '0.0.0.0' -or $Bind -eq 'any') { $ipAddr = [System.Net.IPAddress]::Any }
    elseif ($Bind -eq '::') { $ipAddr = [System.Net.IPAddress]::IPv6Any }
    else {
        try { $ipAddr = [System.Net.IPAddress]::Parse($Bind) }
        catch {
            Write-Line "  [Web] 监听地址无效：$Bind（可用 0.0.0.0 / 127.0.0.1 / 具体网卡 IP）" 'Red'
            return 1
        }
    }

    $listener = $null
    try {
        $listener = New-Object System.Net.Sockets.TcpListener($ipAddr, $Port)
        $listener.Server.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket,
            [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
        $listener.Start(50)
    }
    catch {
        Write-Line "  [Web] 端口 $Port 监听失败：$($_.Exception.Message)" 'Red'
        Write-Line '  [Web] 端口被占用时换一个：-Action web -WebPort 3101' 'Yellow'
        return 1
    }

    $startedAt = Get-Date
    $addrs = @(Get-PanelAddressList)

    Write-Line '' 'Gray'
    Write-Line '  ================= Web 控制面板已启动 =================' 'Cyan'
    Write-Line ("  监听      : {0}:{1}" -f $Bind, $Port) 'Green'
    Write-Line ("  本机访问  : http://127.0.0.1:{0}" -f $Port) 'Green'
    foreach ($a in $addrs) { Write-Line ("  局域网    : http://{0}:{1}" -f $a, $Port) 'Green' }
    Write-Line ("  访问口令  : 无（页面不再校验令牌）") 'Yellow'
    Write-Line '  安全边界  : 只接受同网段私网来源；请勿把本端口映射到公网。' 'DarkGray'
    Write-Line '  说明      : 启停动作由子进程执行，结果看本页日志；页面可点「关闭面板服务」停止本服务。' 'DarkGray'
    Write-Line '  停止      : 页面按钮 / 本窗口 Ctrl+C / 关掉 启动控制面板-Web.bat 窗口' 'DarkGray'
    Write-Line '  =====================================================' 'Cyan'
    Write-Line ''

    $allowedActions = @('start', 'stop', 'restart', 'startnapcat', 'stopnapcat', 'status')
    $actionLabels = @{
        start = '启动主程序'; stop = '停止主程序'; restart = '重启主程序'
        startnapcat = '启动 NapCat'; stopnapcat = '停止 NapCat'; status = '查看状态'
    }
    $selfPath = Join-Path $PanelDir 'panel.ps1'
    $stopRequested = $false

    try {
        while (-not $stopRequested) {
            if (-not $listener.Pending()) { Start-Sleep -Milliseconds 80; continue }
            $client = $null
            try {
                $client = $listener.AcceptTcpClient()
                $client.ReceiveTimeout = 8000
                $client.SendTimeout = 15000
                $stream = $client.GetStream()
                $req = Read-HttpRequest -Stream $stream
                if (-not $req) { continue }

                $remoteIp = ''
                try {
                    $ep = $client.Client.RemoteEndPoint
                    $remoteIp = $ep.Address.ToString()
                }
                catch { }
                if (-not (Test-PrivateIp -Ip $remoteIp)) {
                    Write-GuiLog ("[Web] 拒绝非私网来源 {0} -> {1}" -f $remoteIp, $req.Path)
                    Write-HttpText -Stream $stream -Status 403 -ContentType 'text/plain; charset=utf-8' `
                        -Text "403 仅允许局域网访问（来源 $remoteIp）"
                    continue
                }

                # 无口令模式：只靠上面的私网来源校验做边界。
                switch ($req.Path) {
                    '/' {
                        if ($req.Method -ne 'GET') { Write-HttpText -Stream $stream -Status 405 -ContentType 'text/plain' -Text 'method not allowed'; break }
                        # 每次请求现读：改页面不用重启面板
                        $page = ''
                        try { $page = [System.IO.File]::ReadAllText($indexPath, [System.Text.Encoding]::UTF8) } catch { }
                        if ($page) {
                            Write-HttpText -Stream $stream -Status 200 -ContentType 'text/html; charset=utf-8' -Text $page
                        }
                        else {
                            Write-HttpText -Stream $stream -Status 500 -ContentType 'text/plain; charset=utf-8' -Text '页面文件读取失败'
                        }
                    }
                    '/index.html' {
                        $page = ''
                        try { $page = [System.IO.File]::ReadAllText($indexPath, [System.Text.Encoding]::UTF8) } catch { }
                        Write-HttpText -Stream $stream -Status 200 -ContentType 'text/html; charset=utf-8' -Text $page
                    }
                    '/api/status' {
                        try {
                            $st = Get-WebStatusObject -Bind $Bind -Port $Port -StartedAt $startedAt
                            Send-HttpJson -Stream $stream -Status 200 -Object $st
                        }
                        catch {
                            $msg = $_.Exception.Message
                            Write-GuiLog ("[Web] 状态构建失败：{0} @ {1}:{2}" -f $msg, $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line.Trim())
                            Send-HttpJson -Stream $stream -Status 500 -Object ([ordered]@{ ok = $false; error = "状态构建失败：$msg" })
                        }
                    }
                    '/api/logs' {
                        $n = 120
                        if ($req.Query.ContainsKey('lines')) { try { $n = [int]$req.Query['lines'] } catch { } }
                        if ($n -lt 10) { $n = 10 }; if ($n -gt 1000) { $n = 1000 }
                        Send-HttpJson -Stream $stream -Status 200 -Object ([ordered]@{ ok = $true; lines = @(Get-WebLogTail -Lines $n) })
                    }
                    '/api/action' {
                        if ($req.Method -ne 'POST') { Write-HttpText -Stream $stream -Status 405 -ContentType 'text/plain' -Text 'method not allowed'; break }
                        $act = ''
                        try {
                            $obj = ConvertFrom-Json -InputObject $req.Body
                            if ($obj -and $obj.action) { $act = [string]$obj.action }
                        }
                        catch { }
                        # 关闭本控制面板服务：不走子进程，直接把监听循环停掉。
                        if ($act -eq 'panel-stop') {
                            Write-GuiLog ("[Web] 关闭控制面板（来自 {0}）" -f $remoteIp)
                            Send-HttpJson -Stream $stream -Status 202 -Object ([ordered]@{
                                    ok = $true; action = 'panel-stop'; label = '关闭控制面板'; started = $true
                                })
                            Start-Sleep -Milliseconds 300
                            $stopRequested = $true
                            break
                        }
                        if ($allowedActions -notcontains $act) {
                            Send-HttpJson -Stream $stream -Status 400 -Object ([ordered]@{ ok = $false; error = "不支持的动作：$act" })
                            break
                        }
                        $lockFile = Join-Path $RunDir 'web-action.lock'
                        $busy = $false
                        if (Test-Path -LiteralPath $lockFile) {
                            try {
                                $last = [datetime]::Parse((Get-Content -LiteralPath $lockFile -Raw).Trim())
                                if (((Get-Date) - $last).TotalSeconds -lt 8) { $busy = $true }
                            }
                            catch { }
                        }
                        if ($busy) {
                            Send-HttpJson -Stream $stream -Status 429 -Object ([ordered]@{ ok = $false; error = '上一次操作还在执行，请稍候再试' })
                            break
                        }
                        [System.IO.File]::WriteAllText($lockFile, (Get-Date).ToString('o'),
                            (New-Object System.Text.UTF8Encoding($false)))
                        $label = $actionLabels[$act]
                        Write-GuiLog ("[Web] {0} 请求 {1}（来自 {2}）" -f $label, $act, $remoteIp)
                        try {
                            $childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $selfPath, '-Action', $act, '-NoPause')
                            if ($act -eq 'startnapcat' -and $obj -and $obj.closeDesktopQq -eq $true) { $childArgs += '-CloseDesktopQq' }
                            Start-Process -FilePath 'powershell.exe' `
                                -ArgumentList $childArgs `
                                -WorkingDirectory $Root -WindowStyle Hidden | Out-Null
                            Send-HttpJson -Stream $stream -Status 202 -Object ([ordered]@{
                                    ok = $true; action = $act; label = $label; started = $true
                                })
                        }
                        catch {
                            Send-HttpJson -Stream $stream -Status 500 -Object ([ordered]@{ ok = $false; error = $_.Exception.Message })
                        }
                    }
                    default {
                        Write-HttpText -Stream $stream -Status 404 -ContentType 'text/plain; charset=utf-8' -Text '404'
                    }
                }
            }
            catch {
                Write-GuiLog ("[Web] 请求处理异常：{0}" -f $_.Exception.Message)
            }
            finally {
                if ($client) { try { $client.Close() } catch { } }
            }
        }
    }
    finally {
        try { $listener.Stop() } catch { }
        Write-Line '  [Web] 控制面板已停止。' 'Yellow'
    }
    return 0
}

# ================= 入口（命令行部分） =================
Repair-ProcessEnvironment

# 语法自检：GUI 一般用 -WindowStyle Hidden 启动，脚本语法坏了用户只会看到
# "点了没反应"。这里先解析一遍（约 100 ms），有问题就带行号退出（退出码 1），
# 让 启动控制面板.bat 的预检能拦住并显示出来。
$parseErrors = $null
$parseTokens = $null
try {
    $null = [System.Management.Automation.Language.Parser]::ParseFile($MyInvocation.MyCommand.Path, [ref]$parseTokens, [ref]$parseErrors)
}
catch { }
if ($parseErrors -and $parseErrors.Count -gt 0) {
    Write-Host ("  [错误] panel.ps1 有 {0} 处语法错误：" -f $parseErrors.Count) -ForegroundColor Red
    foreach ($e in ($parseErrors | Select-Object -First 5)) {
        Write-Host ("    行 {0}: {1}" -f $e.Extent.StartLineNumber, $e.Message) -ForegroundColor Red
    }
    if (-not $NoPause) { Write-Host ''; Read-Host '  按回车关闭' | Out-Null }
    exit 1
}

switch ($Action) {
    'start' {
        Invoke-StartAll
        if (-not $NoPause) { Write-Host ''; Read-Host '  按回车关闭' | Out-Null }
    }
    'stop' {
        Invoke-StopAll
        if (-not $NoPause) { Write-Host ''; Read-Host '  按回车关闭' | Out-Null }
        # 退出码给 停止.bat 用：3007 还在听就是没停干净
        if (Test-PortOpen -Port 3007) { exit 1 }
        exit 0
    }
    'stopnapcat' {
        Write-Line '================ 停止 NapCat ================' 'Cyan'
        Stop-NapCatService
        if (-not $NoPause) { Write-Host ''; Read-Host '  按回车关闭' | Out-Null }
        if (Test-PortOpen -Port 6099) { exit 1 }
        exit 0
    }
    'startnapcat' {
        Write-Line '================ 启动 NapCat ================' 'Cyan'
        [void](Start-NapCatService -CloseDesktopQq:$CloseDesktopQq)
        if (-not $NoPause) { Write-Host ''; Read-Host '  按回车关闭' | Out-Null }
    }
    'restart' {
        Invoke-StopAll
        Start-Sleep -Milliseconds 800
        Invoke-StartAll
        if (-not $NoPause) { Write-Host ''; Read-Host '  按回车关闭' | Out-Null }
    }
    'web' {
        # 监听端口对外提供控制面板（默认 0.0.0.0:3100）。
        # 这是常驻进程，不按任意键退出；Ctrl+C 结束。
        exit (Start-WebPanel -Bind $WebBind -Port $WebPort)
    }
    'status' {
        Show-StatusTable
        if (-not $NoPause) { Write-Host ''; Read-Host '  按回车关闭' | Out-Null }
    }
    'update' {
        Update-UpstreamRepos
        if (-not $NoPause) { Write-Host ''; Read-Host '  按回车关闭' | Out-Null }
    }
    'upstreamdiff' {
        $rc = Show-UpstreamDiff -OpenReport
        if (-not $NoPause) { Write-Host ''; Read-Host '  按回车关闭' | Out-Null }
        exit $rc
    }
    'syncupstream' {
        $rc = Invoke-UpstreamSync -ConfirmSync:$ConfirmSync
        if (-not $NoPause) { Write-Host ''; Read-Host '  按回车关闭' | Out-Null }
        exit $rc
    }
    'build' {
        Invoke-WorkspaceInstall | Out-Null
        Invoke-WorkspaceBuild | Out-Null
        if (-not $NoPause) { Write-Host ''; Read-Host '  按回车关闭' | Out-Null }
    }
    'shortcut' { New-DesktopShortcut }
    'checkversion' { Update-VersionCheck }
    'prepscan' { [void](Reset-QqScanLogin) }
    'selftest' {
        Write-Line '================ 面板自检 ================' 'Cyan'
        $errors = $null; $tokens = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($MyInvocation.MyCommand.Path, [ref]$tokens, [ref]$errors)
        if ($errors -and $errors.Count -gt 0) {
            Write-Line "  语法解析：$($errors.Count) 个错误" 'Red'
        }
        else { Write-Line '  语法解析：通过' 'Green' }
        foreach ($s in $Services) {
            $portSet = Get-ListeningPortSet
            $st = Get-ServiceStatus -Service $s -PortSet $portSet -ResolvePid
            Write-Line ("  {0,-20} {1}" -f $s.Name, $(if ($st.Running) { '运行中' } else { '已停止' })) $(if ($st.Running) { 'Green' } else { 'Gray' })
        }
        Write-Line "  日志：$GuiLogPath" 'DarkGray'
        # 窗口构建放在文件末尾执行：Show-Gui 定义在本 switch 之后，
        # 这里直接调用会报"无法将 Show-Gui 项识别为 cmdlet/函数"。
        $script:RunGuiSelfTest = $true
    }
}

# ================= 图形界面 =================
function Show-Gui {
    Write-GuiLog '--- 面板启动 ---'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Add-Type -AssemblyName System.Windows.Forms
    Write-GuiLog ("加载 System.Windows.Forms 完成 ({0:N0} ms)" -f $sw.Elapsed.TotalMilliseconds)
    Add-Type -AssemblyName System.Drawing
    Write-GuiLog ("加载 System.Drawing 完成 ({0:N0} ms)" -f $sw.Elapsed.TotalMilliseconds)
    [System.Windows.Forms.Application]::EnableVisualStyles()
    Write-GuiLog ("EnableVisualStyles 完成 ({0:N0} ms)" -f $sw.Elapsed.TotalMilliseconds)

    # ================= 设计令牌 =================
    $C = @{
        Bg         = [System.Drawing.Color]::FromArgb(244, 246, 248)
        Surface    = [System.Drawing.Color]::White
        Line       = [System.Drawing.Color]::FromArgb(226, 232, 240)
        Text       = [System.Drawing.Color]::FromArgb(30, 41, 59)
        TextSoft   = [System.Drawing.Color]::FromArgb(100, 116, 139)
        TextFaint  = [System.Drawing.Color]::FromArgb(148, 163, 184)
        Brand      = [System.Drawing.Color]::FromArgb(22, 163, 74)
        BrandDark  = [System.Drawing.Color]::FromArgb(21, 128, 61)
        BrandSoft  = [System.Drawing.Color]::FromArgb(220, 252, 231)
        Danger     = [System.Drawing.Color]::FromArgb(220, 38, 38)
        DangerSoft = [System.Drawing.Color]::FromArgb(254, 242, 242)
        DangerLine = [System.Drawing.Color]::FromArgb(252, 165, 165)
        Warn       = [System.Drawing.Color]::FromArgb(180, 83, 9)
        WarnSoft   = [System.Drawing.Color]::FromArgb(255, 251, 235)
        WarnLine   = [System.Drawing.Color]::FromArgb(253, 230, 138)
        StopDot    = [System.Drawing.Color]::FromArgb(148, 163, 184)
        StopSoft   = [System.Drawing.Color]::FromArgb(241, 245, 249)
        GhostBg    = [System.Drawing.Color]::FromArgb(255, 255, 255)
        GhostHover = [System.Drawing.Color]::FromArgb(241, 245, 249)
        LogBg      = [System.Drawing.Color]::FromArgb(250, 251, 253)
        BarBg      = [System.Drawing.Color]::FromArgb(236, 240, 245)
    }

    $ff = 'Microsoft YaHei UI'
    $fBase = New-Object System.Drawing.Font($ff, 9)
    $fTitle = New-Object System.Drawing.Font($ff, 15, [System.Drawing.FontStyle]::Bold)
    $fSub = New-Object System.Drawing.Font($ff, 8.5)
    $fSection = New-Object System.Drawing.Font($ff, 9, [System.Drawing.FontStyle]::Bold)
    $fCard = New-Object System.Drawing.Font($ff, 10.5, [System.Drawing.FontStyle]::Bold)
    $fSmall = New-Object System.Drawing.Font($ff, 8.5)
    $fTiny = New-Object System.Drawing.Font($ff, 8)
    $fTinyB = New-Object System.Drawing.Font($ff, 8.5, [System.Drawing.FontStyle]::Bold)
    $fBtn = New-Object System.Drawing.Font($ff, 9)
    $fBtnStrong = New-Object System.Drawing.Font($ff, 9.5, [System.Drawing.FontStyle]::Bold)
    $fMono = New-Object System.Drawing.Font('Consolas', 9)

    # ================= 版本检测设置 =================
    $cfgAll = Get-PanelConfigHash
    $vc = @{ intervalMinutes = 30; notifyPopup = $true; notifiedSha = @{} }
    if ($cfgAll.ContainsKey('versionCheck') -and $cfgAll['versionCheck']) {
        $v = $cfgAll['versionCheck']
        foreach ($p in $v.PSObject.Properties) {
            if ($p.Name -eq 'notifiedSha') {
                $ns = @{}
                if ($p.Value) { foreach ($q in $p.Value.PSObject.Properties) { $ns[$q.Name] = [string]$q.Value } }
                $vc['notifiedSha'] = $ns
            }
            else { $vc[$p.Name] = $p.Value }
        }
    }
    $script:verCfg = $vc
    $script:versionCheckRunning = $false
    $script:lastStateMtime = $null
    $script:checkStartAt = $null
    $script:nextCheckAt = (Get-Date)

    # ================= 窗体骨架 =================
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'QQ农场助手（活动自动化版）· 控制面板'
    $form.ClientSize = New-Object System.Drawing.Size(904, 856)
    $form.MinimumSize = New-Object System.Drawing.Size(816, 816)
    $form.StartPosition = 'CenterScreen'
    $form.Font = $fBase
    $form.BackColor = $C.Bg
    $form.ForeColor = $C.Text
    $form.FormBorderStyle = 'Sizable'
    $form.MaximizeBox = $true
    $icoPath = Join-Path $PanelDir 'panel.ico'
    if (Test-Path -LiteralPath $icoPath) {
        try { $form.Icon = New-Object System.Drawing.Icon($icoPath) } catch { }
    }

    # ---- 通用小工具 ----
    function New-Label {
        param([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H,
            $Font, $Color, [string]$Anchor = 'Top,Left', [switch]$Ellipsis)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $Text
        $l.Location = New-Object System.Drawing.Point($X, $Y)
        $l.Size = New-Object System.Drawing.Size($W, $H)
        if ($Font) { $l.Font = $Font }
        if ($Color) { $l.ForeColor = $Color }
        $l.Anchor = $Anchor
        $l.BackColor = [System.Drawing.Color]::Transparent
        $l.TextAlign = 'MiddleLeft'
        $l.AutoSize = $false
        $l.AutoEllipsis = $Ellipsis.IsPresent
        return $l
    }

    function New-FlatButton {
        param([string]$Text, [string]$Kind = 'secondary')
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $Text
        $b.FlatStyle = 'Flat'
        $b.UseVisualStyleBackColor = $false
        $b.FlatAppearance.BorderSize = 1
        $b.Font = $fBtn
        $b.Cursor = [System.Windows.Forms.Cursors]::Hand
        switch ($Kind) {
            'primary' {
                $b.BackColor = $C.Brand
                $b.ForeColor = [System.Drawing.Color]::White
                $b.FlatAppearance.BorderColor = $C.Brand
                $b.FlatAppearance.MouseOverBackColor = $C.BrandDark
                $b.FlatAppearance.MouseDownBackColor = $C.BrandDark
                $b.Font = $fBtnStrong
            }
            'danger' {
                $b.BackColor = $C.Surface
                $b.ForeColor = $C.Danger
                $b.FlatAppearance.BorderColor = $C.DangerLine
                $b.FlatAppearance.MouseOverBackColor = $C.DangerSoft
                $b.FlatAppearance.MouseDownBackColor = $C.DangerSoft
            }
            'warn' {
                $b.BackColor = $C.WarnSoft
                $b.ForeColor = $C.Warn
                $b.FlatAppearance.BorderColor = $C.WarnLine
                $b.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(254, 243, 199)
                $b.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(254, 243, 199)
            }
            'ghost' {
                $b.BackColor = $C.GhostBg
                $b.ForeColor = $C.TextSoft
                $b.FlatAppearance.BorderColor = $C.Line
                $b.FlatAppearance.MouseOverBackColor = $C.GhostHover
                $b.FlatAppearance.MouseDownBackColor = $C.GhostHover
                $b.Font = $fTiny
            }
            default {
                $b.BackColor = $C.Surface
                $b.ForeColor = $C.Text
                $b.FlatAppearance.BorderColor = $C.Line
                $b.FlatAppearance.MouseOverBackColor = $C.GhostHover
                $b.FlatAppearance.MouseDownBackColor = $C.GhostHover
            }
        }
        return $b
    }

    # ================= 顶部标题栏 =================
    $accent = New-Object System.Windows.Forms.Panel
    $accent.Location = New-Object System.Drawing.Point(0, 0)
    $accent.Size = New-Object System.Drawing.Size(904, 4)
    $accent.BackColor = $C.Brand
    $accent.Anchor = 'Top,Left,Right'
    $form.Controls.Add($accent)

    $header = New-Object System.Windows.Forms.Panel
    $header.Location = New-Object System.Drawing.Point(0, 4)
    $header.Size = New-Object System.Drawing.Size(904, 70)
    $header.BackColor = $C.Surface
    $header.Anchor = 'Top,Left,Right'
    $form.Controls.Add($header)

    $header.Controls.Add((New-Label -Text 'QQ农场助手 · 活动自动化版' -X 20 -Y 14 -W 460 -H 28 -Font $fTitle -Color $C.Text))

    $versionText = ''
    try {
        $pkg = Join-Path $Root 'core\package.json'
        if (Test-Path -LiteralPath $pkg) {
            $versionText = '   ·   主程序 v' + (Get-Content -LiteralPath $pkg -Raw | ConvertFrom-Json).version
        }
    }
    catch { }
    $subText = "${Root}   ·   仅本机 127.0.0.1${versionText}"
    $header.Controls.Add((New-Label -Text $subText -X 21 -Y 44 -W 640 -H 16 -Font $fSub -Color $C.TextSoft -Anchor 'Top,Left,Right' -Ellipsis))

    $btnExit = New-FlatButton -Text '退出' -Kind 'ghost'
    $btnExit.Location = New-Object System.Drawing.Point(800, 19)
    $btnExit.Size = New-Object System.Drawing.Size(84, 30)
    $btnExit.Anchor = 'Top,Right'
    $header.Controls.Add($btnExit)

    # ================= 服务状态区 =================
    $statusSection = New-Object System.Windows.Forms.Panel
    $statusSection.Location = New-Object System.Drawing.Point(0, 82)
    $statusSection.Size = New-Object System.Drawing.Size(904, 142)
    $statusSection.BackColor = $C.Bg
    $statusSection.Anchor = 'Top,Left,Right'
    $form.Controls.Add($statusSection)

    $statusSection.Controls.Add((New-Label -Text '服务状态' -X 20 -Y 6 -W 200 -H 18 -Font $fSection -Color $C.Text))
    $statusHint = New-Label -Text '每 4 秒自动刷新' -X 700 -Y 7 -W 190 -H 16 -Font $fTiny -Color $C.TextFaint -Anchor 'Top,Right'
    $statusHint.TextAlign = 'MiddleRight'
    $statusSection.Controls.Add($statusHint)

    $cardsRow = New-Object System.Windows.Forms.TableLayoutPanel
    $cardsRow.Location = New-Object System.Drawing.Point(16, 30)
    $cardsRow.Size = New-Object System.Drawing.Size(872, 104)
    $cardsRow.ColumnCount = 2
    $cardsRow.RowCount = 1
    $cardsRow.BackColor = $C.Line
    $cardsRow.Anchor = 'Top,Left,Right'
    for ($i = 0; $i -lt 2; $i++) {
        [void]$cardsRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
    }
    $statusSection.Controls.Add($cardsRow)

    $statusLabels = @{}
    $col = 0
    foreach ($s in $Services) {
        $card = New-Object System.Windows.Forms.Panel
        $card.BackColor = $C.Surface
        $card.Dock = 'Fill'
        $card.Margin = New-Object System.Windows.Forms.Padding(1)
        $cardsRow.Controls.Add($card, $col, 0)

        $strip = New-Object System.Windows.Forms.Panel
        $strip.Location = New-Object System.Drawing.Point(0, 0)
        $strip.Size = New-Object System.Drawing.Size(400, 3)
        $strip.BackColor = $C.StopDot
        $strip.Anchor = 'Top,Left,Right'
        $card.Controls.Add($strip)

        $card.Controls.Add((New-Label -Text $s.Name -X 14 -Y 16 -W 300 -H 22 -Font $fCard -Color $C.Text -Anchor 'Top,Left,Right' -Ellipsis))

        $badge = New-Object System.Windows.Forms.Label
        $badge.Text = '○ 已停止'
        $badge.Font = $fTiny
        $badge.TextAlign = 'MiddleCenter'
        $badge.BackColor = $C.StopSoft
        $badge.ForeColor = $C.TextSoft
        $badge.Location = New-Object System.Drawing.Point(14, 46)
        $badge.Size = New-Object System.Drawing.Size(72, 20)
        $badge.Anchor = 'Top,Left'
        $card.Controls.Add($badge)

        $portLabel = New-Label -Text '—' -X 14 -Y 76 -W 380 -H 18 -Font $fSmall -Color $C.TextFaint -Anchor 'Top,Left,Right' -Ellipsis
        $card.Controls.Add($portLabel)

        $statusLabels[$s.Key] = [pscustomobject]@{ Strip = $strip; Badge = $badge; Ports = $portLabel }
        $col += 1
    }

    # ================= 操作区 =================
    $actionSection = New-Object System.Windows.Forms.Panel
    $actionSection.Location = New-Object System.Drawing.Point(0, 232)
    $actionSection.Size = New-Object System.Drawing.Size(904, 164)
    $actionSection.BackColor = $C.Bg
    $actionSection.Anchor = 'Top,Left,Right'
    $form.Controls.Add($actionSection)

    $actionSection.Controls.Add((New-Label -Text '操作' -X 20 -Y 4 -W 200 -H 18 -Font $fSection -Color $C.Text))

    $buttons = @{}

    function New-BtnRow {
        param([array]$Defs, [int]$Y, [int]$Height)
        $t = New-Object System.Windows.Forms.TableLayoutPanel
        $t.Location = New-Object System.Drawing.Point(16, $Y)
        $t.Size = New-Object System.Drawing.Size(872, $Height)
        $t.ColumnCount = $Defs.Count
        $t.RowCount = 1
        $t.BackColor = $C.Bg
        $t.Anchor = 'Top,Left,Right'
        $pct = [math]::Round(100 / $Defs.Count, 4)
        for ($i = 0; $i -lt $Defs.Count; $i++) {
            [void]$t.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, $pct)))
        }
        for ($i = 0; $i -lt $Defs.Count; $i++) {
            $def = $Defs[$i]
            $b = New-FlatButton -Text $def.Text -Kind $def.Kind
            $b.Dock = 'Fill'
            if ($i -eq ($Defs.Count - 1)) { $b.Margin = New-Object System.Windows.Forms.Padding(0) }
            else { $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0) }
            $t.Controls.Add($b, $i, 0)
            $buttons[$def.Name] = $b
        }
        return $t
    }

    $row1 = New-BtnRow -Y 28 -Height 40 -Defs @(
        @{ Name = 'startAll'; Text = '启动主程序'; Kind = 'primary' },
        @{ Name = 'stopAll'; Text = '停止主程序'; Kind = 'danger' },
        @{ Name = 'restart'; Text = '重启主程序'; Kind = 'secondary' }
    )
    $actionSection.Controls.Add($row1)

    $row2 = New-BtnRow -Y 78 -Height 36 -Defs @(
        @{ Name = 'openFarm'; Text = '打开农场面板 →'; Kind = 'secondary' },
        @{ Name = 'openNapcat'; Text = '打开 NapCat →'; Kind = 'secondary' },
        @{ Name = 'startNapcat'; Text = '启动 NapCat'; Kind = 'warn' },
        @{ Name = 'stopNapcat'; Text = '停止 NapCat'; Kind = 'secondary' },
        @{ Name = 'prepScan'; Text = '准备扫码登录'; Kind = 'warn' }
    )
    $actionSection.Controls.Add($row2)

    $row3 = New-BtnRow -Y 124 -Height 28 -Defs @(
        @{ Name = 'update'; Text = '查看差异'; Kind = 'ghost' },
        @{ Name = 'sync'; Text = '同步上游'; Kind = 'ghost' },
        @{ Name = 'shortcut'; Text = '重建快捷方式'; Kind = 'ghost' },
        @{ Name = 'status'; Text = '刷新状态'; Kind = 'ghost' },
        @{ Name = 'logs'; Text = '主程序日志'; Kind = 'ghost' },
        @{ Name = 'napcatLogs'; Text = 'NapCat 日志'; Kind = 'ghost' },
        @{ Name = 'dir'; Text = '部署目录'; Kind = 'ghost' }
    )
    $actionSection.Controls.Add($row3)

    # ================= NapCat 令牌 =================
    $tokenSection = New-Object System.Windows.Forms.Panel
    $tokenSection.Location = New-Object System.Drawing.Point(0, 404)
    $tokenSection.Size = New-Object System.Drawing.Size(904, 80)
    $tokenSection.BackColor = $C.Bg
    $tokenSection.Anchor = 'Top,Left,Right'
    $form.Controls.Add($tokenSection)

    # 标题独占一行：原来标签只有 76px，中文被挤成「NapCat 令 / 牌」两行并与输入框重叠
    $tokenSection.Controls.Add((New-Label -Text 'NapCat 令牌' -X 20 -Y 8 -W 130 -H 20 -Font $fSection -Color $C.Text))
    $tokenSub = New-Label -Text 'WebUI 与插件共用同一令牌 · 复制后 90 秒自动清空剪贴板' -X 360 -Y 10 -W 520 -H 16 -Font $fTiny -Color $C.TextFaint -Anchor 'Top,Right' -Ellipsis
    $tokenSub.TextAlign = 'MiddleRight'
    $tokenSection.Controls.Add($tokenSub)

    # 第二行：输入框 + 显示/隐藏 + 复制 + 提示，互不重叠
    $txtToken = New-Object System.Windows.Forms.TextBox
    $txtToken.ReadOnly = $true
    $txtToken.Font = $fMono
    $txtToken.BorderStyle = 'FixedSingle'
    $txtToken.BackColor = $C.Surface
    $txtToken.ForeColor = $C.Text
    $txtToken.Location = New-Object System.Drawing.Point(20, 36)
    $txtToken.Size = New-Object System.Drawing.Size(616, 26)
    $txtToken.Anchor = 'Top,Left,Right'
    $txtToken.TabStop = $false
    $tokenSection.Controls.Add($txtToken)

    $btnToggleToken = New-FlatButton -Text '隐藏' -Kind 'ghost'
    $btnToggleToken.Location = New-Object System.Drawing.Point(646, 35)
    $btnToggleToken.Size = New-Object System.Drawing.Size(58, 28)
    $btnToggleToken.Anchor = 'Top,Right'
    $tokenSection.Controls.Add($btnToggleToken)

    $btnCopyToken = New-FlatButton -Text '复制' -Kind 'secondary'
    $btnCopyToken.Location = New-Object System.Drawing.Point(712, 35)
    $btnCopyToken.Size = New-Object System.Drawing.Size(72, 28)
    $btnCopyToken.Anchor = 'Top,Right'
    $tokenSection.Controls.Add($btnCopyToken)

    $tokenHint = New-Label -Text '' -X 790 -Y 40 -W 94 -H 18 -Font $fTiny -Color $C.BrandDark -Anchor 'Top,Right'
    $tokenHint.TextAlign = 'MiddleRight'
    $tokenSection.Controls.Add($tokenHint)

    # ================= 版本检测区 =================
    $verSection = New-Object System.Windows.Forms.Panel
    $verSection.Location = New-Object System.Drawing.Point(0, 492)
    $verSection.Size = New-Object System.Drawing.Size(904, 134)
    $verSection.BackColor = $C.Bg
    $verSection.Anchor = 'Top,Left,Right'
    $form.Controls.Add($verSection)

    $verSection.Controls.Add((New-Label -Text '版本检测' -X 20 -Y 2 -W 200 -H 18 -Font $fSection -Color $C.Text))
    $verSection.Controls.Add((New-Label -Text '检测间隔' -X 20 -Y 28 -W 56 -H 22 -Font $fSmall -Color $C.TextSoft))

    $comboInterval = New-Object System.Windows.Forms.ComboBox
    $comboInterval.DropDownStyle = 'DropDownList'
    $comboInterval.Font = $fSmall
    $comboInterval.Location = New-Object System.Drawing.Point(78, 26)
    $comboInterval.Size = New-Object System.Drawing.Size(100, 24)
    $comboInterval.Anchor = 'Top,Left'
    foreach ($k in $VersionIntervals.Keys) { [void]$comboInterval.Items.Add($k) }
    $verSection.Controls.Add($comboInterval)

    $btnCheckNow = New-FlatButton -Text '立即检测' -Kind 'secondary'
    $btnCheckNow.Location = New-Object System.Drawing.Point(188, 24)
    $btnCheckNow.Size = New-Object System.Drawing.Size(88, 28)
    $btnCheckNow.Anchor = 'Top,Left'
    $verSection.Controls.Add($btnCheckNow)

    $chkNotify = New-Object System.Windows.Forms.CheckBox
    $chkNotify.Text = '发现新版本时弹窗提醒'
    $chkNotify.Font = $fSmall
    $chkNotify.ForeColor = $C.TextSoft
    $chkNotify.Location = New-Object System.Drawing.Point(288, 29)
    $chkNotify.Size = New-Object System.Drawing.Size(164, 20)
    $chkNotify.Anchor = 'Top,Left'
    $chkNotify.Checked = [bool]$script:verCfg.notifyPopup
    $verSection.Controls.Add($chkNotify)

    $verState = New-Label -Text '尚未检测' -X 540 -Y 28 -W 348 -H 20 -Font $fSmall -Color $C.TextFaint -Anchor 'Top,Right' -Ellipsis
    $verState.TextAlign = 'MiddleRight'
    $verSection.Controls.Add($verState)

    $verWrap = New-Object System.Windows.Forms.Panel
    $verWrap.Location = New-Object System.Drawing.Point(16, 58)
    $verWrap.Size = New-Object System.Drawing.Size(872, 72)
    $verWrap.BackColor = $C.Line
    $verWrap.Padding = New-Object System.Windows.Forms.Padding(1)
    $verWrap.Anchor = 'Top,Left,Right'
    $verSection.Controls.Add($verWrap)

    $verTable = New-Object System.Windows.Forms.TableLayoutPanel
    $verTable.Dock = 'Fill'
    $verTable.ColumnCount = 4
    $verTable.RowCount = 1
    $verTable.BackColor = $C.Surface
    # 列宽：Absolute 150 + Percent 合计 83%（870 可用宽）→ 150 + 722 = 872，不溢出
    # （原 132 + 36/36/28 合计 100%，实际总宽 1004 > 872，导致文字被裁）
    [void]$verTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 150)))
    [void]$verTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 30)))
    [void]$verTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 27)))
    [void]$verTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 26)))
    # 行高 42：版本行 + 状态行放得下，不会再被裁成两行半
    [void]$verTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 42)))
    $verWrap.Controls.Add($verTable)

    $verTip = New-Object System.Windows.Forms.ToolTip
    $verTip.AutoPopDelay = 30000

    $verLabels = @{}
    $vr = 0
    foreach ($r in $VersionRepos) {
        $n = New-Label -Text $r.Name -X 0 -Y 0 -W 120 -H 20 -Font $fTinyB -Color $C.Text -Ellipsis
        $n.Dock = 'Fill'
        $n.Margin = New-Object System.Windows.Forms.Padding(10, 0, 4, 0)
        $verTable.Controls.Add($n, 0, $vr)

        $lLocal = New-Label -Text '本地  —' -X 0 -Y 0 -W 200 -H 20 -Font $fSmall -Color $C.TextSoft -Ellipsis
        $lLocal.Dock = 'Fill'
        $verTable.Controls.Add($lLocal, 1, $vr)

        $lRemote = New-Label -Text '上游  —' -X 0 -Y 0 -W 200 -H 20 -Font $fSmall -Color $C.TextSoft -Ellipsis
        $lRemote.Dock = 'Fill'
        $verTable.Controls.Add($lRemote, 2, $vr)

        $lState = New-Label -Text '— 尚未检测' -X 0 -Y 0 -W 160 -H 20 -Font $fSmall -Color $C.TextFaint -Ellipsis
        $lState.Dock = 'Fill'
        $verTable.Controls.Add($lState, 3, $vr)

        $verLabels[$r.Key] = [pscustomobject]@{ Local = $lLocal; Remote = $lRemote; State = $lState }
        $vr += 1
    }

    # ================= 日志区 =================
    $logSection = New-Object System.Windows.Forms.Panel
    $logSection.Location = New-Object System.Drawing.Point(0, 634)
    $logSection.Size = New-Object System.Drawing.Size(904, 190)
    $logSection.BackColor = $C.Surface
    $logSection.Anchor = 'Top,Bottom,Left,Right'
    $form.Controls.Add($logSection)

    $logSection.Controls.Add((New-Label -Text '运行日志' -X 16 -Y 8 -W 200 -H 18 -Font $fSection -Color $C.Text))

    $chkAutoScroll = New-Object System.Windows.Forms.CheckBox
    $chkAutoScroll.Text = '自动滚动'
    $chkAutoScroll.Checked = $true
    $chkAutoScroll.Font = $fTiny
    $chkAutoScroll.ForeColor = $C.TextSoft
    $chkAutoScroll.Location = New-Object System.Drawing.Point(640, 9)
    $chkAutoScroll.Size = New-Object System.Drawing.Size(84, 18)
    $chkAutoScroll.Anchor = 'Top,Right'
    $logSection.Controls.Add($chkAutoScroll)

    $btnClearLog = New-FlatButton -Text '清空' -Kind 'ghost'
    $btnClearLog.Location = New-Object System.Drawing.Point(732, 5)
    $btnClearLog.Size = New-Object System.Drawing.Size(68, 26)
    $btnClearLog.Anchor = 'Top,Right'
    $logSection.Controls.Add($btnClearLog)

    $btnLogFolder = New-FlatButton -Text '打开日志目录' -Kind 'ghost'
    $btnLogFolder.Location = New-Object System.Drawing.Point(806, 5)
    $btnLogFolder.Size = New-Object System.Drawing.Size(82, 26)
    $btnLogFolder.Anchor = 'Top,Right'
    $logSection.Controls.Add($btnLogFolder)

    $logBox = New-Object System.Windows.Forms.TextBox
    $logBox.Multiline = $true
    $logBox.ReadOnly = $true
    $logBox.ScrollBars = 'Vertical'
    $logBox.WordWrap = $false
    $logBox.BorderStyle = 'FixedSingle'
    $logBox.BackColor = $C.LogBg
    $logBox.ForeColor = $C.Text
    $logBox.Font = $fMono
    $logBox.Location = New-Object System.Drawing.Point(16, 42)
    $logBox.Size = New-Object System.Drawing.Size(872, 138)
    $logBox.Anchor = 'Top,Bottom,Left,Right'
    $logSection.Controls.Add($logBox)

    # ================= 底部状态栏 =================
    $statusBar = New-Object System.Windows.Forms.Panel
    $statusBar.Location = New-Object System.Drawing.Point(0, 824)
    $statusBar.Size = New-Object System.Drawing.Size(904, 32)
    $statusBar.BackColor = $C.BarBg
    $statusBar.Anchor = 'Bottom,Left,Right'
    $form.Controls.Add($statusBar)

    $statusText = New-Label -Text '就绪' -X 16 -Y 7 -W 700 -H 18 -Font $fTiny -Color $C.TextSoft -Anchor 'Top,Left,Right' -Ellipsis
    $statusBar.Controls.Add($statusText)

    # ================= 行为 =================
    function Add-Log {
        param([string]$Text)
        try {
            $stamp = (Get-Date).ToString('HH:mm:ss')
            $logBox.AppendText("[$stamp] $Text`r`n")
            # 只保留最近 1500 行：TextBox 无限增长会让滚动和 AppendText 越来越慢
            if ($logBox.Lines.Count -gt 2000) {
                $keep = $logBox.Lines
                $logBox.Lines = $keep[($keep.Count - 1500)..($keep.Count - 1)]
            }
            if ($chkAutoScroll.Checked) {
                $logBox.SelectionStart = $logBox.TextLength
                $logBox.ScrollToCaret()
            }
        }
        catch { }
        Write-GuiLog $Text
    }

    # Write-Line（启动/停止/同步等动作的详细输出）统一接到日志框。
    # 之前只有按钮 handler 里显式 Add-Log 的那一句会出现在界面上，
    # "已请求后台启动 / 启动失败：xxx" 只写进文件，用户看不到。
    $script:GuiLogSink = { param($t) Add-Log $t }

    function Set-Status {
        param([string]$Text)
        try { $statusText.Text = $Text } catch { }
    }

    # ---------- NapCat 令牌 ----------
    $script:napcatTokenValue = Read-NapCatToken
    $script:tokenMasked = $false

    function Update-TokenDisplay {
        if (-not $script:napcatTokenValue) {
            $txtToken.Text = '（未读到 napcat\config\webui.json 里的 token）'
            $txtToken.ForeColor = $C.Danger
            $btnCopyToken.Enabled = $false
            $btnToggleToken.Enabled = $false
            return
        }
        $btnCopyToken.Enabled = $true
        $btnToggleToken.Enabled = $true
        $txtToken.ForeColor = $C.Text
        if ($script:tokenMasked) {
            $txtToken.Text = ('•' * [Math]::Min(32, $script:napcatTokenValue.Length))
            $btnToggleToken.Text = '显示'
        }
        else {
            $txtToken.Text = $script:napcatTokenValue
            $btnToggleToken.Text = '隐藏'
        }
    }
    Update-TokenDisplay

    $copyHintTimer = New-Object System.Windows.Forms.Timer
    $copyHintTimer.Interval = 2200
    $copyHintTimer.Add_Tick({
            $copyHintTimer.Stop()
            $btnCopyToken.Text = '复制'
            $tokenHint.Text = ''
        })

    # 复制后 90 秒自动清空剪贴板（仅当内容仍然是那个令牌），
    # 避免令牌长期驻留在剪贴板里被其它程序读走。
    $clipClearTimer = New-Object System.Windows.Forms.Timer
    $clipClearTimer.Interval = 90000
    $clipClearTimer.Add_Tick({
            $clipClearTimer.Stop()
            try {
                if ($script:napcatTokenValue -and
                    [System.Windows.Forms.Clipboard]::ContainsText() -and
                    [System.Windows.Forms.Clipboard]::GetText() -ceq $script:napcatTokenValue) {
                    [System.Windows.Forms.Clipboard]::Clear()
                    Add-Log '已自动清空剪贴板（NapCat 令牌）'
                }
            }
            catch { }
        })

    $btnToggleToken.Add_Click({
            $script:tokenMasked = -not $script:tokenMasked
            Update-TokenDisplay
        })

    $btnCopyToken.Add_Click({
            if (-not $script:napcatTokenValue) { return }
            $expect = [string]$script:napcatTokenValue
            $err = ''
            try {
                [System.Windows.Forms.Clipboard]::SetText($expect)
                # 读回比对：确保剪贴板里是完整、未变形的令牌
                $back = [System.Windows.Forms.Clipboard]::GetText()
                if ($back -cne $expect) {
                    $err = "剪贴板内容与令牌不一致（读回 $($back.Length) 位，期望 $($expect.Length) 位）"
                }
            }
            catch { $err = $_.Exception.Message }

            if ($err) {
                $tokenHint.Text = '复制失败'
                Add-Log "复制 NapCat 令牌失败：$err"
                [void][System.Windows.Forms.MessageBox]::Show($form, ("复制失败：`r`n$err"), '复制 NapCat 令牌', 'OK', 'Warning')
                return
            }
            $btnCopyToken.Text = '已复制 ✓'
            $tokenHint.Text = '已复制 ✓'
            Add-Log ("NapCat 令牌已复制到剪贴板（$($expect.Length) 位，已读回校验）")
            Set-Status 'NapCat 令牌已复制到剪贴板'
            $copyHintTimer.Stop()
            $copyHintTimer.Start()
            $clipClearTimer.Stop()
            $clipClearTimer.Start()
        })

    function Refresh-Status {
        param([switch]$ResolvePid)
        try {
            $portSet = Get-ListeningPortSet
            foreach ($s in $Services) {
                # 只传一次 -ResolvePid（之前误写成 "-ResolvePid -ResolvePid:$ResolvePid"，
                # PowerShell 会报"参数被指定了多次"，整次刷新抛异常 → 界面永远停在已停止）
                $st = Get-ServiceStatus -Service $s -PortSet $portSet -ResolvePid:$ResolvePid
                $ui = $statusLabels[$s.Key]
                if ($st.Running) {
                    $ui.Strip.BackColor = $C.Brand
                    $ui.Badge.Text = '● 运行中'
                    $ui.Badge.BackColor = $C.BrandSoft
                    $ui.Badge.ForeColor = $C.BrandDark
                    $ui.Ports.ForeColor = $C.BrandDark
                }
                else {
                    $ui.Strip.BackColor = $C.StopDot
                    $ui.Badge.Text = '○ 已停止'
                    $ui.Badge.BackColor = $C.StopSoft
                    $ui.Badge.ForeColor = $C.TextSoft
                    $ui.Ports.ForeColor = $C.TextFaint
                }
                if ($st.Pid -gt 0 -and $st.Running) {
                    $ui.Ports.Text = "$($st.PortText)   ·   PID $($st.Pid)"
                }
                else {
                    $ui.Ports.Text = $st.PortText
                }
            }
        }
        catch { Write-GuiLog "刷新状态失败: $($_.Exception.Message)" }
    }

    function Set-Busy {
        param([bool]$Busy, [string]$Message = '就绪')
        # 本机修复：原来无论 $Busy 真假都设 WaitCursor，导致点过一次按钮后
        # 鼠标一直转圈、永不恢复。必须按 $Busy 显式切回默认光标。
        try {
            if ($Busy) {
                $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            }
            else {
                $form.Cursor = [System.Windows.Forms.Cursors]::Default
                $form.UseWaitCursor = $false
            }
        }
        catch { }
        foreach ($b in $buttons.Values) { $b.Enabled = -not $Busy }
        Set-Status $Message
        [System.Windows.Forms.Application]::DoEvents()
    }

    function Invoke-GuiAction {
        param([string]$BusyText, [scriptblock]$Body, [switch]$NoBusy)
        if (-not $NoBusy) { Set-Busy $true $BusyText }
        try { & $Body }
        catch {
            Add-Log "操作失败：$($_.Exception.Message)"
            Write-GuiLog "操作失败: $($_.ScriptStackTrace)"
        }
        finally {
            # 操作后需要准确的 PID，这里才反查一次；4 秒定时器不反查（见 Get-ServiceStatus 注释）
            Refresh-Status -ResolvePid
            if (-not $NoBusy) { Set-Busy $false }
        }
    }

    function Save-VersionConfig {
        try {
            $all = Get-PanelConfigHash
            $all['versionCheck'] = $script:verCfg
            [void](Save-PanelConfigHash -Hash $all)
        }
        catch { Write-GuiLog "保存版本检测设置失败: $($_.Exception.Message)" }
    }

    function Start-VersionCheck {
        if ($script:versionCheckRunning) { return }
        if (Test-Path -LiteralPath $VersionLockFile) {
            $age = (Get-Date) - (Get-Item -LiteralPath $VersionLockFile).LastWriteTime
            if ($age.TotalSeconds -lt 300) {
                $script:versionCheckRunning = $true
                $script:checkStartAt = (Get-Date)
                return
            }
        }
        try {
            Start-Process -FilePath 'powershell.exe' -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass',
                '-File', (Join-Path $PanelDir 'panel.ps1'),
                '-Action', 'checkversion', '-NoPause'
            ) -WorkingDirectory $PanelDir -WindowStyle Hidden
            $script:versionCheckRunning = $true
            $script:checkStartAt = (Get-Date)
            Set-Status '正在后台检测上游版本…'
            Add-Log '已开始检测上游版本（后台进程，不占用界面）…'
        }
        catch {
            Add-Log "启动版本检测失败：$($_.Exception.Message)"
        }
    }

    function Check-VersionSchedule {
        $mins = [int]$script:verCfg.intervalMinutes
        if ($mins -le 0) { return }
        if ((Get-Date) -lt $script:nextCheckAt) { return }
        $script:nextCheckAt = (Get-Date).AddMinutes($mins)
        Start-VersionCheck
    }

    function Refresh-VersionDisplay {
        if (-not (Test-Path -LiteralPath $VersionStateFile)) { return }
        $item = Get-Item -LiteralPath $VersionStateFile
        if ($script:lastStateMtime -and $item.LastWriteTime -eq $script:lastStateMtime) { return }
        $st = $null
        try {
            $raw = [System.IO.File]::ReadAllText($VersionStateFile, [System.Text.Encoding]::UTF8)
            $st = $raw | ConvertFrom-Json
        }
        catch {
            Write-GuiLog "版本检测结果解析失败: $($_.Exception.Message)"
            return
        }
        $script:lastStateMtime = $item.LastWriteTime
        $script:versionCheckRunning = $false

        $hasUpdate = $false
        foreach ($e in $st.repos) {
            $ui = $verLabels[$e.key]
            if (-not $ui) { continue }
            $ld = [string]$e.localDate
            if ($ld.Length -ge 16) { $ld = $ld.Substring(5) }
            $rd = [string]$e.remoteDate
            if ($rd.Length -ge 16) { $rd = $rd.Substring(5) }

            $lv = '—'
            if ($e.localVersion) { $lv = 'v' + [string]$e.localVersion }
            $ls = '—'
            if ($e.localSha) { $ls = [string]$e.localSha }
            # 列宽有限：日期移到 tooltip，行内只留"版本 + 提交"
            $line = "本地 ${lv}  ·  ${ls}"
            if ($e.localDirty) { $line = $line + '  ·  有改动' }
            $ui.Local.Text = $line

            $rv = '—'
            if ($e.remoteVersion) { $rv = 'v' + [string]$e.remoteVersion }
            $rs = '—'
            if ($e.remoteSha) { $rs = [string]$e.remoteSha }
            $rline = "上游 ${rv}  ·  ${rs}"
            $ui.Remote.Text = $rline

            $tipLocal = "本机已部署（自有版本）`r`n版本：$lv`r`n提交：$($e.localSha)`r`n提交时间：$($e.localDate)`r`n`r`n基线（构建所基于的上游提交）：`r`nv$($e.baseVersion)  $($e.baseSha)`r`n$($e.baseDate)"
            if ($e.localDirty) { $tipLocal += "`r`n`r`n⚠ 有未提交的已跟踪改动，同步前请先提交" }
            $verTip.SetToolTip($ui.Local, $tipLocal)
            $tipRemote = "上游 $($Repo.Branch)`r`n版本：$rv`r`n提交：$($e.remoteSha)`r`n提交时间：$($e.remoteDate)"
            if ($e.remoteMessage) { $tipRemote += "`r`n提交信息：$($e.remoteMessage)" }
            if ($e.source) { $tipRemote += "`r`n数据源：$($e.source)" }
            $verTip.SetToolTip($ui.Remote, $tipRemote)

            if ($e.error) {
                $ui.State.Text = '! 检测失败'
                $ui.State.ForeColor = $C.Danger
                $ui.Remote.Text = '上游  ' + [string]$e.error
                $verTip.SetToolTip($ui.State, [string]$e.error)
            }
            elseif ($e.behind) {
                $ui.State.Text = "● 有新版本（基线 $($e.baseSha)）"
                $ui.State.ForeColor = $C.Warn
                $ui.Remote.ForeColor = $C.Warn
                $ui.Local.ForeColor = $C.TextSoft
                $hasUpdate = $true
                $verTip.SetToolTip($ui.State, "上游比基线新`r`n基线：$($e.baseSha)`r`n上游：$($e.remoteSha)`r`n`r`n先点「查看差异」，确认后再同步`r`n$($e.remoteMessage)")
            }
            else {
                $ui.State.Text = "● 与基线一致（$($e.baseSha)）"
                $ui.State.ForeColor = $C.BrandDark
                $ui.Remote.ForeColor = $C.TextSoft
                $ui.Local.ForeColor = $C.TextSoft
                $verTip.SetToolTip($ui.State, "上游没有超出基线的提交`r`n基线：$($e.baseSha)`r`n本地自有提交不影响这个判断")
            }
        }

        $when = ''
        if ($st.finishedAt) {
            try { $when = ([datetime]::Parse([string]$st.finishedAt)).ToLocalTime().ToString('HH:mm:ss') } catch { }
        }
        if ($hasUpdate) {
            $verState.Text = "● 上游有新版本（相对基线）—— 先「查看差异」再同步   （检测于 $when）"
            $verState.ForeColor = $C.Warn
            Set-Status '上游有新版本：先点「查看差异」，确认后再同步'
        }
        elseif ($st.anyError) {
            $verState.Text = "! 部分仓库检测失败   （$when）"
            $verState.ForeColor = $C.Danger
        }
        else {
            $verState.Text = "● 全部已是最新   （检测于 $when）"
            $verState.ForeColor = $C.BrandDark
        }

        if ($hasUpdate -and $chkNotify.Checked) {
            foreach ($e in $st.repos) {
                if (-not $e.behind) { continue }
                $sha = [string]$e.remoteSha
                $seen = ''
                if ($script:verCfg.notifiedSha.ContainsKey($e.key)) { $seen = [string]$script:verCfg.notifiedSha[$e.key] }
                if ($seen -eq $sha) { continue }
                Add-Log "发现新版本：$($e.name)  上游 $sha（本地 $($e.localSha)）"
                $script:verCfg.notifiedSha[$e.key] = $sha
                Save-VersionConfig
                $msg = "$([string]$e.name) 检测到上游新版本：`r`n`r`n"
                $msg += "本地：v$($e.localVersion)  $($e.localSha)`r`n"
                $msg += "上游：v$($e.remoteVersion)  $($e.remoteSha)`r`n`r`n"
                if ($e.remoteDate) { $msg += "提交时间：$($e.remoteDate)`r`n" }
                if ($e.remoteMessage) { $msg += "提交信息：$($e.remoteMessage)`r`n" }
                $msg += "`r`n需要更新时，点控制面板的「同步上游」。"
                [void][System.Windows.Forms.MessageBox]::Show($form, $msg, '发现上游新版本', 'OK', 'Information')
            }
        }
    }

    # ---------- 版本检测区交互 ----------
    $script:suppressComboEvent = $true
    $curName = '30 分钟'
    foreach ($k in $VersionIntervals.Keys) {
        if ([int]$VersionIntervals[$k] -eq [int]$script:verCfg.intervalMinutes) { $curName = $k; break }
    }
    $comboInterval.SelectedItem = $curName
    $script:suppressComboEvent = $false

    $comboInterval.Add_SelectedIndexChanged({
            if ($script:suppressComboEvent) { return }
            $name = [string]$comboInterval.SelectedItem
            if (-not $VersionIntervals.Contains($name)) { return }
            $mins = [int]$VersionIntervals[$name]
            $script:verCfg['intervalMinutes'] = $mins
            Save-VersionConfig
            if ($mins -gt 0) {
                $script:nextCheckAt = (Get-Date).AddMinutes($mins)
                Add-Log "自动检测间隔已设为 $name"
            }
            else {
                Add-Log '自动检测已关闭（仅手动「立即检测」）'
            }
        })

    $chkNotify.Add_CheckedChanged({
            $script:verCfg['notifyPopup'] = $chkNotify.Checked
            Save-VersionConfig
        })

    $btnCheckNow.Add_Click({
            $script:versionCheckRunning = $false
            $script:nextCheckAt = (Get-Date)
            Start-VersionCheck
        })

    # ---------- 主操作区交互 ----------
    $buttons['startAll'].Add_Click({
            Invoke-GuiAction -BusyText '正在启动服务…' -Body {
                Add-Log '启动主程序'
                Invoke-StartAll | Out-Null
            }
        })

    $buttons['stopAll'].Add_Click({
            Invoke-GuiAction -BusyText '正在停止服务…' -Body {
                Add-Log '停止主程序'
                Invoke-StopAll | Out-Null
            }
        })

    $buttons['restart'].Add_Click({
            Invoke-GuiAction -BusyText '正在重启服务…' -Body {
                Add-Log '重启主程序'
                Invoke-StopAll | Out-Null
                Start-Sleep -Milliseconds 800
                Invoke-StartAll | Out-Null
            }
        })

    $buttons['openFarm'].Add_Click({
            Invoke-GuiAction -NoBusy -Body {
                Start-Process 'http://127.0.0.1:3007'
                Add-Log '已打开农场面板：http://127.0.0.1:3007'
            }
        })

    $buttons['openNapcat'].Add_Click({
            Invoke-GuiAction -NoBusy -Body {
                Start-Process 'http://127.0.0.1:6099/webui/'
                Add-Log '已打开 NapCat WebUI。'
            }
        })

    $buttons['startNapcat'].Add_Click({
            $desktops = @(Get-DesktopQqProcesses)
            $closeDesktop = $false
            if ($desktops.Count -gt 0) {
                $hint = Format-DesktopQqHint $desktops
                $msg = "检测到桌面版 QQ 正在运行：`r`n  $hint`r`n`r`n" +
                "它会占用同一个 QQ 号的会话。如果不关掉，NapCat 登录会报`r`n" +
                "「当前账号已登录，无法重复登录」，扫码点确认后也不会有任何反应。`r`n`r`n" +
                "是否关闭桌面版 QQ 并启动 NapCat？"
                $answer = [System.Windows.Forms.MessageBox]::Show($msg, '启动 NapCat', 'YesNo', 'Warning')
                if ($answer -ne 'Yes') {
                    Add-Log '已取消：桌面版 QQ 仍在运行。请手动退出后再启动 NapCat。'
                    return
                }
                $closeDesktop = $true
            }
            else {
                $answer = [System.Windows.Forms.MessageBox]::Show(
                    "启动 NapCat 会用同一个 QQ 号登录 QQ 协议端。" + "`r`n" +
                    "启动后不弹控制台窗口（隐藏窗口运行），日志写到 napcat\logs\ 目录。" + "`r`n`r`n是否继续？",
                    '启动 NapCat', 'YesNo', 'Warning')
                if ($answer -ne 'Yes') { return }
            }
            Invoke-GuiAction -BusyText '正在启动 NapCat…' -Body {
                Add-Log '启动 NapCat（上游 launcher，等待 UAC 授权）…'
                $startArgs = @{}
                if ($closeDesktop) { $startArgs['CloseDesktopQq'] = $true }
                [void](Start-NapCatService @startArgs)
                Start-Sleep -Seconds 2
            }
        })

    $buttons['stopNapcat'].Add_Click({
            $answer = [System.Windows.Forms.MessageBox]::Show(
                "停止 NapCat 只会结束 NapCat 自己拉起的那组进程" + "`r`n" +
                "（判据：父进程是 NapCatWinBootMain、或 QQ 命令行带 --enable-logging）。" + "`r`n" +
                "你自己打开的桌面版 QQ 不带这些特征，不会被结束。" + "`r`n`r`n是否继续？",
                '停止 NapCat', 'YesNo', 'Warning')
            if ($answer -ne 'Yes') { return }
            Invoke-GuiAction -BusyText '正在停止 NapCat…' -Body {
                Add-Log '停止 NapCat…'
                Stop-NapCatService
            }
        })

    $buttons['prepScan'].Add_Click({
            $answer = [System.Windows.Forms.MessageBox]::Show(
                "把「QQ 扫码登录」恢复成可用状态：" + "`r`n`r`n" +
                "1) 让 NapCat 退出当前已登录的 QQ（否则拿不到登录二维码）" + "`r`n`r`n" +
                "为什么需要：扫码登录要求 NapCat 处于未登录状态。" + "`r`n" +
                "NapCat 已登录某个 QQ 时，界面会显示「二维码不可用」。" + "`r`n`r`n是否继续？",
                '准备 QQ 扫码登录', 'YesNo', 'Question')
            if ($answer -ne 'Yes') { return }
            Invoke-GuiAction -BusyText '正在准备扫码环境…' -Body {
                Add-Log '准备 QQ 扫码登录（NapCat 注销）'
                [void](Reset-QqScanLogin)
            }
        })

    $buttons['update'].Add_Click({
            Invoke-GuiAction -NoBusy -Body {
                Add-Log '正在生成上游差异报告（基线 → 上游最新）…'
                Start-Process -FilePath 'powershell.exe' -ArgumentList @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PanelDir 'panel.ps1'),
                    '-Action', 'upstreamdiff', '-NoPause'
                ) -WorkingDirectory $PanelDir
            }
        })

    $buttons['sync'].Add_Click({
            # 强约束：必须先看差异（24 小时内）、再明确确认；同步进程独立窗口可见
            $diff = Join-Path $RunDir 'upstream-diff.md'
            if (-not (Test-Path -LiteralPath $diff)) {
                [void][System.Windows.Forms.MessageBox]::Show($form,
                    "还没有差异报告。`r`n`r`n请先点「查看差异」，确认上游改了什么，再回来同步。",
                    '同步上游', 'OK', 'Warning')
                return
            }
            $age = (Get-Date) - (Get-Item -LiteralPath $diff).LastWriteTime
            if ($age.TotalHours -gt 24) {
                [void][System.Windows.Forms.MessageBox]::Show($form,
                    "差异报告已超过 24 小时（$([int]$age.TotalHours) 小时前），可能已过期。`r`n`r`n请重新点「查看差异」。",
                    '同步上游', 'OK', 'Warning')
                return
            }
            $msg = "将把「基线之后的上游提交」作为补丁应用到本机代码。`r`n`r`n" +
            "· 只执行 git apply --3way（上游 diff），**不会** reset 或覆盖自有改动`r`n" +
            "· 预检发现冲突就停，工作树不会被修改`r`n" +
            "· 应用失败会立即回滚到同步前的备份 tag`r`n" +
            "· 成功后更新 baseline.json 并提交（保留来源记录）`r`n`r`n" +
            "确认已看过差异报告，继续同步？"
            if ([System.Windows.Forms.MessageBox]::Show($form, $msg, '同步上游（需确认）', 'YesNo', 'Warning') -ne 'Yes') { return }
            Add-Log '开始同步上游（独立窗口，过程可见）…'
            Start-Process -FilePath 'powershell.exe' -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PanelDir 'panel.ps1'),
                '-Action', 'syncupstream', '-ConfirmSync', '-NoPause'
            ) -WorkingDirectory $PanelDir
        })

    # 「重新构建」按钮已移除（固化版本不再改前端，且按钮里的 pnpm install -r
    # 会把 hoisted 依赖布局改成 isolated、失败还可能留半装状态）。
    # 真需要重建前端时用命令行：panel.ps1 -Action build

    $buttons['shortcut'].Add_Click({
            Invoke-GuiAction -NoBusy -Body {
                Add-Log '重建桌面快捷方式…'
                [void](New-DesktopShortcut)
            }
        })

    $buttons['status'].Add_Click({
            Invoke-GuiAction -NoBusy -Body {
                Add-Log '已刷新状态。'
                Set-Status '状态已刷新'
            }
        })

    $buttons['logs'].Add_Click({
            Invoke-GuiAction -NoBusy -Body {
                $d = Join-Path $Root 'data\logs'
                if (Test-Path -LiteralPath $d) { Start-Process $d } else { Add-Log "目录不存在：$d" }
            }
        })
    $buttons['napcatLogs'].Add_Click({
            Invoke-GuiAction -NoBusy -Body {
                $d = Join-Path $Root 'napcat\logs'
                if (Test-Path -LiteralPath $d) { Start-Process $d } else { Add-Log "目录不存在：$d" }
            }
        })
    $buttons['dir'].Add_Click({ Invoke-GuiAction -NoBusy -Body { Start-Process $Root } })

    $btnClearLog.Add_Click({ try { $logBox.Clear(); Set-Status '日志已清空' } catch { } })
    $btnLogFolder.Add_Click({
            Invoke-GuiAction -NoBusy -Body {
                $d = Join-Path $Root 'data\logs'
                if (Test-Path -LiteralPath $d) { Start-Process $d } else { Start-Process $LogDir }
            }
        })
    $btnExit.Add_Click({ $form.Close() })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 4000
    $timer.Add_Tick({
            Refresh-Status
            Refresh-VersionDisplay
            if ($script:versionCheckRunning -and $script:checkStartAt -and ((Get-Date) - $script:checkStartAt).TotalMinutes -gt 3) {
                $script:versionCheckRunning = $false
            }
            Check-VersionSchedule
        })

    $form.Add_Shown({
            Write-GuiLog '面板已显示（Shown）'
            Refresh-Status
            $permText = if (Test-IsElevated) { '管理员' } else { '普通（停止 NapCat 时会弹一次 UAC）' }
            Set-Status "就绪 · 部署目录 $Root · 权限：$permText"
            $timer.Start()
            if ($script:SelfTestMode) {
                $st = New-Object System.Windows.Forms.Timer
                $st.Interval = 1500
                $st.Add_Tick({
                        $st.Stop()
                        Write-GuiLog '自检：窗体构建 + 显示 + 首次状态刷新 全部成功'
                        $form.Close()
                    })
                $st.Start()
            }
            elseif ([int]$script:verCfg.intervalMinutes -gt 0) {
                Start-VersionCheck
            }
        })
    $form.Add_FormClosed({
            try { $timer.Stop() } catch { }
            $script:GuiLogSink = $null
            Write-GuiLog '面板已关闭'
        })

    Write-GuiLog '开始 ShowDialog'
    [void]$form.ShowDialog()
    Write-GuiLog 'ShowDialog 已返回'
}

if ($Action -eq 'gui') {
    # 剪贴板是 OLE 调用，必须在 STA 线程上用；PowerShell 默认是 MTA，
    # 直接调 [Windows.Forms.Clipboard]::SetText 会抛
    # "Current thread must be set to single thread apartment (STA) mode"。
    # 所以只要不是 STA，就用 -STA 重新拉起自己（用环境变量做标记，防止死循环）。
    $apartment = [System.Threading.Thread]::CurrentThread.GetApartmentState()
    if ($apartment -ne 'STA' -and -not $env:QQFARM_PANEL_STA) {
        $env:QQFARM_PANEL_STA = '1'
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        try {
            Start-Process -FilePath $psExe -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA',
                '-WindowStyle', 'Hidden', '-File', $MyInvocation.MyCommand.Path
            ) | Out-Null
            Write-Host '  已用 STA 模式重新启动控制面板（剪贴板需要 STA）。' -ForegroundColor Gray
            return
        }
        catch {
            Write-Host "  [警告] 无法以 STA 重启，剪贴板复制可能不可用：$($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    Show-Gui
}

# selftest 的窗口构建入口：必须放在 Show-Gui 定义之后，
# 否则调用时函数还不存在（纯语法解析也发现不了这类运行期错误）。
if ($script:RunGuiSelfTest) {
    Write-Line ''
    Write-Line '  ---- 构建窗口（1.5 秒后自动关闭）----' 'Gray'
    try {
        Show-Gui
        Write-Line '  窗口构建与首次状态刷新：通过' 'Green'
    }
    catch {
        Write-Line ("  窗口构建失败：$($_.Exception.Message)") 'Red'
    }
}
