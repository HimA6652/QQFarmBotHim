<#
============================================================================
 QQ农场助手 · 取码器版 · 控制面板（Web）
============================================================================
 端口   面板 3100 / 主程序 3007 / 抓码 API 8450 / 抓码代理 18000

 设计要点
   - 面板只做三件事：启停主程序、启停取码器（本机 MITM）、把 P0 串起来
   - 取码器 = 主程序自带的 capture 内核（独立进程模式），抓到 code 供账号使用
   - 不含任何 QQ 协议端（NapCat / SnowLuma 均已移除）
   - 动作交给子进程执行，避免阻塞 HTTP 线程；只接受私网来源
#>
[CmdletBinding()]
param(
    [ValidateSet('web', 'start', 'stop', 'startp0', 'stopp0', 'startcapture', 'stopcapture', 'renewcapture', 'status')]
    [string]$Action = 'web',
    [switch]$NoPause,
    [string]$WebBind = '0.0.0.0',
    [int]$WebPort = 3100
)

$ErrorActionPreference = 'Continue'
$PanelDir = $PSScriptRoot
$Root = Split-Path -Parent $PanelDir
$CoreDir = Join-Path $Root 'core'
$ToolsDir = Join-Path $Root 'tools'
$LogDir = Join-Path $Root 'logs'
$RunDir = Join-Path $PanelDir 'run'
$DataDir = Join-Path $Root 'data'
foreach ($d in @($LogDir, $RunDir, $DataDir)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

$MainPort = 3007
$CapApiPort = 8450
$CapProxyPort = 18000
$CapSessionId = 'pc-local'
$CapLog = Join-Path $LogDir 'capture-server.log'
$MainPidFile = Join-Path $RunDir 'farm.pid'
$CapPidFile = Join-Path $RunDir 'capture.pid'
$PanelLog = Join-Path $LogDir 'panel.log'

# ---- 取码器（注入式）----
$FetcherPort = 8460
$FetcherScript = Join-Path $Root 'fetcher\code-fetcher.mjs'
$FetcherPidFile = Join-Path $RunDir 'fetcher.pid'
$FetcherLog = Join-Path $LogDir 'fetcher.log'
$LocalTokenFile = Join-Path $DataDir 'local-api-token.txt'

# ---------------------------------------------------------------- 基础工具
function Write-Line {
    param([string]$Text = '', [string]$Color = 'Gray')
    $c = switch ($Color) {
        'Red' { 'Red' } 'Yellow' { 'Yellow' } 'Green' { 'Green' }
        'Cyan' { 'Cyan' } 'DarkGray' { 'DarkGray' } default { 'Gray' }
    }
    Write-Host $Text -ForegroundColor $c
    try {
        $stamp = (Get-Date).ToString('HH:mm:ss')
        [System.IO.File]::AppendAllText($PanelLog, "[$stamp] $Text`r`n", [System.Text.Encoding]::UTF8)
    }
    catch { }
}

function Test-PortOpen {
    param([int]$Port)
    try {
        $c = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        return [bool]$c
    }
    catch { return $false }
}

function Get-PortOwner {
    param([int]$Port)
    try {
        $c = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($c) { return [int]$c.OwningProcess }
    }
    catch { }
    return 0
}

function Wait-Port {
    param([int]$Port, [int]$TimeoutSec = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-PortOpen -Port $Port) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

function Read-TailLines {
    param([string]$Path, [int]$Lines = 120)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    try {
        $share = [System.IO.FileShare]([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
        try {
            $len = [int][Math]::Min($fs.Length, 400000)
            if ($len -le 0) { return @() }
            [void]$fs.Seek(-$len, [System.IO.SeekOrigin]::End)
            $buf = New-Object byte[] $len
            [void]$fs.Read($buf, 0, $len)
            $text = [System.Text.Encoding]::UTF8.GetString($buf)
        }
        finally { $fs.Close() }
        $text = [regex]::Replace($text, "`e\[[0-9;]*[A-Za-z]", '')
        $all = $text -split "`r?`n"
        if ($all.Count -le $Lines) { return $all }
        return ($all[($all.Count - $Lines)..($all.Count - 1)])
    }
    catch { return @() }
}

function Mask-Code {
    param([string]$Code)
    if (-not $Code) { return '' }
    if ($Code.Length -le 10) { return $Code.Substring(0, [Math]::Max(2, [int]($Code.Length / 2))) + '…' }
    return $Code.Substring(0, 4) + '…' + $Code.Substring($Code.Length - 4)
}

# ---------------------------------------------------------------- 取码器
function Invoke-CapApi {
    param([string]$Method, [string]$Path, $Body)
    $uri = "http://127.0.0.1:$CapApiPort$Path"
    try {
        if ($Body) {
            $json = ($Body | ConvertTo-Json -Compress)
            return Invoke-RestMethod -Method $Method -Uri $uri -ContentType 'application/json; charset=utf-8' `
                -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 15
        }
        return Invoke-RestMethod -Method $Method -Uri $uri -TimeoutSec 10
    }
    catch { return $null }
}

function Start-CaptureService {
    $entry = Join-Path $CoreDir 'capture-server.js'
    if (-not (Test-Path -LiteralPath $entry)) {
        Write-Line "  [取码器] 缺少 $entry" 'Red'
        return $false
    }
    if (Test-PortOpen -Port $CapApiPort) {
        Write-Line "  [取码器] 已在运行（API $CapApiPort）" 'Green'
    }
    else {
        $nodeExe = Join-Path $Root 'runtime\node\node.exe'
        if (-not (Test-Path -LiteralPath $nodeExe)) {
            $nodeExe = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
            if (-not $nodeExe) { Write-Line '  [取码器] 找不到 node.exe' 'Red'; return $false }
        }
        try {
            $env:CAPTURE_PROXY_BIND = '0.0.0.0'
            # 用 cmd 重定向启动：PowerShell 在 HTTP_PROXY/http_proxy 大小写重复时
            # 用 -RedirectStandardOutput 会抛「已添加项」，cmd 重定向不受影响。
            $cmdLine = '/c ""{0}" capture-server.js 1>"{1}" 2>&1"' -f $nodeExe, $CapLog
            Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') `
                -ArgumentList $cmdLine -WorkingDirectory $CoreDir -WindowStyle Hidden | Out-Null
            if (-not (Wait-Port -Port $CapApiPort -TimeoutSec 25)) {
                Write-Line '  [取码器] API 25 秒内未就绪，见 logs\capture-server.log' 'Red'
                return $false
            }
            $owner = Get-PortOwner -Port $CapApiPort
            if ($owner) { Set-Content -LiteralPath $CapPidFile -Value "$owner|0" -Encoding ascii }
            Write-Line "  [取码器] API 就绪：http://127.0.0.1:$CapApiPort（pid $owner）" 'Green'
        }
        catch {
            Write-Line "  [取码器] 启动失败：$($_.Exception.Message)" 'Red'
            return $false
        }
    }
    return (Start-CaptureSession)
}

function Start-CaptureSession {
    <#  建会话并启动 MITM 代理（幂等：已在跑就只提示）。 #>
    Invoke-CapApi -Method 'POST' -Path '/api/sessions' -Body @{ sessionId = $CapSessionId; platform = 'qq' } | Out-Null
    $snap = Invoke-CapApi -Method 'GET' -Path "/api/sessions/$CapSessionId/state"
    if ($snap -and $snap.data -and $snap.data.proxy -and $snap.data.proxy.running -eq $true) {
        Write-Line "  [取码器] 代理已在运行：$CapProxyPort（沿用当前会话）" 'Green'
    }
    else {
        $started = Invoke-CapApi -Method 'POST' -Path '/api/capture/start' -Body @{ sessionId = $CapSessionId }
        if (-not $started -or $started.ok -ne $true) {
            Write-Line '  [取码器] 代理启动失败（见 logs\capture-server.log）' 'Red'
            return $false
        }
        Write-Line "  [取码器] 代理已启动：0.0.0.0:$CapProxyPort（会话 $CapSessionId）" 'Green'
    }
    $snap = Invoke-CapApi -Method 'GET' -Path "/api/sessions/$CapSessionId/state"
    if ($snap -and $snap.data -and $snap.data.publicInfo -and $snap.data.publicInfo.addresses) {
        $addrs = (@($snap.data.publicInfo.addresses) | ForEach-Object { "$($_.address):$CapProxyPort" }) -join ' / '
        Write-Line "  [取码器] 代理地址：$addrs" 'DarkGray'
    }
    Write-Line '  [取码器] 用法：运行 tools\抓码-开启.ps1（装证书 + 设系统代理），重启 QQ 后打开农场' 'DarkGray'
    return $true
}

function Stop-CaptureService {
    $snap = Invoke-CapApi -Method 'GET' -Path "/api/sessions/$CapSessionId/state"
    if ($snap) {
        Invoke-CapApi -Method 'POST' -Path '/api/capture/stop' -Body @{ sessionId = $CapSessionId } | Out-Null
        Invoke-CapApi -Method 'DELETE' -Path "/api/sessions/$CapSessionId" | Out-Null
    }
    $stopped = 0
    if (Test-Path -LiteralPath $CapPidFile) {
        $rec = (Get-Content -LiteralPath $CapPidFile -Raw).Trim()
        $parts = $rec -split '\|'
        $targetPid = [int]$parts[0]
        if ($targetPid) {
            try { Stop-Process -Id $targetPid -Force -ErrorAction SilentlyContinue; $stopped++ } catch { }
        }
        Remove-Item -LiteralPath $CapPidFile -Force -ErrorAction SilentlyContinue
    }
    $owner = Get-PortOwner -Port $CapApiPort
    if ($owner) { try { Stop-Process -Id $owner -Force -ErrorAction SilentlyContinue; $stopped++ } catch { } }
    $apiState = if (Test-PortOpen -Port $CapApiPort) { '仍占用' } else { '已释放' }
    $proxyState = if (Test-PortOpen -Port $CapProxyPort) { '仍占用' } else { '已释放' }
    Write-Line "  [取码器] 已停止 $stopped 个进程；8450 $apiState、18000 $proxyState" 'Green'
}

function Get-CaptureStatus {
    $apiUp = Test-PortOpen -Port $CapApiPort
    $proxyUp = Test-PortOpen -Port $CapProxyPort
    $codes = @()
    $addresses = @()
    $remaining = 0
    $status = 'idle'
    if ($apiUp) {
        $snap = Invoke-CapApi -Method 'GET' -Path "/api/sessions/$CapSessionId/state"
        if ($snap -and $snap.data) {
            $ch = $snap.data.channels.qq
            if ($ch) {
                $status = [string]$ch.status
                foreach ($c in @($ch.codes)) {
                    if ($c -and $c.code) {
                        $codes += [ordered]@{ masked = (Mask-Code $c.code); openid = [string]$c.openid; ver = [string]$c.clientVersion }
                    }
                }
            }
            $pi = $snap.data.publicInfo
            if ($pi) {
                $remaining = [int]$pi.remainingSec
                # 独立进程模式的快照里可能没有 remainingSec，用 startedAt + autoStopSec 现算
                if ($remaining -le 0 -and $pi.autoStopSec -and $pi.startedAt) {
                    try {
                        $startedAt = [datetime]$pi.startedAt
                        $remaining = [int](($startedAt.AddSeconds([int]$pi.autoStopSec)) - (Get-Date)).TotalSeconds
                        if ($remaining -lt 0) { $remaining = 0 }
                    }
                    catch { }
                }
                foreach ($a in @($pi.addresses)) { if ($a.address) { $addresses += [string]$a.address } }
            }
        }
    }
    return [ordered]@{
        running      = $apiUp
        proxyUp      = $proxyUp
        apiPort      = $CapApiPort
        proxyPort    = $CapProxyPort
        status       = $status
        session      = $CapSessionId
        addresses    = @($addresses)
        certUrl      = "http://127.0.0.1:$CapApiPort/cert/mitmproxy-ca-cert.cer"
        codes        = @($codes)
        codeCount    = $codes.Count
        remainingSec = $remaining
        logFile      = $CapLog
    }
}

# ---------------------------------------------------------------- 取码器（注入式）
function Invoke-FetcherApi {
    param([string]$Method, [string]$Path)
    try {
        return Invoke-RestMethod -Method $Method -Uri "http://127.0.0.1:$FetcherPort$Path" -TimeoutSec 8
    }
    catch { return $null }
}

function Get-FetcherState {
    $running = Test-PortOpen -Port $FetcherPort
    if (-not $running) { return [ordered]@{ running = $false; phase = 'idle' } }
    $s = Invoke-FetcherApi -Method 'GET' -Path '/state'
    if (-not $s) { return [ordered]@{ running = $true; phase = 'unknown' } }
    return [ordered]@{
        running    = $true
        phase      = [string]$s.phase
        qr         = [string]$s.qr
        qrPng      = [string]$s.qrPng
        uin        = [string]$s.uin
        nickname   = [string]$s.nickname
        codeMasked = $(if ($s.code) { (Mask-Code ([string]$s.code)) } else { '' })
        error      = [string]$s.error
        elapsedSec = [int]$s.elapsedSec
    }
}

function Get-QqPath {
    # 解析 QQ.exe：注册表 -> 常见路径 -> fetcher\qqpath.txt
    try {
        $key = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\QQ'
        $item = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if ($item -and $item.UninstallString) {
            $dir = Split-Path -Parent ($item.UninstallString.Trim('"'))
            $exe = Join-Path $dir 'QQ.exe'
            if (Test-Path -LiteralPath $exe) { return $exe }
        }
    }
    catch { }
    foreach ($candidate in @('D:\ProgramData\QQ\QQ.exe', (Join-Path $env:ProgramFiles 'Tencent\QQNT\QQ.exe'))) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    $qqFile = Join-Path $Root 'fetcher\qqpath.txt'
    if (Test-Path -LiteralPath $qqFile) {
        $p = (Get-Content -LiteralPath $qqFile -Raw).Trim()
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return ''
}

function Start-Fetcher {
    param([string]$Mode = 'new', [string]$AccountId = '', [int]$TimeoutSec = 180)
    if (Test-PortOpen -Port $FetcherPort) {
        Write-Line "  [取码器] 已有会话在跑（$FetcherPort），请先取消。" 'Yellow'
        return $false
    }
    if (-not (Test-Path -LiteralPath $FetcherScript)) {
        Write-Line "  [取码器] 缺少 $FetcherScript" 'Red'
        return $false
    }
    $nodeExe = Join-Path $Root 'runtime\node\node.exe'
    if (-not (Test-Path -LiteralPath $nodeExe)) {
        $nodeExe = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
        if (-not $nodeExe) { Write-Line '  [取码器] 找不到 node.exe' 'Red'; return $false }
    }
    try {
        $qq = Get-QqPath
        $args = @($FetcherScript, '--port', $FetcherPort, '--timeout', $TimeoutSec, '--mode', $Mode)
        if ($qq) { $args += @('--qq', $qq) }
        else { Write-Line '  [取码器] 未找到 QQ.exe，请把路径写进 fetcher\qqpath.txt' 'Yellow' }
        $p = Start-Process -FilePath $nodeExe -ArgumentList $args -WorkingDirectory $Root -WindowStyle Hidden -PassThru
        Set-Content -LiteralPath $FetcherPidFile -Value "$($p.Id)|0" -Encoding ascii
        Write-Line "  [取码器] 已启动会话（pid $($p.Id)，模式 $Mode）" 'Green'
        return $true
    }
    catch {
        Write-Line "  [取码器] 启动失败：$($_.Exception.Message)" 'Red'
        return $false
    }
}

function Stop-Fetcher {
    # 先让取码器自己收尾（它会杀 QQ 进程树），再兜底杀进程
    [void](Invoke-FetcherApi -Method 'POST' -Path '/cancel')
    Start-Sleep -Milliseconds 800
    if (Test-Path -LiteralPath $FetcherPidFile) {
        $rec = (Get-Content -LiteralPath $FetcherPidFile -Raw).Trim()
        $parts = $rec -split '\|'
        $targetPid = [int]$parts[0]
        if ($targetPid) { try { Stop-Process -Id $targetPid -Force -ErrorAction SilentlyContinue } catch { } }
        Remove-Item -LiteralPath $FetcherPidFile -Force -ErrorAction SilentlyContinue
    }
    $owner = Get-PortOwner -Port $FetcherPort
    if ($owner) { try { Stop-Process -Id $owner -Force -ErrorAction SilentlyContinue } catch { } }
    Write-Line "  [取码器] 会话已结束（端口 $FetcherPort $(if (Test-PortOpen -Port $FetcherPort) {'仍占用'} else {'已释放'})）" 'Green'
}

function Invoke-ApplyCode {
    <#  把取码器拿到的 code 交给主程序：新建账号或更新失效账号。  #>
    param([string]$Mode = 'new', [string]$AccountId = '')
    $s = Invoke-FetcherApi -Method 'GET' -Path '/state'
    if (-not $s -or -not $s.code) {
        Write-Line '  [取码器] 还没有可用的 code。' 'Yellow'
        return $false
    }
    $token = ''
    if (Test-Path -LiteralPath $LocalTokenFile) { $token = (Get-Content -LiteralPath $LocalTokenFile -Raw).Trim() }
    if (-not $token) {
        Write-Line '  [取码器] 读不到主程序的本机令牌（data\local-api-token.txt），主程序可能没启动过。' 'Red'
        return $false
    }
    if (-not (Test-PortOpen -Port $MainPort)) {
        Write-Line '  [取码器] 主程序未运行（3007），无法写入账号。' 'Red'
        return $false
    }
    $payload = @{
        token     = $token
        mode      = $(if ($Mode -eq 'refresh') { 'refresh' } else { 'new' })
        code      = [string]$s.code
        platform  = 'qq'
        uin       = [string]$s.uin
        name      = [string]$s.nickname
        accountId = $AccountId
    } | ConvertTo-Json -Compress
    try {
        $res = Invoke-RestMethod -Method 'POST' -Uri "http://127.0.0.1:$MainPort/api/local/code-account" `
            -ContentType 'application/json; charset=utf-8' `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($payload)) -TimeoutSec 20
        if ($res.ok) {
            $d = $res.data
            Write-Line ("  [取码器] 已写入账号 #{0}（{1}）并触发启动" -f $d.accountId, $(if ($d.created) { '新建' } else { '更新' })) 'Green'
            return $true
        }
        Write-Line ("  [取码器] 主程序拒绝：{0}" -f $res.error) 'Red'
        return $false
    }
    catch {
        Write-Line "  [取码器] 写入账号失败：$($_.Exception.Message)" 'Red'
        return $false
    }
}

# ---------------------------------------------------------------- 主程序
function Start-FarmService {
    $launcher = Join-Path $Root 'launch.ps1'
    if (-not (Test-Path -LiteralPath $launcher)) {
        Write-Line "  [主程序] 缺少启动器：$launcher" 'Red'
        return $false
    }
    if (Test-PortOpen -Port $MainPort) {
        Write-Line "  [主程序] 已在运行（端口 $MainPort）" 'Green'
        return $true
    }
    Remove-Item -LiteralPath $MainPidFile -Force -ErrorAction SilentlyContinue
    try {
        Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launcher, '-Hidden') `
            -WorkingDirectory $Root -WindowStyle Hidden | Out-Null
        Write-Line "  [主程序] 已请求启动，等待 $MainPort …" 'Green'
        if (Wait-Port -Port $MainPort -TimeoutSec 40) {
            Write-Line "  [主程序] 就绪： http://127.0.0.1:$MainPort" 'Green'
            return $true
        }
        Write-Line '  [主程序] 40 秒内未监听，见 data\logs\combined-*.log' 'Red'
        return $false
    }
    catch {
        Write-Line "  [主程序] 启动失败：$($_.Exception.Message)" 'Red'
        return $false
    }
}

function Test-FarmProcess {
    param([int]$ProcessId)
    try {
        $ci = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
        if (-not $ci) { return $false }
        return ([string]$ci.CommandLine -match 'core[\\/]client\.js')
    }
    catch { return $false }
}

function Stop-FarmService {
    $stopped = 0
    if (Test-Path -LiteralPath $MainPidFile) {
        $rec = (Get-Content -LiteralPath $MainPidFile -Raw).Trim()
        $parts = $rec -split '\|'
        $targetPid = [int]$parts[0]
        if ($targetPid -and (Test-FarmProcess -ProcessId $targetPid)) {
            Stop-Process -Id $targetPid -Force -ErrorAction SilentlyContinue
            $stopped++
        }
        Remove-Item -LiteralPath $MainPidFile -Force -ErrorAction SilentlyContinue
    }
    $owner = Get-PortOwner -Port $MainPort
    if ($owner -and (Test-FarmProcess -ProcessId $owner)) {
        Stop-Process -Id $owner -Force -ErrorAction SilentlyContinue
        $stopped++
    }
    $mainState = if (Test-PortOpen -Port $MainPort) { '仍占用' } else { '已释放' }
    Write-Line "  [主程序] 已结束 $stopped 个进程；端口 $MainPort $mainState" 'Green'
}

# ---------------------------------------------------------------- P0 编排
function Invoke-StartP0 {
    Write-Line '================ P0：启动取码器 → 主程序 ================' 'Cyan'
    $capOk = Start-CaptureService
    if (-not $capOk) { Write-Line '  [P0] 取码器未就绪，继续启动主程序（已建账号仍可正常运行）。' 'Yellow' }
    $mainOk = Start-FarmService
    if (-not $mainOk) { Write-Line '  [P0] 主程序未就绪，请检查 data\logs。' 'Red'; return $false }
    Write-Line ''
    Write-Line '  [P0] 就绪。添加/恢复账号时：' 'Cyan'
    Write-Line '        1. 运行 tools\抓码-开启.ps1（装证书 + 设系统代理，需管理员一次）' 'Gray'
    Write-Line '        2. 重启 QQ，打开「QQ农场」小程序，保持 10 秒' 'Gray'
    Write-Line '        3. 回到主程序「新增账号」→ 抓包登录（码会出现在取码器里）' 'Gray'
    return $true
}

function Invoke-StopP0 {
    Write-Line '================ 停止全部（主程序 + 取码器） ================' 'Cyan'
    Stop-FarmService
    Stop-CaptureService
}

# ---------------------------------------------------------------- 状态
function Get-StatusObject {
    $mainRunning = Test-PortOpen -Port $MainPort
    $cap = Get-CaptureStatus
    return [ordered]@{
        ok        = $true
        host      = 'local'
        generated = (Get-Date).ToString('o')
        ports     = [ordered]@{ panel = $WebPort; main = $MainPort; captureApi = $CapApiPort; captureProxy = $CapProxyPort }
        main      = [ordered]@{ running = $mainRunning; port = $MainPort; url = "http://127.0.0.1:$MainPort" }
        capture   = $cap
        fetcher   = (Get-FetcherState)
        p0        = [ordered]@{ ready = $mainRunning }
    }
}

# ---------------------------------------------------------------- HTTP
function Test-PrivateIp {
    param([string]$Ip)
    if (-not $Ip) { return $false }
    if ($Ip -eq '127.0.0.1' -or $Ip -eq '::1') { return $true }
    $parts = $Ip -split '\.'
    if ($parts.Count -eq 4) {
        $a = [int]$parts[0]; $b = [int]$parts[1]
        if ($a -eq 10) { return $true }
        if ($a -eq 192 -and $b -eq 168) { return $true }
        if ($a -eq 172 -and $b -ge 16 -and $b -le 31) { return $true }
        if ($a -eq 169 -and $b -eq 254) { return $true }
    }
    if ($Ip -match '^(fe80|fc|fd)') { return $true }
    return $false
}

function Read-HttpRequest {
    param($Stream)
    $reader = New-Object System.IO.StreamReader($Stream, [System.Text.Encoding]::UTF8, $false, 4096, $true)
    $requestLine = $reader.ReadLine()
    if (-not $requestLine) { return $null }
    $p = $requestLine -split ' '
    $headers = @{}
    while ($true) {
        $line = $reader.ReadLine()
        if ($null -eq $line -or $line -eq '') { break }
        $idx = $line.IndexOf(':')
        if ($idx -gt 0) { $headers[$line.Substring(0, $idx).Trim().ToLower()] = $line.Substring($idx + 1).Trim() }
    }
    $body = ''
    $len = 0
    if ($headers.ContainsKey('content-length')) { [void][int]::TryParse($headers['content-length'], [ref]$len) }
    if ($len -gt 0) {
        $buf = New-Object char[] $len
        $read = 0
        while ($read -lt $len) {
            $n = $reader.Read($buf, $read, $len - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        if ($read -gt 0) { $body = New-Object string($buf, 0, $read) }
    }
    return @{ Method = $p[0]; Path = $p[1]; Body = $body; Headers = $headers }
}

function Write-HttpText {
    param($Stream, [int]$Status = 200, [string]$ContentType = 'text/plain; charset=utf-8', [string]$Text = '')
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $head = "HTTP/1.1 $Status OK`r`nContent-Type: $ContentType`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`nCache-Control: no-store`r`n`r`n"
    $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
    $Stream.Write($hb, 0, $hb.Length)
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
}

function Send-HttpJson {
    param($Stream, [int]$Status = 200, $Object)
    $json = ($Object | ConvertTo-Json -Depth 10 -Compress)
    Write-HttpText -Stream $Stream -Status $Status -ContentType 'application/json; charset=utf-8' -Text $json
}

# ---------------------------------------------------------------- Web 服务
function Start-WebPanel {
    $indexPath = Join-Path $PanelDir 'web\index.html'
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse($WebBind), $WebPort)
    try { $listener.Start() }
    catch {
        Write-Line "  [Web] 监听 $WebBind`:$WebPort 失败：$($_.Exception.Message)" 'Red'
        return 1
    }
    Write-Line '  =====================================================' 'Cyan'
    Write-Line '   QQ农场助手 · 取码器版 · 控制面板' 'White'
    Write-Line '  =====================================================' 'Cyan'
    Write-Line "   本机    : http://127.0.0.1:$WebPort" 'Gray'
    Write-Line '   安全边界: 只接受同网段私网来源；请勿映射到公网' 'DarkGray'
    Write-Line '   停止    : 页面按钮 / Ctrl+C / 关掉本窗口' 'DarkGray'
    Write-Line '  =====================================================' 'Cyan'
    Write-Line ''

    $selfPath = Join-Path $PanelDir 'panel.ps1'
    $allowed = @('startp0', 'stopp0', 'start', 'stop', 'startcapture', 'stopcapture', 'renewcapture')
    $labels = @{
        startp0      = '启动 P0'
        stopp0       = '停止全部'
        start        = '启动主程序'
        stop         = '停止主程序'
        startcapture = '启动取码器'
        stopcapture  = '停止取码器'
        renewcapture = '续期取码会话'
    }
    $stopRequested = $false

    try {
        while (-not $stopRequested) {
            $client = $null
            try {
                $client = $listener.AcceptTcpClient()
                $client.ReceiveTimeout = 8000
                $client.SendTimeout = 15000
                $stream = $client.GetStream()
                $req = Read-HttpRequest -Stream $stream
                if (-not $req) { continue }

                $remoteIp = ''
                try { $remoteIp = $client.Client.RemoteEndPoint.Address.ToString() } catch { }
                if (-not (Test-PrivateIp -Ip $remoteIp)) {
                    Write-HttpText -Stream $stream -Status 403 -Text "403 仅允许私网访问（来源 $remoteIp）"
                    continue
                }

                switch ($req.Path) {
                    '/' {
                        $page = ''
                        try { $page = [System.IO.File]::ReadAllText($indexPath, [System.Text.Encoding]::UTF8) } catch { }
                        if ($page) { Write-HttpText -Stream $stream -ContentType 'text/html; charset=utf-8' -Text $page }
                        else { Write-HttpText -Stream $stream -Status 500 -Text 'index.html 缺失' }
                    }
                    '/api/status' {
                        Send-HttpJson -Stream $stream -Object (Get-StatusObject)
                    }
                    '/api/capture-log' {
                        $lines = Read-TailLines -Path $CapLog -Lines 200
                        Send-HttpJson -Stream $stream -Object ([ordered]@{ ok = $true; file = $CapLog; lines = @($lines) })
                    }
                    '/api/code/state' {
                        Send-HttpJson -Stream $stream -Object ([ordered]@{ ok = $true; fetcher = (Get-FetcherState) })
                    }
                    '/api/code/start' {
                        if ($req.Method -ne 'POST') { Write-HttpText -Stream $stream -Status 405 -Text 'method not allowed'; break }
                        $b = @{}
                        try { $b = ConvertFrom-Json -InputObject $req.Body } catch { }
                        $mode = if ($b -and $b.mode) { [string]$b.mode } else { 'new' }
                        $accId = if ($b -and $b.accountId) { [string]$b.accountId } else { '' }
                        $ok = Start-Fetcher -Mode $mode -AccountId $accId
                        Send-HttpJson -Stream $stream -Status $(if ($ok) { 202 } else { 409 }) -Object ([ordered]@{ ok = $ok })
                    }
                    '/api/code/cancel' {
                        if ($req.Method -ne 'POST') { Write-HttpText -Stream $stream -Status 405 -Text 'method not allowed'; break }
                        Stop-Fetcher
                        Send-HttpJson -Stream $stream -Status 202 -Object ([ordered]@{ ok = $true })
                    }
                    '/api/code/apply' {
                        if ($req.Method -ne 'POST') { Write-HttpText -Stream $stream -Status 405 -Text 'method not allowed'; break }
                        $b = @{}
                        try { $b = ConvertFrom-Json -InputObject $req.Body } catch { }
                        $mode = if ($b -and $b.mode) { [string]$b.mode } else { 'new' }
                        $accId = if ($b -and $b.accountId) { [string]$b.accountId } else { '' }
                        $ok = Invoke-ApplyCode -Mode $mode -AccountId $accId
                        Send-HttpJson -Stream $stream -Status $(if ($ok) { 200 } else { 400 }) -Object ([ordered]@{ ok = $ok })
                    }
                    '/api/action' {
                        if ($req.Method -ne 'POST') { Write-HttpText -Stream $stream -Status 405 -Text 'method not allowed'; break }
                        $act = ''
                        try { $obj = ConvertFrom-Json -InputObject $req.Body; if ($obj -and $obj.action) { $act = [string]$obj.action } } catch { }
                        if ($act -eq 'panel-stop') {
                            Send-HttpJson -Stream $stream -Status 202 -Object ([ordered]@{ ok = $true; action = 'panel-stop' })
                            Start-Sleep -Milliseconds 300
                            $stopRequested = $true
                            break
                        }
                        if ($allowed -notcontains $act) {
                            Send-HttpJson -Stream $stream -Status 400 -Object ([ordered]@{ ok = $false; error = "不支持的动作：$act" })
                            break
                        }
                        Write-Line ("[Web] {0} 请求 {1}（来自 {2}）" -f $labels[$act], $act, $remoteIp) 'DarkGray'
                        Start-Process -FilePath 'powershell.exe' `
                            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $selfPath, '-Action', $act, '-NoPause') `
                            -WorkingDirectory $Root -WindowStyle Hidden | Out-Null
                        Send-HttpJson -Stream $stream -Status 202 -Object ([ordered]@{ ok = $true; action = $act; label = $labels[$act] })
                    }
                    default {
                        Write-HttpText -Stream $stream -Status 404 -Text '404'
                    }
                }
            }
            catch {
                Write-Line ("[Web] 请求异常：{0}" -f $_.Exception.Message) 'DarkGray'
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

# ---------------------------------------------------------------- 入口
switch ($Action) {
    'web' {
        Write-Line ("  面板启动：{0}  根目录：{1}" -f (Get-Date).ToString('HH:mm:ss'), $Root) 'DarkGray'
        exit (Start-WebPanel)
    }
    'startp0' {
        [void](Invoke-StartP0)
        if (-not $NoPause) { Write-Host ''; Read-Host '  按回车关闭' | Out-Null }
    }
    'stopp0' {
        Invoke-StopP0
        if (-not $NoPause) { Write-Host ''; Read-Host '  按回车关闭' | Out-Null }
    }
    'startcapture' {
        Write-Line '================ 启动取码器 ================' 'Cyan'
        [void](Start-CaptureService)
        if (-not $NoPause) { Write-Host ''; Read-Host '  按回车关闭' | Out-Null }
    }
    'stopcapture' {
        Write-Line '================ 停止取码器 ================' 'Cyan'
        Stop-CaptureService
        if (-not $NoPause) { Write-Host ''; Read-Host '  按回车关闭' | Out-Null }
    }
    'renewcapture' {
        Write-Line '================ 续期取码会话 ================' 'Cyan'
        Invoke-CapApi -Method 'POST' -Path '/api/capture/stop' -Body @{ sessionId = $CapSessionId } | Out-Null
        Invoke-CapApi -Method 'DELETE' -Path "/api/sessions/$CapSessionId" | Out-Null
        Start-Sleep -Milliseconds 500
        [void](Start-CaptureService)
        if (-not $NoPause) { Write-Host ''; Read-Host '  按回车关闭' | Out-Null }
    }
    'start' {
        Write-Line '================ 启动主程序 ================' 'Cyan'
        [void](Start-FarmService)
        if (-not $NoPause) { Write-Host ''; Read-Host '  按回车关闭' | Out-Null }
    }
    'stop' {
        Write-Line '================ 停止主程序 ================' 'Cyan'
        Stop-FarmService
        if (-not $NoPause) { Write-Host ''; Read-Host '  按回车关闭' | Out-Null }
    }
    'status' {
        $s = Get-StatusObject
        Write-Line ("主程序 : {0}" -f $(if ($s.main.running) { "运行中 :$MainPort" } else { '已停止' })) $(if ($s.main.running) { 'Green' } else { 'DarkGray' })
        Write-Line ("取码器 : {0}" -f $(if ($s.capture.running) { "运行中 API:$CapApiPort 代理:$CapProxyPort 码数:$($s.capture.codeCount)" } else { '已停止' })) $(if ($s.capture.running) { 'Green' } else { 'DarkGray' })
        if (-not $NoPause) { Write-Host ''; Read-Host '  按回车关闭' | Out-Null }
    }
}
