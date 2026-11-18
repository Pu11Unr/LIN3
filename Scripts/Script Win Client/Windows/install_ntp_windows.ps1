# ==============================
# Script de configuration NTP - Windows
# Projet LIN3 - Client et serveur NTP secondaire
# PowerShell -ExecutionPolicy Bypass -File install_ntp_windows.ps1
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

function Invoke-W32Time {
    param([string[]]$Arguments)
    & w32tm.exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Echec w32tm (code $LASTEXITCODE)" }
}

try {
    Assert-Administrator
    $Cfg = Read-NtpConfig
    $Peers = "$($Cfg.NTP_PRIMARY_SERVER),0x8 $($Cfg.NTP_BACKUP_SERVER),0xA"
    Write-Host '===============================' -ForegroundColor Cyan
    Write-Host ' Configuration NTP - Windows'
    Write-Host " Source principale : $($Cfg.NTP_PRIMARY_SERVER)"
    Write-Host " Source de secours : $($Cfg.NTP_BACKUP_SERVER)"
    Write-Host '===============================' -ForegroundColor Cyan

    # 1. Activation du service et des fournisseurs NTP
    Write-Host '[1/5] Activation du service Windows Time...'
    Set-Service -Name W32Time -StartupType Automatic
    foreach ($provider in @('NtpClient','NtpServer')) {
        New-ItemProperty -Path "$Base\TimeProviders\$provider" -Name Enabled -PropertyType DWord -Value 1 -Force | Out-Null
    }
    Start-Service -Name W32Time
    Write-Host '[OK] Client et serveur NTP actives' -ForegroundColor Green

    # 2. Configuration des sources principale et secondaire
    Write-Host '[2/5] Configuration des sources NTP...'
    Invoke-W32Time -Arguments @('/config', "/manualpeerlist:$Peers", '/syncfromflags:manual', '/update')
    Write-Host '[OK] Sources NTP configurees' -ForegroundColor Green

    # 3. Configuration des intervalles et de l'ajustement
    Write-Host '[3/5] Configuration des intervalles...'
    New-ItemProperty -Path "$Base\Config" -Name MinPollInterval -PropertyType DWord -Value $Cfg.NTP_MIN_POLL_INTERVAL -Force | Out-Null
    New-ItemProperty -Path "$Base\Config" -Name MaxPollInterval -PropertyType DWord -Value $Cfg.NTP_MAX_POLL_INTERVAL -Force | Out-Null
    New-ItemProperty -Path "$Base\Config" -Name UpdateInterval -PropertyType DWord -Value $Cfg.NTP_UPDATE_INTERVAL -Force | Out-Null
    Write-Host '[OK] Parametres enregistres' -ForegroundColor Green

    # 4. Configuration du pare-feu (sans doublon)
    Write-Host '[4/5] Configuration du pare-feu UDP 123...'
    $rules = @(Get-NetFirewallRule -PolicyStore PersistentStore -ErrorAction Stop | Where-Object DisplayName -eq $RuleName)
    $params = @{Direction='Inbound'; Action='Allow'; Enabled='True'; Profile='Any'; Protocol='UDP'; LocalPort=123; RemoteAddress=$Cfg.NTP_ALLOWED_SUBNET; LocalAddress='Any'; RemotePort='Any'; EdgeTraversalPolicy='Block'}
    if ($rules.Count -gt 0) {
        foreach ($rule in $rules) { Set-NetFirewallRule -Name $rule.Name -PolicyStore PersistentStore @params | Out-Null }
    } else {
        New-NetFirewallRule -Name 'LIN3-NTP-Server' -DisplayName $RuleName -PolicyStore PersistentStore @params | Out-Null
    }
    Write-Host '[OK] Regle pare-feu configuree' -ForegroundColor Green

    # 5. Application et synchronisation
    Write-Host '[5/5] Application de la configuration...'
    Invoke-W32Time -Arguments @('/config','/update')
    Restart-Service -Name W32Time
    & w32tm.exe /resync /rediscover
    $syncCode = $LASTEXITCODE
    Write-Host '===============================' -ForegroundColor Cyan
    if ($syncCode -ne 0) {
        Write-Host '[AVERTISSEMENT] Configuration appliquee, synchronisation non confirmee. Relancer la validation apres stabilisation.' -ForegroundColor Yellow
        exit 2
    }
    Write-Host '[OK] Configuration appliquee. Executer le script de validation apres stabilisation.' -ForegroundColor Green
    exit 0
} catch {
    Write-Host "[ERREUR] $_" -ForegroundColor Red
    exit 1
}
