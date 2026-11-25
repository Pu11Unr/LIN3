#!/usr/bin/env bash
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Il faut root"; exit 1; }

CONF=/etc/ntpsec/ntp.conf
SERVERS="0.ie.pool.ntp.org 1.ie.pool.ntp.org 2.ie.pool.ntp.org 3.ie.pool.ntp.org"
CLIENT_SUBNET="10.0.2.0"
CLIENT_MASK="255.255.255.0"

# Installation
apt-get update
apt-get install -y ntpsec

# Écrire la config complète (ordre important : restrict avant server)
cat > "$CONF" <<EOF
# === NTPSEC Configuration — DC source horloge ===

# --- Logging ---
logfile /var/log/ntpsec/ntp.log
logconfig = +syspeer +peer +clock +cfgstats +timerall

# --- Restriction ---
# Refuser tout par défaut
restrict -4 default kod nomodify notrap nopeer noquery
restrict -6 default kod nomodify notrap nopeer noquery

# Localhost (ntpq / ntpdc locaux)
restrict 127.0.0.1
restrict ::1

# Sous-réseau clients
restrict ${CLIENT_SUBNET} mask ${CLIENT_MASK} nomodify notrap nopeer

# Pools upstream
restrict 0.ie.pool.ntp.org nomodify notrap nopeer
restrict 1.ie.pool.ntp.org nomodify notrap nopeer
restrict 2.ie.pool.ntp.org nomodify notrap nopeer
restrict 3.ie.pool.ntp.org nomodify notrap nopeer

# --- Sources ---
EOF

for s in $SERVERS; do
  echo "server $s" >> "$CONF"
done

# Démarrage
systemctl enable ntpsec
systemctl restart ntpsec

# Vérifications
systemctl is-active ntpsec
systemctl is-enabled ntpsec

if dpkg -s systemd-timesyncd 2>/dev/null | grep -q "Status: install ok installed"; then
  echo "ECHEC : systemd-timesyncd est encore installé."; exit 1
fi

grep -E '^\s*(pool|server)' "$CONF"
ss -uln | grep -E ':123\b' > /dev/null

# Attente de la synchronisation (max 10 min)
synced() { ntpq -pn | grep '^\*' > /dev/null; }
for _ in {1..120}; do synced && break; sleep 5; done
ntpq -p
synced || { echo "ECHEC : pas de synchronisation."; exit 1; }

# Stratum
ntpq -c rv | grep -o 'stratum=[0-9]*'

echo "C'est bon"
