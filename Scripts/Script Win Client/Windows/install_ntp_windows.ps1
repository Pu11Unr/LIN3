# =============================================================================
# install_ntp_windows.ps1 - LIN3 Windows NTP failover (PowerShell 5.1)
# Configures Windows as NTP client + secondary NTP server.
# Sources: internal Linux primary (0x8), external backup servers / pool (0xA).
# Does NOT change the Windows hostname or network IP settings.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File .\install_ntp_windows.ps1
# =============================================================================
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$Base = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time'
$RuleName = 'LIN3-NTP-Server'

function Is-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Say([string]$m) { Write-Host "`n== $m ==" -ForegroundColor Cyan }
function OK([string]$m) { Write-Host "[OK] $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Warning $m }
function Read-Config {
    $path = Join-Path $PSScriptRoot '.env.windows.txt'
    if (-not (Test-Path -LiteralPath $path)) { throw 'Missing .env.windows.txt; copy env.windows.template first.' }
    $cfg = @{}
    foreach ($line in Get-Content -LiteralPath $path) {
        $s = $line.Trim()
        if (-not $s -or $s.StartsWith('#')) { continue }
        if ($s -notmatch '^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') { throw "Invalid config line: $line" }
        $name = $matches[1]; $value = $matches[2]
        if ($cfg.ContainsKey($name)) { throw "Duplicate config key: $name" }
        if ($value -match '^(["''])(.*)\1$') { $value = $matches[2] }
        else { $value = ($value -replace '\s+#.*$','').Trim() }
        $cfg[$name] = $value
    }
    foreach ($key in @('TZ_NAME','NTP_PRIMARY_SERVER','NTP_POOL','NTP_ALLOWED_SUBNET')) {
        if (-not $cfg[$key]) { throw "Missing config key: $key" }
    }
    $cfg['BACKUP_HOSTS'] = @()
    $rawServers = [string]$cfg['NTP_SERVERS']
    if ($rawServers.Trim()) { $cfg['BACKUP_HOSTS'] = @($rawServers -split '\s+' | Where-Object { $_ }) }
    $cfg['BACKUP_HOSTS'] = @($cfg['BACKUP_HOSTS']) + @([string]$cfg['NTP_POOL'])
    $cfg['BACKUP_HOSTS'] = @($cfg['BACKUP_HOSTS'] | Select-Object -Unique)
    if ($cfg['BACKUP_HOSTS'].Count -eq 0) { throw 'At least one external NTP fallback is required.' }
    foreach ($hostName in @($cfg.NTP_PRIMARY_SERVER) + @($cfg.BACKUP_HOSTS)) {
        if ($hostName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.\-]*$') { throw "Invalid NTP hostname/IP: $hostName" }
        if ($hostName -eq $cfg.NTP_PRIMARY_SERVER -and @($cfg.BACKUP_HOSTS) -contains $hostName) { throw 'Primary is also listed as fallback.' }
    }
    if ($cfg.NTP_ALLOWED_SUBNET -ne 'LocalSubnet' -and $cfg.NTP_ALLOWED_SUBNET -notmatch '^(\d{1,3}\.){3}\d{1,3}/([1-9]|[12]\d|3[012])$') {
        throw 'NTP_ALLOWED_SUBNET must be LocalSubnet or an IPv4 CIDR.'
    }
    if (-not @(Get-TimeZone -ListAvailable | Where-Object { $_.Id -eq $cfg.TZ_NAME }).Count) {
        throw "Invalid Windows time zone ID: $($cfg.TZ_NAME)"
    }
    $defaults = @{ NTP_MIN_POLL_INTERVAL=6; NTP_MAX_POLL_INTERVAL=6; NTP_UPDATE_INTERVAL=100; NTP_ANNOUNCE_FLAGS=10; NTP_EVENT_LOG_FLAGS=3; NTP_DISABLE_VMIC=1; NTP_MAX_ROOT_DISTANCE=5; NTP_INSTALL_WAIT_SECONDS=300 }
    foreach ($key in $defaults.Keys) {
        if (-not $cfg.ContainsKey($key)) { $cfg[$key] = $defaults[$key] }
        $n = 0
        if (-not [int]::TryParse([string]$cfg[$key],[ref]$n)) { throw "Invalid integer for $key" }
        $cfg[$key] = $n
    }
    if ($cfg.NTP_MIN_POLL_INTERVAL -lt 6 -or $cfg.NTP_MAX_POLL_INTERVAL -gt 15 -or $cfg.NTP_MIN_POLL_INTERVAL -gt $cfg.NTP_MAX_POLL_INTERVAL) { throw 'Invalid poll intervals (6..15).' }
    if ($cfg.NTP_UPDATE_INTERVAL -lt 1 -or $cfg.NTP_INSTALL_WAIT_SECONDS -lt 0 -or $cfg.NTP_INSTALL_WAIT_SECONDS -gt 3600) { throw 'Invalid update/wait interval.' }
    if ($cfg.NTP_DISABLE_VMIC -notin @(0,1) -or $cfg.NTP_MAX_ROOT_DISTANCE -lt 1 -or $cfg.NTP_MAX_ROOT_DISTANCE -gt 5) { throw 'Invalid VMIC or max-distance setting.' }
    return $cfg
}
function Invoke-W32([string[]]$ArgsList) {
    & w32tm.exe @ArgsList | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "w32tm $($ArgsList -join ' ') failed (code $LASTEXITCODE)." }
}
function Check-W32Policy {
    $path = 'HKLM:\SOFTWARE\Policies\Microsoft\W32Time'
    if (Test-Path $path) {
        $entries = @((Get-Item $path)) + @(Get-ChildItem $path -Recurse)
        if (@($entries | Where-Object { $_.ValueCount -gt 0 }).Count -gt 0) {
            throw 'A W32Time group policy is active. Local configuration might be overridden.'
        }
    }
}

