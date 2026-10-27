<#
  本机抓码 · 关闭
  ---------------------------------------------------------------
  作用：清掉系统代理（恢复直连）。证书保留在「受信任的根证书颁发机构」中不影响使用，
        如需彻底移除：certlm.msc → 受信任的根证书颁发机构 → 证书 → 删除 QQFarmBot MITM CA
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

$k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
try {
    Set-ItemProperty -LiteralPath $k -Name ProxyEnable -Value 0
    $sig = @'
[DllImport("wininet.dll", SetLastError = true)]
public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
'@
    $t = Add-Type -MemberDefinition $sig -Name WinInet2 -Namespace Native2 -PassThru
    [void]$t::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
    [void]$t::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)
    Write-Host '  系统代理已关闭（恢复直连）' -ForegroundColor Green
}
catch {
    Write-Host ("  关闭系统代理失败：{0}" -f $_.Exception.Message) -ForegroundColor Red
}

Write-Host '  提示：QQ 需要重启才会重新走直连。' -ForegroundColor DarkGray
Write-Host ''
if (-not $NoPause) { Read-Host '  按回车关闭' | Out-Null }
