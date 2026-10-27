<#
  本机抓码 · 开启
  ---------------------------------------------------------------
  作用：
    1) 把 MITM 根证书装进「受信任的根证书颁发机构」（本机，需管理员）
    2) 把系统代理指向 127.0.0.1:18000（当前用户）
    3) 提示你打开 QQ 农场

  前置：抓码服务已在运行（面板「取码器」或 面板一键启动 P0 会拉起）
  关闭：运行 抓码-关闭.ps1（会清掉系统代理；证书可留着，不影响）
#>
[CmdletBinding()]
param(
    [string]$Proxy = '127.0.0.1:18000',
    [string]$CertPath = (Join-Path $PSScriptRoot 'mitm-ca.cer')
)

$ErrorActionPreference = 'Stop'

# ---- 1) 证书 ----
if (-not (Test-Path -LiteralPath $CertPath)) {
    Write-Host "  [错误] 找不到证书：$CertPath" -ForegroundColor Red
    Write-Host "         请先在面板里启动「取码器」，或从 http://127.0.0.1:8450/cert/mitmproxy-ca-cert.cer 下载。" -ForegroundColor Yellow
    exit 1
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host '  需要管理员权限安装证书，正在请求提权…' -ForegroundColor Yellow
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Proxy', $Proxy, '-CertPath', $CertPath)
    Start-Process -FilePath 'powershell.exe' -ArgumentList $args -Verb RunAs
    exit 0
}

try {
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CertPath)
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root', 'LocalMachine')
    $store.Open('ReadWrite')
    $store.Add($cert)
    $store.Close()
    Write-Host ("  [1/2] 证书已装入「受信任的根证书颁发机构」：{0}" -f $cert.Subject) -ForegroundColor Green
}
catch {
    Write-Host ("  [1/2] 证书安装失败：{0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host '        可能已安装过，可忽略后继续。' -ForegroundColor DarkGray
}

# ---- 2) 系统代理 ----
try {
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    Set-ItemProperty -LiteralPath $k -Name ProxyEnable -Value 1
    Set-ItemProperty -LiteralPath $k -Name ProxyServer -Value $Proxy
    Set-ItemProperty -LiteralPath $k -Name ProxyOverride -Value '<local>'
    # 通知 WinINET 刷新（不重启也能生效）
    $sig = @'
[DllImport("wininet.dll", SetLastError = true)]
public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
'@
    $t = Add-Type -MemberDefinition $sig -Name WinInet -Namespace Native -PassThru
    [void]$t::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)  # SETTINGS_CHANGED
    [void]$t::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)  # REFRESH
    Write-Host ("  [2/2] 系统代理已设为 {0}" -f $Proxy) -ForegroundColor Green
}
catch {
    Write-Host ("  [2/2] 设置系统代理失败：{0}" -f $_.Exception.Message) -ForegroundColor Red
}

Write-Host ''
Write-Host '  接下来：' -ForegroundColor Cyan
Write-Host '    1. 完全退出 QQ（托盘 → 退出），再重新打开（QQ 在启动时读取代理）' -ForegroundColor Gray
Write-Host '    2. 在 QQ 里打开「QQ农场」小程序，保持 10 秒' -ForegroundColor Gray
Write-Host '    3. 看面板「取码器」里的码池，或等本脚本所在目录出现 code 记录' -ForegroundColor Gray
Write-Host ''
Write-Host '  验收结束后请运行：抓码-关闭.ps1（清掉系统代理）' -ForegroundColor DarkGray
Write-Host ''
if (-not $NoPause) { Read-Host '  按回车关闭' | Out-Null }