$exitCode = 1; $transcript = $false
try {
    if (-not (Is-Administrator)) { throw 'Open Windows PowerShell as Administrator.' }
    $C = Read-Config
    Check-W32Policy
    $logDir = Join-Path $PSScriptRoot 'logs'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Start-Transcript -Path (Join-Path $logDir "install-$stamp.log") | Out-Null
    $transcript = $true

    Say '1. Backup current Windows Time configuration'
    $regFile = Join-Path $logDir "W32Time-$stamp.reg"
    & reg.exe export 'HKLM\SYSTEM\CurrentControlSet\Services\W32Time' $regFile /y | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'W32Time registry backup failed.' }
    (Get-TimeZone).Id | Set-Content -LiteralPath (Join-Path $logDir "timezone-$stamp.txt")
    OK 'Registry backup and original time zone saved'

    Say '2. Time zone and W32Time service'
    if ((Get-TimeZone).Id -ne $C.TZ_NAME) { Set-TimeZone -Id $C.TZ_NAME }
    Set-Service -Name W32Time -StartupType Automatic
    foreach ($provider in @('NtpClient','NtpServer')) {
        New-ItemProperty -Path "$Base\TimeProviders\$provider" -Name Enabled -Value 1 -PropertyType DWord -Force | Out-Null
    }
    New-ItemProperty -Path "$Base\TimeProviders\NtpClient" -Name InputProvider -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path "$Base\TimeProviders\NtpClient" -Name EventLogFlags -Value $C.NTP_EVENT_LOG_FLAGS -PropertyType DWord -Force | Out-Null
    if ($C.NTP_DISABLE_VMIC -eq 1 -and (Test-Path "$Base\TimeProviders\VMICTimeProvider")) {
        New-ItemProperty -Path "$Base\TimeProviders\VMICTimeProvider" -Name Enabled -Value 0 -PropertyType DWord -Force | Out-Null
    }
    if ((Get-Service W32Time).Status -ne 'Running') { Start-Service -Name W32Time }
    OK "Time zone: $($C.TZ_NAME); W32Time automatic, NTP client and server enabled"

    Say '3. NTP sources, failover and clock tuning'
    $peers = @("$($C.NTP_PRIMARY_SERVER),0x8")
    foreach ($s in $C.BACKUP_HOSTS) { $peers += "$s,0xA" }
    $peerString = $peers -join ' '
    Invoke-W32 -ArgsList @('/config',"/manualpeerlist:$peerString",'/syncfromflags:manual','/update')
    $settings = @{MinPollInterval=$C.NTP_MIN_POLL_INTERVAL; MaxPollInterval=$C.NTP_MAX_POLL_INTERVAL; UpdateInterval=$C.NTP_UPDATE_INTERVAL; AnnounceFlags=$C.NTP_ANNOUNCE_FLAGS}
    foreach ($key in $settings.Keys) {
        New-ItemProperty -Path "$Base\Config" -Name $key -Value $settings[$key] -PropertyType DWord -Force | Out-Null
    }
    # LocalClockDispersion is deliberately unchanged: never disguise uncertainty.
    OK "Primary: $($C.NTP_PRIMARY_SERVER); backups: $($C.BACKUP_HOSTS -join ', ')"

    Say '4. Windows firewall inbound UDP/123'
    # Recreate ONLY our named rule; avoids unsupported Set-NetFirewallRule port parameters.
    $oldRules = @(Get-NetFirewallRule -PolicyStore PersistentStore -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $RuleName -or $_.DisplayName -eq 'LIN3 - NTP Server' })
    foreach ($rule in $oldRules) { Remove-NetFirewallRule -Name $rule.Name -PolicyStore PersistentStore }
    New-NetFirewallRule -Name $RuleName -DisplayName 'LIN3 - NTP Server' -PolicyStore PersistentStore -Direction Inbound -Action Allow -Enabled True -Profile Any -Protocol UDP -LocalPort 123 -RemoteAddress $C.NTP_ALLOWED_SUBNET | Out-Null
    OK "Inbound UDP/123 restricted to $($C.NTP_ALLOWED_SUBNET)"

    Say '5. Apply configuration'
    Invoke-W32 -ArgsList @('/config','/update')
    Restart-Service W32Time
    $channel = 'Microsoft-Windows-Time-Service/Operational'
    if ($null -ne (Get-WinEvent -ListLog $channel -ErrorAction SilentlyContinue)) {
        & wevtutil.exe sl $channel /e:true | Out-Null
    }
    $resync = & w32tm.exe /resync /rediscover 2>&1
    $resyncCode = $LASTEXITCODE
    $resync | ForEach-Object { Write-Host $_ }
    if ($resyncCode -ne 0 -or ($resync -join ' ') -match '(?i)no time data|did not resync|aucune donn.e') {
        Warn 'Immediate synchronization was not confirmed. Validation will determine success.'
    }

    Say '6. Automated validation (configuration + real NTP UDP replies)'
    $validator = Join-Path $PSScriptRoot 'validate_ntp_windows.ps1'
    if (-not (Test-Path -LiteralPath $validator)) { throw 'Missing validate_ntp_windows.ps1' }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $validator -Mode Normal -WaitSeconds $C.NTP_INSTALL_WAIT_SECONDS
    if ($LASTEXITCODE -ne 0) {
        Warn 'Settings applied but NTP has NOT been validated; see logs. Check Linux NTP service and AWS UDP 123 rules.'
        $exitCode = 2
    } else {
        OK 'Windows NTP deployment validated'
        $exitCode = 0
    }
} catch {
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    $exitCode = 1
} finally {
    if ($transcript) { Stop-Transcript | Out-Null }
}
exit $exitCode
