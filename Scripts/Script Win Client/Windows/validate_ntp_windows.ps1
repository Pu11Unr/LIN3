# LIN3 - Validation NTP Windows V4 / PowerShell 5.1
# Normal : source principale ; Failover : secours pendant panne ; Recovery : retour.
# Any : l'une des sources configurees. Aucun redemarrage ni resync force.
[CmdletBinding()]
param([ValidateSet('Normal','Failover','Recovery','Any')][string]$Mode = 'Normal',
      [ValidateRange(0,7200)][int]$WaitSeconds = 0)
$ErrorActionPreference = 'Stop'
$Base = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time'
$RuleName = 'LIN3-NTP-Server'
$DisplayName = 'LIN3 - NTP Server'
function Assert-Administrator {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Ouvrir PowerShell en administrateur.' }
}
function Read-NtpConfig {
    $path = Join-Path $PSScriptRoot '.env.windows.txt'
    if (-not (Test-Path -LiteralPath $path)) { throw 'Copier env.windows.template vers .env.windows.txt.' }
    $c = @{}
    foreach ($line in Get-Content -LiteralPath $path) {
        if ($line -match '^\s*(#|$)') { continue }
        $parts = $line -split '=',2
        if ($parts.Count -ne 2) { throw "Ligne invalide : $line" }
        $key = $parts[0].Trim()
        if ($c.ContainsKey($key)) { throw "Variable en double : $key" }
        $value = ($parts[1] -replace '\s+#.*$','').Trim()
        if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))) { $value = $value.Substring(1,$value.Length-2) }
        $c[$key] = $value
    }
    foreach ($key in @('TZ_NAME','NTP_PRIMARY_SERVER','NTP_POOL','NTP_ALLOWED_SUBNET')) {
        if (-not $c[$key]) { throw "Variable manquante : $key" }
    }
    foreach ($key in @('NTP_PRIMARY_SERVER','NTP_POOL')) {
        if ($c[$key] -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]*$') { throw "Adresse IPv4 ou nom DNS invalide : $key" }
    }
    $backupHosts = @()
    if ($c.ContainsKey('NTP_SERVERS') -and $c.NTP_SERVERS.Trim()) {
        $backupHosts = @($c.NTP_SERVERS.Trim() -split '\s+' | Where-Object { $_ })
    }
    $backupHosts = @($backupHosts + @($c.NTP_POOL) | Select-Object -Unique)
    foreach ($hostName in $backupHosts) {
        if ($hostName -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]*$') { throw "Adresse de secours invalide : $hostName" }
        if ($hostName -eq $c.NTP_PRIMARY_SERVER) { throw 'Source principale incluse dans les secours.' }
    }
    $c['BACKUP_HOSTS'] = $backupHosts
    if ($c.NTP_ALLOWED_SUBNET -ne 'LocalSubnet') {
        $p = $c.NTP_ALLOWED_SUBNET -split '/'
        $a = $null; $prefix = 0
        if ($p.Count -ne 2 -or -not [Net.IPAddress]::TryParse($p[0],[ref]$a) -or $a.AddressFamily -ne 'InterNetwork' -or -not [int]::TryParse($p[1],[ref]$prefix) -or $prefix -lt 1 -or $prefix -gt 32) { throw 'Plage attendue : LocalSubnet ou CIDR IPv4 restreint.' }
    }
    $zone = @(Get-TimeZone -ListAvailable | Where-Object Id -eq $c.TZ_NAME)
    if ($zone.Count -ne 1) { throw "Fuseau Windows invalide : $($c.TZ_NAME)" }
    # Site LIN3: enforce the two peers and the permitted remote subnet.
    if ($c.TZ_NAME -ne 'W. Europe Standard Time' -or $c.NTP_PRIMARY_SERVER -ne '10.0.2.10' -or $c.NTP_POOL -ne 'ie.pool.ntp.org' -or @($c.BACKUP_HOSTS).Count -ne 1 -or $c.NTP_ALLOWED_SUBNET -ne '10.0.2.0/28') {
        throw 'Invalid site settings: use the corrected .env.windows.txt (Swiss TZ, two peers, 10.0.2.0/28 only).'
    }
    $defaults = @{NTP_MIN_POLL_INTERVAL=6; NTP_MAX_POLL_INTERVAL=6; NTP_UPDATE_INTERVAL=100; NTP_ANNOUNCE_FLAGS=10; NTP_EVENT_LOG_FLAGS=3; NTP_DISABLE_VMIC=1; NTP_MAX_ROOT_DISTANCE=5; NTP_INSTALL_WAIT_SECONDS=120}
    foreach ($key in $defaults.Keys) {
        if (-not $c.ContainsKey($key)) { $c[$key] = $defaults[$key] }
        $n = 0
        if (-not [int]::TryParse([string]$c[$key],[ref]$n)) { throw "Valeur invalide : $key" }
        $c[$key] = $n
    }
    if ($c.NTP_MIN_POLL_INTERVAL -lt 6 -or $c.NTP_MAX_POLL_INTERVAL -gt 15 -or $c.NTP_MIN_POLL_INTERVAL -gt $c.NTP_MAX_POLL_INTERVAL -or $c.NTP_UPDATE_INTERVAL -lt 1 -or $c.NTP_ANNOUNCE_FLAGS -ne 10 -or $c.NTP_EVENT_LOG_FLAGS -ne 3 -or $c.NTP_DISABLE_VMIC -notin @(0,1) -or $c.NTP_MAX_ROOT_DISTANCE -lt 1 -or $c.NTP_MAX_ROOT_DISTANCE -gt 5 -or $c.NTP_INSTALL_WAIT_SECONDS -lt 0 -or $c.NTP_INSTALL_WAIT_SECONDS -gt 3600) { throw 'Parametres NTP hors limites.' }
    if ($c.NTP_DISABLE_VMIC -ne 1) { throw 'VMIC must remain disabled for this deployment.' }
    return $c
}
function Invoke-W32Time([string[]]$Arguments) {
    $out = & w32tm.exe @Arguments 2>&1
    $code = $LASTEXITCODE
    $out | ForEach-Object { Write-Host $_ }
    if ($code -ne 0) { throw "w32tm : code $code" }
}
function Start-NtpLog([string]$Name) {
    $dir = Join-Path $PSScriptRoot 'logs'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Start-Transcript -Path (Join-Path $dir ("{0}-{1}.log" -f $Name,(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))) | Out-Null
}
$script:Errors = 0
function Test-Result([bool]$Passed,[string]$Message) {
    if ($Passed) { Write-Host "[OK] $Message" -ForegroundColor Green }
    else { Write-Host "[ECHEC] $Message" -ForegroundColor Red; $script:Errors++ }
}
function Get-IPv4([string]$Name) {
    try { [Net.Dns]::GetHostAddresses($Name) | Where-Object AddressFamily -eq 'InterNetwork' | Select-Object -First 4 }
    catch { Write-Warning "Resolution DNS impossible : $Name" }
}
function Read-U32([byte[]]$Bytes,[int]$Index) {
    return ([double]$Bytes[$Index]*16777216 + [double]$Bytes[($Index+1)]*65536 + [double]$Bytes[($Index+2)]*256 + [double]$Bytes[($Index+3)])
}
# Sonde NTP UDP reelle : verifie mode, originate timestamp, leap, stratum et distance.
# La socket utilise un port source ephemere ; elle ne change pas l'heure Windows.
function Get-NtpProbe([string]$Name) {
    $result = $null
    $last = 'Aucune adresse IPv4 ou reponse UDP.'
    foreach ($ip in @(Get-IPv4 $Name)) {
        $udp = $null
        try {
            $udp = New-Object Net.Sockets.UdpClient
            $udp.Client.ReceiveTimeout = 2500
            $udp.Connect($ip,123)
            $packet = New-Object byte[] 48
            $packet[0] = 0x23 # NTPv4, mode client
            $epoch = [datetime]::SpecifyKind([datetime]'1900-01-01',[DateTimeKind]::Utc)
            $now = ([datetime]::UtcNow - $epoch).TotalSeconds
            $sec = [uint32]([math]::Floor($now) % 4294967296)
            $frac = [uint32][math]::Floor(($now - [math]::Floor($now))*4294967296)
            $a = [BitConverter]::GetBytes($sec); [array]::Reverse($a); [array]::Copy($a,0,$packet,40,4)
            $a = [BitConverter]::GetBytes($frac); [array]::Reverse($a); [array]::Copy($a,0,$packet,44,4)
            [void]$udp.Send($packet,$packet.Length)
            $remote = New-Object Net.IPEndPoint([Net.IPAddress]::Any,0)
            $reply = $udp.Receive([ref]$remote)
            if ($reply.Length -lt 48 -or ($reply[0] -band 7) -ne 4) { throw 'Reponse NTP invalide.' }
            for ($i=0; $i -lt 8; $i++) { if ($reply[(24+$i)] -ne $packet[(40+$i)]) { throw 'Originate timestamp invalide.' } }
            $leap = $reply[0] -shr 6; $stratum = [int]$reply[1]
            $delay = Read-U32 $reply 4
            if ($delay -ge 2147483648) { $delay -= 4294967296 }
            $delay /= 65536
            $disp = (Read-U32 $reply 8)/65536
            $distance = [math]::Max(0,$delay)/2 + $disp
            $ref = Read-U32 $reply 16
            $age = ($now - $ref) % 4294967296
            if ($age -gt 2147483648) { $age -= 4294967296 }
            $valid = $leap -ne 3 -and $stratum -ge 1 -and $stratum -le 15 -and ($ref -ne 0 -or (Read-U32 $reply 20) -ne 0) -and ((Read-U32 $reply 40) -ne 0 -or (Read-U32 $reply 44) -ne 0)
            $result = [pscustomobject]@{Name=$Name; IP=[string]$ip; Responded=$true; Valid=$valid; Leap=$leap; Stratum=$stratum; RootDelay=$delay; RootDispersion=$disp; RootDistance=$distance; ReferenceAge=$age; Error=''}
            if ($valid) { return $result }
            $last = "Reponse non synchronisee : leap=$leap, stratum=$stratum"
        } catch { $last = $_.Exception.Message }
        finally { if ($null -ne $udp) { $udp.Close() } }
    }
    if ($null -ne $result) { return $result }
    return [pscustomobject]@{Name=$Name; IP=''; Responded=$false; Valid=$false; Leap=-1; Stratum=0; RootDelay=0; RootDispersion=0; RootDistance=0; ReferenceAge=-1; Error=$last}
}
function Show-Probe($p) {
    if ($p.Responded) { Write-Host ("{0} ({1}) : leap={2}, stratum={3}, dispersion={4:F6}s, distance annoncee={5:F6}s, ref_age={6:F1}s" -f $p.Name,$p.IP,$p.Leap,$p.Stratum,$p.RootDispersion,$p.RootDistance,$p.ReferenceAge) }
    else { Write-Host "$($p.Name) : aucune reponse NTP validee ($($p.Error))" }
}
function Test-SourceName([string]$Actual,[string]$Expected) {
    if ($Actual.TrimEnd('.') -ieq $Expected.TrimEnd('.')) { return $true }
    $addresses = @(Get-IPv4 $Expected | ForEach-Object { $_.IPAddressToString })
    return ($addresses -contains $Actual)
}

