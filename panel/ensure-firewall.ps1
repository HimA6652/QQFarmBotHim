# =============================================================================
#  ensure-firewall.ps1 - keep inbound exposure to exactly 3100 + 3007
#
#  Called by panel\server.js on startup (the panel already runs elevated because
#  启动控制面板.bat asks for UAC), so no scheduled task and no manual step.
#
#  Rules created:
#    QQFarmBot Panel 3100   TCP 3100  LocalSubnet  this build's node.exe
#    QQFarmBot Web 3007     TCP 3007  LocalSubnet  this build's node.exe
#
#  Rules removed:
#    any "Node.js JavaScript Runtime" allow rule whose Program points at an old
#    QQFarmBot copy - those allow every port node.exe binds, not just two.
#
#  Profile=Any is intentional: this machine's Wi-Fi is classified as "Public",
#  a Private-only rule would block LAN access. The boundary is RemoteAddress.
#
#  Exit codes: 0 = ok / nothing to do, 2 = not elevated, 1 = partial failure
# =============================================================================
[CmdletBinding()]
param(
    [string]$DeployRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$LogPath = (Join-Path $PSScriptRoot 'logs\firewall.log')
)

$ErrorActionPreference = 'Continue'
$changed = 0
$failed = 0
$messages = New-Object System.Collections.Generic.List[string]

function Note([string]$text) {
    $messages.Add(("[" + (Get-Date -Format 'HH:mm:ss') + "] " + $text))
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Note 'skip: not elevated'
    $messages | ForEach-Object { Write-Host $_ }
    exit 2
}

$nodeExe = Join-Path $DeployRoot 'runtime\node\node.exe'
$wanted = @(
    @{ Name = 'QQFarmBot Panel 3100'; Port = 3100 },
    @{ Name = 'QQFarmBot Web 3007'; Port = 3007 }
)

# -- 1. remove over-broad program rules left by earlier installs -------------
foreach ($rule in @(Get-NetFirewallRule -ErrorAction SilentlyContinue)) {
    if ($rule.DisplayName -like 'QQFarmBot*') { continue }
    $app = $rule | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue
    if ($null -eq $app -or -not $app.Program) { continue }
    if ($app.Program -like '*qqfarmbot*') {
        Remove-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue
        if ($?) {
            $changed++
            Note ("removed broad program rule: " + $app.Program)
        }
        else {
            $failed++
            Note ("failed to remove: " + $app.Program)
        }
    }
}

# -- 2. ensure exactly two port-scoped rules --------------------------------
foreach ($spec in $wanted) {
    $existing = @(Get-NetFirewallRule -DisplayName $spec.Name -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 0) {
        $portFilter = $existing[0] | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
        $addrFilter = $existing[0] | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue
        $ok = ($existing[0].Action -eq 'Allow') -and ($existing[0].Enabled -eq 'True')
        $ok = $ok -and ("" + $portFilter.LocalPort -eq "" + $spec.Port)
        $ok = $ok -and ("" + $addrFilter.RemoteAddress -eq 'LocalSubnet')
        if ($ok) { continue }
        Remove-NetFirewallRule -DisplayName $spec.Name -ErrorAction SilentlyContinue
    }

    $params = @{
        DisplayName   = $spec.Name
        Description   = 'QQFarmBot: LAN only, single port, this build only'
        Direction     = 'Inbound'
        Action        = 'Allow'
        Protocol      = 'TCP'
        LocalPort     = $spec.Port
        RemoteAddress = 'LocalSubnet'
        Profile       = 'Any'
        Enabled       = 'True'
    }
    if (Test-Path -LiteralPath $nodeExe) { $params.Program = $nodeExe }
    try {
        New-NetFirewallRule @params | Out-Null
        $changed++
        Note ("added: " + $spec.Name + " (TCP " + $spec.Port + ", LocalSubnet)")
    }
    catch {
        $failed++
        Note ("failed: " + $spec.Name + " -> " + $_.Exception.Message)
    }
}

if ($changed -eq 0 -and $failed -eq 0) { Note 'firewall already up to date' }

try {
    $dir = Split-Path -Parent $LogPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllLines($LogPath, $messages, (New-Object System.Text.UTF8Encoding($false)))
}
catch {}

$messages | ForEach-Object { Write-Host $_ }
if ($failed -gt 0) { exit 1 }
exit 0
