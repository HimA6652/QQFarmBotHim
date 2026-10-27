<#
============================================================================
 QQ农场助手 · SnowLuma 版 · 主程序启动器
============================================================================
 端口   3007（与上游默认一致）
 数据   <本目录>\data
 自包含：Node 运行时在 .\runtime\node
 QQ 宿主：SnowLuma（.\snowluma，WebUI 5099）—— 由控制面板统一启停

 说明
   主程序不依赖 OneBot：它用 Code 直连农场网关。
   SnowLuma 只负责保持 QQ 登录态，Code 由「抓包登录」或「手动填码」进入主程序。
============================================================================
#>
[CmdletBinding()]
param(
    [switch]$Hidden
)

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$nodeDir = Join-Path $root 'runtime\node'

if (-not (Test-Path -LiteralPath (Join-Path $nodeDir 'node.exe'))) {
    # 允许回退到系统 node（开发环境）
    $sysNode = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($sysNode) { $nodeDir = Split-Path -Parent $sysNode.Source }
    else {
        Write-Host "  [错误] 找不到 Node 运行时：$nodeDir" -ForegroundColor Red
        exit 1
    }
}

try {
    $nodeVer = [string](& (Join-Path $nodeDir 'node.exe') -v 2>$null)
    if ($nodeVer -match '^v(\d+)\.') {
        $nodeMajor = [int]$Matches[1]
        if ($nodeMajor -lt 20) {
            Write-Host "  [错误] Node 版本过低：$nodeVer（需要 >= 20）" -ForegroundColor Red
            exit 1
        }
        if (-not $Hidden) { Write-Host "   Node 运行时 : $nodeVer" -ForegroundColor DarkGray }
    }
}
catch {
    Write-Host "  [注意] 读取 Node 版本失败，继续启动：$($_.Exception.Message)" -ForegroundColor Yellow
}

if (-not $Hidden) {
    Write-Host ''
    Write-Host '  ============================================================' -ForegroundColor Cyan
    Write-Host '   QQ农场助手 · SnowLuma 版' -ForegroundColor White
    Write-Host '  ============================================================' -ForegroundColor Cyan
    Write-Host '   主程序后台 : http://127.0.0.1:3007'
    Write-Host ("   数据目录   : " + (Join-Path $root 'data'))
    Write-Host '   QQ 宿主     : SnowLuma  http://127.0.0.1:5099'
    Write-Host '   取码方式   : 抓包登录 / 手动填码'
    Write-Host ''
}

# ---- 运行时环境 ----
$env:ADMIN_PORT = '3007'
$env:FARM_DATA_DIR = Join-Path $root 'data'
$env:PATH = "$nodeDir;$env:PATH"

Set-Location -LiteralPath $root
$nodeExe = Join-Path $nodeDir 'node.exe'
$client = Join-Path $root 'core\client.js'

if ($Hidden) {
    # 供控制面板调用：后台无窗口启动，真实 node PID 由这里写入 farm.pid
    $panelRun = Join-Path $root 'panel\run'
    if (-not (Test-Path -LiteralPath $panelRun)) { New-Item -ItemType Directory -Force -Path $panelRun | Out-Null }
    $nodeProc = Start-Process -FilePath $nodeExe -ArgumentList $client -WorkingDirectory $root -WindowStyle Hidden -PassThru
    $ticks = 0
    try { $ticks = $nodeProc.StartTime.Ticks } catch { $ticks = 0 }
    try { Set-Content -LiteralPath (Join-Path $panelRun 'farm.pid') -Value "$($nodeProc.Id)|$ticks" -Encoding ascii }
    catch { Write-Host "  [注意] 写 farm.pid 失败：$($_.Exception.Message)" -ForegroundColor Yellow }
    Write-Host '  已在后台启动： http://127.0.0.1:3007' -ForegroundColor Green
}
else {
    & $nodeExe $client
}