# Conservative audit of rules potentially matching W32Time inbound UDP/123.
function Test-OnlyAllowedAddress($Address) {
    $a = @($Address)
    return ($a.Count -eq 1 -and $a[0] -in @('10.0.2.0/28','10.0.2.0/255.255.255.240','10.0.2.0-10.0.2.15'))
}
# V4: explicit service-scoped deny outside the permitted IPv4 network.
# Windows Firewall gives explicit blocks precedence over ordinary allow rules.
# Stateful UDP replies to outbound queries must still be verified in practice.
$NtpDenyScopes = @{
    'LIN3-NTP-Deny-IPv4' = @('0.0.0.0-10.0.1.255','10.0.2.16-255.255.255.255')
    'LIN3-NTP-Deny-IPv6' = @('::/1','8000::/1')
}
function Normalize-NtpScope([string]$Address) {
    switch ($Address) {
        '::/8000::' { return '::/1' }
        '8000::/8000::' { return '8000::/1' }
        '::-7fff:ffff:ffff:ffff:ffff:ffff:ffff:ffff' { return '::/1' }
        '8000::-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff' { return '8000::/1' }
        default { return $Address }
    }
}
function Test-NtpDenyRules {
    foreach ($name in $NtpDenyScopes.Keys) {
        $rules = @(Get-NetFirewallRule -PolicyStore ActiveStore -Name $name -ErrorAction SilentlyContinue)
        if ($rules.Count -ne 1) { return $false }
        $r = $rules[0]
        $p = $r | Get-NetFirewallPortFilter
        $a = $r | Get-NetFirewallAddressFilter
        $s = $r | Get-NetFirewallServiceFilter
        $app = $r | Get-NetFirewallApplicationFilter
        $actual = @($a.RemoteAddress | ForEach-Object { Normalize-NtpScope $_ } | Sort-Object)
        $expected = @($NtpDenyScopes[$name] | Sort-Object)
        if ($r.Enabled -ne 'True' -or $r.Direction -ne 'Inbound' -or $r.Action -ne 'Block' -or $r.Profile -ne 'Any' -or
            [string]$p.Protocol -notin @('UDP','17') -or [string]$p.LocalPort -ne '123' -or [string]$p.RemotePort -ne 'Any' -or
            [string]$s.Service -ne 'W32Time' -or [string]$app.Program -ne 'Any' -or [string]$a.LocalAddress -ne 'Any' -or
            ($actual -join '|') -ne ($expected -join '|')) { return $false }
    }
    return $true
}
function Get-NtpBypassRules {
    # Authenticated IPsec bypass rules are an exception to block precedence.
    # Check all enabled inbound bypass rules, rather than assuming their scope.
    foreach ($r in @(Get-NetFirewallRule -PolicyStore ActiveStore -Enabled True -Direction Inbound -Action Allow)) {
        $security = $r | Get-NetFirewallSecurityFilter
        if ([string]$security.OverrideBlockRules -eq 'True') { $r }
    }
}

