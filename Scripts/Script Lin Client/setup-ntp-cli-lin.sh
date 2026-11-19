#!/usr/bin/env bash
# =============================================================================
# setup-ntp-cli-lin.sh
# Projet  : LIN3 - déploiement NTP
# Cible   : client Linux Ubuntu Server (ntp-cli-lin)
# Rôle    : installe les outils de base, configure le client NTP avec
#           systemd-timesyncd / timedatectl, puis vérifie le résultat
#           (y compris la réception effective de paquets NTP du serveur).
#
# Usage   : ./setup-ntp-cli-lin.sh
#           (se relance automatiquement en root via sudo)
#
# Le réseau n'est pas modifié par ce script.
# =============================================================================
set -euo pipefail

# ========= Variables à adapter =========
HOSTNAME_NEW=""
TIMEZONE="Europe/Dublin"      # vide = ne pas changer le fuseau horaire
NTP_SERVER="10.0.2.10"
SYNC_TIMEOUT=20               # secondes d'attente max pour la synchronisation
CAPTURE_TIMEOUT=$SYNC_TIMEOUT # durée max de la capture des paquets NTP
# ========================================

# ---------- Auto-élévation en root ----------
if [[ $EUID -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    echo "Élévation des privilèges via sudo..."
    exec sudo -E bash "$0" "$@"
  else
    echo "Erreur : ni root ni sudo disponible. Lancez : su -c 'bash $0'" >&2
    exit 1
  fi
fi

export DEBIAN_FRONTEND=noninteractive
ERRORS=0
ok()   { echo -e "[\e[32m OK \e[0m] $1"; }
fail() { echo -e "[\e[31mÉCHEC\e[0m] $1"; [[ -n "${2:-}" ]] && echo "         ↳ Erreur : $2"; ERRORS=$((ERRORS+1)); }
step() { echo -e "\n\e[1m== $1 ==\e[0m"; }

# ---------- 1. Nom d'hôte (optionnel) ----------
step "1. Nom d'hôte"
if [[ -n "$HOSTNAME_NEW" ]]; then
  hostnamectl set-hostname "$HOSTNAME_NEW"
  grep -q "$HOSTNAME_NEW" /etc/hosts || echo "127.0.1.1 $HOSTNAME_NEW" >> /etc/hosts
  echo "Nom d'hôte défini : $HOSTNAME_NEW"
else
  echo "Inchangé : $(hostname)"
fi

# ---------- 2. Paquets nécessaires ----------
step "2. Installation des paquets"
apt-get update -y
apt-get install -y \
  systemd-timesyncd \
  iputils-ping \
  iproute2 \
  bind9-dnsutils \
  traceroute \
  net-tools \
  curl \
  ca-certificates \
  vim \
  tcpdump

# ---------- 3. Retirer les clients NTP concurrents ----------
step "3. Suppression des clients NTP concurrents"
for svc in chrony ntp ntpsec; do
  if dpkg -s "$svc" >/dev/null 2>&1; then
    systemctl disable --now "$svc" 2>/dev/null || true
    apt-get purge -y "$svc"
    echo "Paquet $svc supprimé"
  fi
done

# ---------- 4. Fuseau horaire ----------
step "4. Fuseau horaire"
if [[ -n "$TIMEZONE" ]]; then
  if timedatectl list-timezones | grep -qx "$TIMEZONE"; then
    timedatectl set-timezone "$TIMEZONE"
    echo "Fuseau horaire défini : $TIMEZONE"
  else
    echo "Fuseau horaire inconnu : $TIMEZONE (inchangé)"
  fi
else
  echo "Inchangé : $(timedatectl show -p Timezone --value)"
fi

# ---------- 5. Configuration de timesyncd ----------
step "5. Configuration de systemd-timesyncd"
systemctl unmask systemd-timesyncd 2>/dev/null || true
mkdir -p /etc/systemd/timesyncd.conf.d
if [[ -n "$NTP_SERVER" ]]; then
  cat > /etc/systemd/timesyncd.conf.d/ntp.conf <<EOF
[Time]
NTP=${NTP_SERVER}
FallbackNTP=
ConnectionRetrySec=5
EOF
  echo "Serveur NTP : $NTP_SERVER (sans fallback, nouvelle tentative toutes les 5 s)"
else
  rm -f /etc/systemd/timesyncd.conf.d/ntp.conf
  echo "Serveurs NTP par défaut conservés"
fi

# ---------- 6. Activation ----------
step "6. Activation du service"
systemctl enable systemd-timesyncd

# Capture : 1 réponse NTP (UDP/123) provenant du serveur.
# Lancée AVANT le redémarrage : le premier paquet part au démarrage de timesyncd.
CAPTURE_FILE=$(mktemp)
TCPDUMP_PID=""
if [[ -n "$NTP_SERVER" ]]; then
  timeout "$CAPTURE_TIMEOUT" tcpdump -n -l -i any -c 1 \
    "udp src port 123 and src host $NTP_SERVER" >"$CAPTURE_FILE" 2>&1 &
  TCPDUMP_PID=$!
  sleep 1   # laisse tcpdump s'initialiser
fi

systemctl restart systemd-timesyncd
timedatectl set-ntp true

echo "Attente de la synchronisation (max ${SYNC_TIMEOUT}s)..."
for ((i=0; i<SYNC_TIMEOUT; i+=2)); do
  [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]] && break
  sleep 2
done

# ---------- 7. Vérifications ----------
step "7. Vérifications"

# 7.1 Outils disponibles (vérification par commande)
for cmd in timedatectl ping ip dig curl tcpdump; do
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "Commande $cmd disponible"
  else
    fail "Commande $cmd manquante" "installer le paquet qui fournit $cmd"
  fi
done
if dpkg -s systemd-timesyncd >/dev/null 2>&1; then
  ok "Paquet systemd-timesyncd installé"
else
  fail "Paquet systemd-timesyncd manquant" "apt-get install -y systemd-timesyncd"
fi

# 7.2 Aucun client NTP concurrent
conflict=""
for svc in chrony ntp ntpsec; do dpkg -s "$svc" >/dev/null 2>&1 && conflict+="$svc "; done
if [[ -z "$conflict" ]]; then
  ok "Aucun client NTP concurrent installé"
else
  fail "Client(s) NTP concurrent(s) présent(s)" "$conflict"
fi

# 7.3 Fuseau horaire
if [[ -n "$TIMEZONE" ]]; then
  current_tz=$(timedatectl show -p Timezone --value 2>/dev/null)
  if [[ "$current_tz" == "$TIMEZONE" ]]; then
    ok "Fuseau horaire : $current_tz"
  else
    fail "Fuseau horaire incorrect" "attendu $TIMEZONE, obtenu ${current_tz:-inconnu}"
  fi
fi

# 7.4 Service timesyncd enabled / active
if out=$(systemctl is-enabled systemd-timesyncd 2>&1); then
  ok "systemd-timesyncd activé au démarrage ($out)"
else
  fail "systemd-timesyncd non activé au démarrage" "$out"
fi
if systemctl is-active --quiet systemd-timesyncd; then
  ok "systemd-timesyncd en cours d'exécution"
else
  fail "systemd-timesyncd inactif" "$(systemctl status systemd-timesyncd --no-pager -n 5 2>&1 | tail -n 5)"
fi

# 7.5 NTP activé dans timedatectl
if [[ "$(timedatectl show -p NTP --value 2>/dev/null)" == "yes" ]]; then
  ok "NTP activé (timedatectl set-ntp)"
else
  fail "NTP désactivé dans timedatectl" "$(timedatectl status 2>&1 | grep -i 'NTP service')"
fi

# 7.6 Connectivité vers le serveur de temps
TARGET="${NTP_SERVER:-ntp.ubuntu.com}"
if out=$(ping -c 2 -W 2 "$TARGET" 2>&1); then
  ok "Serveur de temps $TARGET joignable"
else
  fail "Serveur de temps $TARGET injoignable au ping (ICMP parfois filtré)" "$(echo "$out" | tail -n 2)"
fi

# 7.7 Serveur configuré
if [[ -n "$NTP_SERVER" ]]; then
  cfg=$(timedatectl show-timesync -p SystemNTPServers --value 2>&1 || true)
  if [[ "$cfg" == *"$NTP_SERVER"* ]]; then
    ok "Serveur NTP configuré : $cfg"
  else
    fail "Serveur NTP $NTP_SERVER non pris en compte" "SystemNTPServers = ${cfg:-vide}"
  fi
fi

# 7.8 Synchronisation
if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]]; then
  ok "Horloge synchronisée (System clock synchronized: yes)"
  timedatectl timesync-status 2>/dev/null | grep -E "Server|Stratum|Offset" || true
