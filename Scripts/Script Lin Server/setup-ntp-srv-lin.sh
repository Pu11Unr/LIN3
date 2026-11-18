#!/usr/bin/env bash
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Faut lancer en sudo"; exit 1; }

CONF=/etc/ntpsec/ntp.conf
SERVERS="ntp11.metas.ch ntp12.metas.ch ntp13.metas.ch"   # METAS (métrologie suisse)

# Installation
apt-get update
apt-get install -y ntpsec

# Sources : désactive les pools Debian, ajoute les serveurs METAS (une seule fois)
sed -i -E 's/^\s*pool\s/#&/' "$CONF"
for s in $SERVERS; do
  grep -q "^server $s " "$CONF" || echo "server $s iburst" >> "$CONF"
done

# Démarrage
systemctl enable ntpsec
systemctl restart ntpsec

# Vérifications (le script s'arrête avec une erreur si l'une échoue)
systemctl is-active ntpsec
systemctl is-enabled ntpsec
if dpkg -s systemd-timesyncd 2>/dev/null | grep -q "Status: install ok installed"; then
  echo "ECHEC : systemd-timesyncd est encore là"; exit 1
fi
grep -E '^\s*(pool|server)' "$CONF"
ss -uln | grep -E ':123\b' > /dev/null

# Attente de la synchronisation (max 2 min)
synced() { ntpq -pn | grep '^\*' > /dev/null; }
for _ in {1..24}; do synced && break; sleep 5; done
ntpq -p
synced || { echo "ECHEC : y'a pa des synchro."; exit 1; }

# Stratum attendu : 2
ntpq -c rv | grep -E 'stratum=2\b' > /dev/null || { echo "ECHEC : Le stratum est pas à deux"; exit 1; }

echo "Voilà, c'est fini"