$exitCode = 1; $logging = $false
try {
    Assert-Administrator
    $Cfg = Read-NtpConfig
    Start-NtpLog "validate-$Mode"; $logging = $true
    Write-Host "LIN3 | Validation NTP V4 - explicit deny | Mode $Mode" -ForegroundColor Cyan
    Write-Host "Date et heure suisse : $(Get-Date -Format 'dd.MM.yyyy HH:mm:ss zzz')"
    Get-TimeZone | Format-List Id,DisplayName,SupportsDaylightSavingTime | Out-Host
    Write-Host "UTC : $([datetime]::UtcNow.ToString('dd.MM.yyyy HH:mm:ss'))"
    Write-Host '[1/5] Service, fournisseurs et configuration...'
    Test-Result ((Get-TimeZone).Id -eq $Cfg.TZ_NAME) "Fuseau horaire : $($Cfg.TZ_NAME)"
    $svc = Get-CimInstance Win32_Service -Filter "Name='W32Time'"
    Test-Result ($svc.State -eq 'Running' -and $svc.StartMode -eq 'Auto') 'W32Time actif et automatique'
    $p = Get-ItemProperty "$Base\Parameters"
    $peers = @($p.NtpServer -split '\s+' | Where-Object { $_ })
    $expectedPeers = @("$($Cfg.NTP_PRIMARY_SERVER),0x8") + @($Cfg.BACKUP_HOSTS | ForEach-Object { "$_,0xA" })
    $unexpectedPeers = @($peers | Where-Object { $_ -notin $expectedPeers })
    $missingPeers = @($expectedPeers | Where-Object { $_ -notin $peers })
    Test-Result ($p.Type -eq 'NTP' -and $peers.Count -eq $expectedPeers.Count -and $unexpectedPeers.Count -eq 0 -and $missingPeers.Count -eq 0) 'Sources principale et secours (0x8 / 0xA)'
    foreach ($provider in @('NtpClient','NtpServer')) { Test-Result ((Get-ItemProperty "$Base\TimeProviders\$provider").Enabled -eq 1) "$provider active" }
    $nc = Get-ItemProperty "$Base\TimeProviders\NtpClient"
    Test-Result ($nc.InputProvider -eq 1 -and $nc.EventLogFlags -eq $Cfg.NTP_EVENT_LOG_FLAGS) 'InputProvider et journalisation NtpClient'
    $settings = Get-ItemProperty "$Base\Config"
    Test-Result ($settings.MinPollInterval -eq $Cfg.NTP_MIN_POLL_INTERVAL -and $settings.MaxPollInterval -eq $Cfg.NTP_MAX_POLL_INTERVAL -and $settings.UpdateInterval -eq $Cfg.NTP_UPDATE_INTERVAL -and $settings.AnnounceFlags -eq $Cfg.NTP_ANNOUNCE_FLAGS) 'Intervalles, ajustement et annonce automatique'
    $vmic = "$Base\TimeProviders\VMICTimeProvider"
    if ($Cfg.NTP_DISABLE_VMIC -eq 1 -and (Test-Path $vmic)) { Test-Result ((Get-ItemProperty $vmic).Enabled -eq 0) 'Fournisseur VMIC desactive' }
    $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\W32Time'
    if (Test-Path $policy) { Test-Result ((Get-Item $policy).ValueCount -eq 0 -and @(Get-ChildItem $policy -Recurse | Where-Object { $_.ValueCount -gt 0 }).Count -eq 0) 'Aucune GPO W32Time concurrente' }
    Invoke-W32Time -Arguments @('/query','/configuration')
    Invoke-W32Time -Arguments @('/query','/peers')
    Write-Host '[2/5] Ecoute UDP 123 et pare-feu effectif...'
    $ep = @(Get-NetUDPEndpoint -LocalPort 123 -ErrorAction SilentlyContinue | Where-Object OwningProcess -eq $svc.ProcessId)
    Test-Result ($ep.Count -gt 0 -and $svc.ProcessId -gt 0) 'W32Time ecoute UDP 123'
    $rules = @(Get-NetFirewallRule -PolicyStore ActiveStore | Where-Object Name -eq $RuleName)
    $validRule = $false
    if ($rules.Count -eq 1) {
        $r = $rules[0]; $port = $r | Get-NetFirewallPortFilter; $addr = $r | Get-NetFirewallAddressFilter
        $actual = @($addr.RemoteAddress); $expected = $Cfg.NTP_ALLOWED_SUBNET
        $match = Test-OnlyAllowedAddress $actual
        if ($expected -eq 'LocalSubnet') { $match = $actual.Count -gt 0 -and @($actual | Where-Object { $_ -notin @('LocalSubnet','LocalSubnet4','LocalSubnet6') }).Count -eq 0 }
        # Windows peut normaliser CIDR en adresse/masque.
        if (-not $match -and $expected -match '/') {
            $parts = $expected -split '/'; $bits = [int]$parts[1]
            $mask = (0..3 | ForEach-Object { $n=[math]::Min(8,[math]::Max(0,$bits-8*$_)); [int](256-[math]::Pow(2,8-$n)) }) -join '.'
            $match = $actual.Count -eq 1 -and $actual[0] -eq "$($parts[0])/$mask"
        }
        $validRule = $r.Enabled -eq 'True' -and $r.Direction -eq 'Inbound' -and $r.Action -eq 'Allow' -and $r.Profile -eq 'Any' -and $port.Protocol -in @('UDP','17') -and [string]$port.LocalPort -eq '123' -and $match -and [string]($r | Get-NetFirewallServiceFilter).Service -eq 'W32Time'
    }
    Test-Result $validRule 'Regle active du projet conforme'
    $profiles = @(Get-NetFirewallProfile -PolicyStore ActiveStore)
    Test-Result (@($profiles | Where-Object { $_.Enabled -ne 'True' -or $_.DefaultInboundAction -ne 'Block' -or $_.AllowInboundRules -eq 'False' }).Count -eq 0) 'Pare-feu actif, trafic entrant bloque par defaut'
    Test-Result (Test-NtpDenyRules) 'Regles de refus explicite IPv4 hors du /28 et IPv6 actives'
    $bypass = @(Get-NtpBypassRules)
    if ($bypass.Count) { $bypass | Select-Object Name,DisplayName | Format-Table -AutoSize | Out-Host }
    Test-Result ($bypass.Count -eq 0) 'Aucun contournement IPsec entrant detecte'
    Write-Host '[INFO] Tester depuis une IP de 10.0.2.0/28 et une IP hors de ce sous-reseau. Les regles cloud restent a verifier.'
    Write-Host '[3/5] Source active et reponse locale NTP (sans forcer le service)...'
    $deadline = [datetime]::UtcNow.AddSeconds($WaitSeconds)
    do {
        $source = (& w32tm.exe /query /source 2>&1 | Out-String).Trim(); $sourceCode = $LASTEXITCODE
        $name = ($source -split ',')[0].Trim()
        $primary = $sourceCode -eq 0 -and (Test-SourceName $name $Cfg.NTP_PRIMARY_SERVER)
        $backup = $false; foreach ($candidate in $Cfg.BACKUP_HOSTS) { if (Test-SourceName $name $candidate) { $backup = $true; break } }
        $sourceOK = switch ($Mode) { 'Failover' { $backup } 'Any' { $primary -or $backup } default { $primary } }
        $local = Get-NtpProbe '127.0.0.1'
        $maxAge = [math]::Max(300,3*[math]::Pow(2,$Cfg.NTP_MAX_POLL_INTERVAL))
        $localOK = $local.Valid -and $local.RootDistance -lt $Cfg.NTP_MAX_ROOT_DISTANCE -and $local.ReferenceAge -ge -5 -and $local.ReferenceAge -le $maxAge
        Write-Host "Source active : $source"; Show-Probe $local
        if ($sourceOK -and $localOK) { break }
        $remaining = ($deadline - [datetime]::UtcNow).TotalSeconds
        if ($remaining -le 0) { break }
        Start-Sleep -Seconds ([int][math]::Min(10,[math]::Ceiling($remaining)))
    } while ($true)
    Test-Result $sourceOK "Source attendue pour le mode $Mode"
    Test-Result $localOK 'Reponse locale synchronisee, recente et distance annoncee sous la limite'
    Invoke-W32Time -Arguments @('/query','/status','/verbose')
    Write-Host '[4/5] Requetes NTP vers les sources...'
    $p1 = Get-NtpProbe $Cfg.NTP_PRIMARY_SERVER; Show-Probe $p1
    $backupProbes = @($Cfg.BACKUP_HOSTS | ForEach-Object { Get-NtpProbe $_ })
    foreach ($probe in $backupProbes) { Show-Probe $probe }
    $validBackups = @($backupProbes | Where-Object { $_.Valid -and $_.RootDistance -lt $Cfg.NTP_MAX_ROOT_DISTANCE })
    if ($Mode -eq 'Failover') {
        Test-Result (-not $p1.Valid) 'Source principale indisponible ou non synchronisee'
        Test-Result (@($validBackups | Where-Object { Test-SourceName $name $_.Name }).Count -gt 0) 'Source de secours selectionnee et joignable'
    } elseif ($Mode -eq 'Any') {
        Test-Result (($primary -and $p1.Valid) -or ($backup -and $validBackups.Count -gt 0)) 'Source active repond aux requetes NTP'
    } else {
        Test-Result $p1.Valid 'Source principale synchronisee'
        Test-Result ($validBackups.Count -gt 0) 'Au moins une source de secours disponible'
    }
    Write-Host '[5/5] Journaux Windows Time (preuves de demonstration)...'
    $since = (Get-Date).AddMinutes(-15)
    $marker = Join-Path $PSScriptRoot 'logs\last-install-utc.txt'
    if (Test-Path -LiteralPath $marker) { $since = [datetime]::Parse((Get-Content -LiteralPath $marker -Raw).Trim()).ToLocalTime() }
    Write-Host "Evenements depuis : $since"
    $events = @(Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Microsoft-Windows-Time-Service';StartTime=$since} -MaxEvents 15 -ErrorAction SilentlyContinue)
    if ($events.Count -gt 0) { $events | Select-Object TimeCreated,Id,LevelDisplayName,Message | Format-List | Out-Host }
    else { Write-Warning 'Aucun evenement System recent. Verifier aussi le canal Operational.' }
    Write-Host '[INFO] Une sonde locale ne remplace pas le test depuis le client Linux. Correlation des journaux avec la panne necessaire.'
    if ($script:Errors -eq 0) { Write-Host "[OK] Validation Windows $Mode reussie." -ForegroundColor Green; $exitCode = 0 }
    else { Write-Host "[ECHEC] $script:Errors verification(s) non validee(s)." -ForegroundColor Red; $exitCode = 2 }
} catch { Write-Host "[ERREUR] $_" -ForegroundColor Red; $exitCode = 1 }
finally { if ($logging) { Stop-Transcript | Out-Null } }
exit $exitCode