else
  fail "Horloge non synchronisée après ${SYNC_TIMEOUT}s" \
       "$(timedatectl timesync-status 2>&1 | head -n 6) | logs : journalctl -u systemd-timesyncd -n 10"
fi

# 7.9 Réception effective de paquets NTP depuis le serveur
if [[ -n "$NTP_SERVER" ]]; then
  # a) Preuve réseau : une réponse UDP/123 du serveur a été vue
  [[ -n "$TCPDUMP_PID" ]] && { wait "$TCPDUMP_PID" 2>/dev/null || true; }
  if grep -q "NTP" "$CAPTURE_FILE"; then
    ok "Paquet NTP reçu de $NTP_SERVER (capture tcpdump)"
    grep "NTP" "$CAPTURE_FILE" | head -n 1 | sed 's/^/         ↳ /'
  else
    fail "Aucun paquet NTP reçu de $NTP_SERVER en ${CAPTURE_TIMEOUT}s" \
         "service NTP arrêté sur le serveur ? UDP/123 filtré ? (voir $CAPTURE_FILE)"
  fi

  # b) Preuve côté client : compteur de paquets de timesyncd
  pkt=$(timedatectl timesync-status 2>/dev/null | awk '/Packet count/{print $3}')
  if [[ "${pkt:-0}" -gt 0 ]]; then
    ok "timesyncd a traité $pkt paquet(s) NTP"
  else
    fail "Compteur de paquets NTP à 0" "timesyncd n'a reçu aucune réponse valide"
  fi

  # c) Le serveur qui répond est bien celui configuré
  srv=$(timedatectl timesync-status 2>/dev/null | awk -F': ' '/Server:/{print $2}')
  if [[ "$srv" == *"$NTP_SERVER"* ]]; then
    ok "Serveur utilisé par timesyncd : $srv"
  else
    fail "Serveur utilisé différent de $NTP_SERVER" "obtenu : ${srv:-aucun}"
  fi
fi
rm -f "${CAPTURE_FILE:-}"

# ---------- Bilan ----------
echo "-----------------------------------------"
if [[ $ERRORS -eq 0 ]]; then
  echo -e "\e[32mTous les contrôles sont passés.\e[0m"
else
  echo -e "\e[31m$ERRORS contrôle(s) en échec.\e[0m"
fi
echo; timedatectl status
exit $ERRORS
