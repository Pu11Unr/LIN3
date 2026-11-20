# LIN3 — Windows NTP (V4)

## Fichiers
- `env.windows.template` : paramètres du site. Copier en `.env.windows.txt`.
- `install_ntp_windows.ps1` : installation, sauvegarde et configuration du Windows Time Service, puis validation.
- `validate_ntp_windows.ps1` : validation en mode `Normal`, `Failover`, `Recovery` ou `Any`, avec requêtes UDP/NTP réelles et journaux.

## AWS équipe 02
- Serveur Linux principal : `10.0.2.10` (à vérifier avant lancement).
- Windows secondaire : `10.0.2.11` (son IP et son nom restent inchangés).
- Client Linux : `10.0.2.12`.
- Fuseau Windows Dublin : `GMT Standard Time` (équivalent Linux : `Europe/Dublin`).
- Secours : `169.254.169.123`, `time.cloudflare.com`, `ie.pool.ntp.org`. Vérifier l'accessibilité réseau.

## Installation (PowerShell administrateur)
```powershell
cd C:\NTP
Copy-Item .\env.windows.template .\.env.windows.txt
notepad .\.env.windows.txt
powershell -NoProfile -ExecutionPolicy Bypass -File .\install_ntp_windows.ps1
```

## Validation
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\validate_ntp_windows.ps1 -Mode Normal -WaitSeconds 300
# Pendant l'arrêt volontaire du serveur principal, en coordination avec l'équipe :
powershell -NoProfile -ExecutionPolicy Bypass -File .\validate_ntp_windows.ps1 -Mode Failover -WaitSeconds 900
# Après rétablissement du serveur principal :
powershell -NoProfile -ExecutionPolicy Bypass -File .\validate_ntp_windows.ps1 -Mode Recovery -WaitSeconds 900
```

**Important :** la configuration de Windows ne peut ni démarrer le service NTP Linux ni modifier les Security Groups et ACL réseau AWS. Le mode de validation du failover constate les conditions : il ne provoque pas de panne. L'heure de Windows n'est jamais réglée manuellement. La validation de la synchronisation du client Linux doit être effectuée sur cette machine.

Les scripts n'ont pas été exécutés sur une instance Windows dans cet environnement : la validation réelle sur AWS reste indispensable.
