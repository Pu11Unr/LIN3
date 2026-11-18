# ==============================
# Script de validation NTP - Windows
# Projet LIN3 - Client et serveur NTP secondaire
# PowerShell -ExecutionPolicy Bypass -File validate_ntp_windows.ps1
# ==============================

# ==============================
# Chargement du fichier .env et verification des droits
# ==============================
$ErrorActionPreference = 'Stop'
$EnvFile = Join-Path $PSScriptRoot '.env.windows.txt'

function Read-NtpConfig {
    if (-not (Test-Path -LiteralPath $EnvFile)) {
        throw 'Fichier .env.windows.txt introuvable. Copier env.windows.template vers .env.windows.txt.'
    }
    $config = @{}
    foreach ($line in (Get-Content -LiteralPath $EnvFile)) {
        if ($line -match '^\s*(#|$)') { continue }
        $parts = $line -split '=', 2
        if ($parts.Count -ne 2) { throw "Ligne de configuration invalide : $line" }
        $key = $parts[0].Trim()
        if ($config.ContainsKey($key)) { throw "Variable en double : $key" }
        $config[$key] = $parts[1].Trim()
    }
    foreach ($key in @('NTP_PRIMARY_SERVER','NTP_BACKUP_SERVER','NTP_ALLOWED_SUBNET','NTP_MIN_POLL_INTERVAL','NTP_MAX_POLL_INTERVAL','NTP_UPDATE_INTERVAL')) {
        if (-not $config.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($config[$key])) { throw "Variable manquante : $key" }
    }
    foreach ($key in @('NTP_PRIMARY_SERVER','NTP_BACKUP_SERVER')) {
        if ($config[$key] -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.:-]*$') { throw "Source NTP invalide : $key" }
    }
    if ($config.NTP_PRIMARY_SERVER -eq $config.NTP_BACKUP_SERVER) { throw 'Les deux sources doivent etre differentes.' }
    foreach ($key in @('NTP_MIN_POLL_INTERVAL','NTP_MAX_POLL_INTERVAL','NTP_UPDATE_INTERVAL')) {
        $value = 0
        if (-not [int]::TryParse($config[$key], [ref]$value)) { throw "Valeur numerique invalide : $key" }
        $config[$key] = $value
    }
    if ($config.NTP_MIN_POLL_INTERVAL -lt 6 -or $config.NTP_MAX_POLL_INTERVAL -gt 15 -or $config.NTP_MIN_POLL_INTERVAL -gt $config.NTP_MAX_POLL_INTERVAL -or $config.NTP_UPDATE_INTERVAL -lt 1) { throw 'Intervalles NTP invalides.' }
    if ($config.NTP_ALLOWED_SUBNET -eq 'Any' -or $config.NTP_ALLOWED_SUBNET -eq '*') { throw 'Une plage reseau restreinte est requise.' }
    return $config
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Executer ce script en tant qu Administrateur.'
    }
}

$Base = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time'
$RuleName = 'LIN3 - NTP Server'

$script:Errors = 0
function Test-Result {
    param([bool]$Passed, [string]$Message)
    if ($Passed) { Write-Host "[OK] $Message" -ForegroundColor Green }
    else { Write-Host "[ERREUR] $Message" -ForegroundColor Red; $script:Errors++ }
}

