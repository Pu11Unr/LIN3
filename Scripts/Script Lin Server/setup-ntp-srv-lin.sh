#!/usr/bin/env bash
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Il faut root"; exit 1; }

CONF=/etc/ntpsec/ntp.conf
SERVERS="0.ie.pool.ntp.org 1.ie.pool.ntp.org 2.ie.pool.ntp.org 3.ie.pool.ntp.org"   # Pool NTP Irlande

# Installation
apt-get update
apt-get install -y ntpsec

# Sources : supprime les anciennes (pools Debian, METAS...) et ajoute celles d'Irlande
sed -i -E '/^\s*(pool|server)\s/d' "$CONF"
for s in $SERVERS; do
  echo "server $s" >> "$CONF"
done

# Démarrage
systemctl enable ntpsec
systemctl restart ntpsec

# Vérifications (le script s'arrête avec une erreur si l'une échoue)
systemctl is-active ntpsec
systemctl is-enabled ntpsec
if dpkg -s systemd-timesyncd 2>/dev/null | grep -q "Status: install ok installed"; then
  echo "ECHEC : systemd-timesyncd est encore installé."; exit 1
fi
grep -E '^\s*(pool|server)' "$CONF"
ss -uln | grep -E ':123\b' > /dev/null

# Attente de la synchronisation (max 10 min, sans iburst c'est plus lent)
synced() { ntpq -pn | grep '^\*' > /dev/null; }
for _ in {1..120}; do synced && break; sleep 5; done
ntpq -p
synced || { echo "ECHEC : pas de synchronisation."; exit 1; }

# Stratum du serveur (affiché)
ntpq -c rv | grep -o 'stratum=[0-9]*'

echo "C'est bon"