try {
    Assert-Administrator
    $Cfg = Read-NtpConfig
    Write-Host '===============================' -ForegroundColor Cyan
    Write-Host ' Validation NTP - Windows (fonctionnement normal)'
    Write-Host '===============================' -ForegroundColor Cyan

    # 1. Service Windows Time
    Write-Host '[1/6] Verification du service Windows Time...'
    $svc = Get-CimInstance Win32_Service -Filter "Name='W32Time'"
    Test-Result ($svc.State -eq 'Running' -and $svc.StartMode -eq 'Auto') 'Service W32Time actif et automatique'

    # 2. Sources et fournisseurs NTP
    Write-Host '[2/6] Verification des sources et fournisseurs NTP...'
    $parameters = Get-ItemProperty "$Base\Parameters"
    $peers = @($parameters.NtpServer -split '\s+' | Where-Object { $_ })
    Test-Result ($parameters.Type -eq 'NTP' -and $peers.Count -eq 2 -and $peers -contains "$($Cfg.NTP_PRIMARY_SERVER),0x8" -and $peers -contains "$($Cfg.NTP_BACKUP_SERVER),0xA") 'Sources principale et de secours configurees'
    foreach ($provider in @('NtpClient','NtpServer')) {
        $enabled = (Get-ItemProperty "$Base\TimeProviders\$provider").Enabled
        Test-Result ($enabled -eq 1) "$provider active"
    }
    $peerOutput = & w32tm.exe /query /peers
    $peerCode = $LASTEXITCODE
    $peerOutput | Write-Host
    Test-Result ($peerCode -eq 0) 'Liste des pairs accessible (etat affiche ci-dessus)'

    # 3. Parametres de synchronisation
    Write-Host '[3/6] Verification des intervalles...'
    $settings = Get-ItemProperty "$Base\Config"
    Test-Result ($settings.MinPollInterval -eq $Cfg.NTP_MIN_POLL_INTERVAL -and $settings.MaxPollInterval -eq $Cfg.NTP_MAX_POLL_INTERVAL -and $settings.UpdateInterval -eq $Cfg.NTP_UPDATE_INTERVAL) 'Intervalles et UpdateInterval conformes'

    # 4. Port UDP 123 et pare-feu
    Write-Host '[4/6] Verification du port et du pare-feu...'
    $endpoint = @(Get-NetUDPEndpoint -LocalPort 123 -ErrorAction SilentlyContinue | Where-Object OwningProcess -eq $svc.ProcessId)
    Test-Result ($endpoint.Count -gt 0 -and $svc.ProcessId -gt 0) 'Port UDP 123 ouvert par le processus W32Time'
    $rules = @(Get-NetFirewallRule -PolicyStore ActiveStore | Where-Object DisplayName -eq $RuleName)
    $valid = $rules.Count -gt 0
    foreach ($rule in $rules) {
        $port = $rule | Get-NetFirewallPortFilter
        $address = $rule | Get-NetFirewallAddressFilter
        $expected = $Cfg.NTP_ALLOWED_SUBNET
        $actual = @($address.RemoteAddress)
        $matches = ($actual.Count -eq 1 -and $actual[0] -eq $expected)
        if ($expected -eq 'LocalSubnet' -and $actual.Count -gt 0 -and @($actual | Where-Object { $_ -notin @('LocalSubnet','LocalSubnet4','LocalSubnet6') }).Count -eq 0) { $matches = $true }
        if ($rule.Enabled -ne 'True' -or $rule.Direction -ne 'Inbound' -or $rule.Action -ne 'Allow' -or $rule.Profile -ne 'Any' -or $port.Protocol -notin @('UDP','17') -or [string]$port.LocalPort -ne '123' -or -not $matches) { $valid = $false }
    }
    Test-Result $valid 'Regle active UDP 123 conforme a la plage autorisee'

    # 5. Source NTP active et etat de synchronisation
    Write-Host '[5/6] Verification de la synchronisation normale...'
    $source = & w32tm.exe /query /source
    $sourceCode = $LASTEXITCODE
    $sourceText = ($source -join ' ').Trim()
    Write-Host "Source actuelle : $sourceText"
    Test-Result ($sourceCode -eq 0 -and ($sourceText -split ',')[0] -eq $Cfg.NTP_PRIMARY_SERVER) 'Source principale selectionnee'
    $status = & w32tm.exe /query /status /verbose
    $statusCode = $LASTEXITCODE
    $status | Write-Host
    Test-Result ($statusCode -eq 0) 'Etat W32Time accessible (precision et leap affiches ci-dessus)'

    # 6. Test NTP reel vers les sources (UDP, sans modifier l'heure)
    Write-Host '[6/6] Verification de la reponse NTP des deux sources...'
    foreach ($server in @($Cfg.NTP_PRIMARY_SERVER,$Cfg.NTP_BACKUP_SERVER)) {
        $samples = & w32tm.exe /stripchart "/computer:$server" /dataonly /samples:3
        $sampleCode = $LASTEXITCODE
        $samples | Write-Host
        $validSamples = @($samples | Where-Object { $_ -match '^\s*\d{1,2}:\d{2}:\d{2}.*[+-]\d+[.,]\d+s\s*$' })
        Test-Result ($sampleCode -eq 0 -and $validSamples.Count -gt 0) "Reponse NTP de $server"
    }

    Write-Host '===============================' -ForegroundColor Cyan
    if ($script:Errors -eq 0) { Write-Host '[OK] Verifications locales et sources NTP valides.' -ForegroundColor Green }
    else { Write-Host "[ERREUR] $script:Errors verification(s) en echec." -ForegroundColor Red }
    Write-Host '[INFO] Verifier manuellement Leap, Stratum et Root Dispersion ci-dessus.' -ForegroundColor Yellow
    Write-Host '[INFO] Le test depuis le client Linux et le failover complet doivent etre effectues separement.' -ForegroundColor Yellow
    exit $script:Errors
} catch {
    Write-Host "[ERREUR] $_" -ForegroundColor Red
    exit 1
}
