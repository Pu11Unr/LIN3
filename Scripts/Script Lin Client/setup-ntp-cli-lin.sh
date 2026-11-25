#!/usr/bin/env bash
# =============================================================================
# setup-ntp-cli-lin.sh
# Projet  : LIN3 - déploiement NTP
# Cible   : client Linux Ubuntu Server (ntp-cli-lin)
# Rôle    : met à jour le système, fixe le fuseau horaire, réécrit entièrement
#           chrony.conf (sauvegarde .bak conservée) avec UNIQUEMENT les
#           serveurs NTP internes, puis vérifie le résultat (y compris la
#           réception effective de paquets NTP).
#
# Usage   : ./setup-ntp-cli-lin.sh   (se relance automatiquement en root)
# Le réseau n'est pas modifié par ce script.
# =============================================================================
set -euo pipefail

# ========= Variables à adapter =========
TIMEZONE="Europe/Zurich"
NTP_PRIMARY="10.0.2.10"
NTP_FALLBACK="10.0.2.11"
SYNC_TIMEOUT=20                 # secondes d'attente max pour la synchronisation
CAPTURE_TIMEOUT=$SYNC_TIMEOUT   # durée max de la capture des paquets NTP
# ========================================

CONF="/etc/chrony/chrony.conf"
SRV=("$NTP_PRIMARY" "$NTP_FALLBACK")

# ---------- Auto-élévation en root ----------
if [[ $EUID -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    echo "Élévation des privilèges via sudo..."
    exec sudo bash "$0" "$@"
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

# ---------- 1. Mise à jour et paquets ----------
step "1. Mise à jour du système et paquets"
apt-get update -y
apt-get -y upgrade
apt-get install -y \
  chrony \
  iputils-ping \
  iproute2 \
  bind9-dnsutils \
  traceroute \
  net-tools \
  curl \
  ca-certificates \
  vim \
  tcpdump

# ---------- 2. Retirer les clients NTP concurrents ----------
step "2. Suppression des clients NTP concurrents"
for svc in ntp ntpsec; do
  if dpkg -s "$svc" >/dev/null 2>&1; then
    systemctl disable --now "$svc" 2>/dev/null || true
    apt-get purge -y "$svc"
    echo "Paquet $svc supprimé"
  fi
done
if systemctl list-unit-files systemd-timesyncd.service >/dev/null 2>&1; then
  systemctl disable --now systemd-timesyncd 2>/dev/null || true
  systemctl mask systemd-timesyncd 2>/dev/null || true
  echo "systemd-timesyncd désactivé et masqué"
fi

# ---------- 3. Fuseau horaire ----------
step "3. Fuseau horaire"
timedatectl set-timezone "$TIMEZONE"
echo "Fuseau horaire défini : $TIMEZONE"

# ---------- 4. Configuration de chrony ----------
step "4. Configuration de chrony"
BAK="$CONF.bak.$(date +%Y%m%d%H%M%S)"
cp -a "$CONF" "$BAK"
echo "Sauvegarde : $BAK"

cat > "$CONF" <<EOF
# Configuration chrony - générée par setup-ntp-cli-lin.sh (LIN3)
# Serveurs NTP internes uniquement

server ${NTP_PRIMARY}  iburst prefer minpoll 4 maxpoll 6
server ${NTP_FALLBACK} iburst minpoll 4 maxpoll 6

keyfile /etc/chrony/chrony.keys
driftfile /var/lib/chrony/chrony.drift
ntsdumpdir /var/lib/chrony
logdir /var/log/chrony
maxupdateskew 100.0
rtcsync
makestep 1 3
leapsectz right/UTC
EOF
chmod 644 "$CONF"
echo "Configuration réécrite : $CONF (serveurs : ${SRV[*]})"

# ---------- 5. Activation ----------
step "5. Activation du service"
systemctl enable chrony

# Capture : 1 réponse NTP (UDP/123) d'un des serveurs, lancée AVANT le redémarrage
CAPTURE_FILE=$(mktemp)
HOSTS_FILTER=""
for s in "${SRV[@]}"; do HOSTS_FILTER+="${HOSTS_FILTER:+ or }src host $s"; done
timeout "$CAPTURE_TIMEOUT" tcpdump -n -l -i any -c 1 \
  "udp src port 123 and ($HOSTS_FILTER)" >"$CAPTURE_FILE" 2>&1 &
TCPDUMP_PID=$!
sleep 1

systemctl restart chrony
sleep 3
chronyc burst 4/4 >/dev/null || true
sleep 3
chronyc makestep || true

echo "Attente de la synchronisation (max ${SYNC_TIMEOUT}s)..."
for ((i=0; i<SYNC_TIMEOUT; i+=2)); do
  [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]] && break
  sleep 2
done

# ---------- 6. Vérifications ----------
step "6. Vérifications"

# 6.1 Outils
for cmd in timedatectl chronyc ping ip dig curl tcpdump; do
  if command -v "$cmd" >/dev/null 2>&1; then ok "Commande $cmd disponible"
  else fail "Commande $cmd manquante" "installer le paquet qui fournit $cmd"; fi
done
dpkg -s chrony >/dev/null 2>&1 && ok "Paquet chrony installé" \
  || fail "Paquet chrony manquant" "apt-get install -y chrony"

# 6.2 Aucun client NTP concurrent actif
conflict=""
for svc in ntp ntpsec; do dpkg -s "$svc" >/dev/null 2>&1 && conflict+="$svc "; done
systemctl is-active --quiet systemd-timesyncd 2>/dev/null && conflict+="systemd-timesyncd "
[[ -z "$conflict" ]] && ok "Aucun client NTP concurrent actif" \
  || fail "Client(s) NTP concurrent(s) présent(s)" "$conflict"

# 6.3 Fuseau horaire
current_tz=$(timedatectl show -p Timezone --value 2>/dev/null)
[[ "$current_tz" == "$TIMEZONE" ]] && ok "Fuseau horaire : $current_tz" \
  || fail "Fuseau horaire incorrect" "attendu $TIMEZONE, obtenu ${current_tz:-inconnu}"

# 6.4 Service chrony
if out=$(systemctl is-enabled chrony 2>&1); then ok "chrony activé au démarrage ($out)"
else fail "chrony non activé au démarrage" "$out"; fi
if systemctl is-active --quiet chrony; then ok "chrony en cours d'exécution"
else fail "chrony inactif" "$(systemctl status chrony --no-pager -n 5 2>&1 | tail -n 5)"; fi

# 6.5 Seuls nos serveurs sont déclarés
extra=$(grep -E '^[[:space:]]*(pool|peer|sourcedir|confdir)[[:space:]]' "$CONF" || true)
other=$(grep -E '^[[:space:]]*server[[:space:]]' "$CONF" | awk '{print $2}' \
        | grep -vxF -e "$NTP_PRIMARY" -e "$NTP_FALLBACK" || true)
if [[ -z "$extra" && -z "$other" ]]; then
  ok "chrony.conf ne déclare que les serveurs internes"
else
  fail "Source(s) ou répertoire(s) inattendu(s) dans $CONF" "$extra $other"
fi

# 6.6 Connectivité vers chaque serveur
for s in "${SRV[@]}"; do
  if out=$(ping -c 2 -W 2 "$s" 2>&1); then ok "Serveur de temps $s joignable"
  else fail "Serveur de temps $s injoignable au ping (ICMP parfois filtré)" "$(echo "$out" | tail -n 2)"; fi
done

# 6.7 Sources chrony = exactement nos serveurs
got=$(chronyc -c sources 2>/dev/null | awk -F, '{print $3}' | sort | tr '\n' ' ' || true)
want=$(printf '%s\n' "${SRV[@]}" | sort | tr '\n' ' ')
if [[ "$got" == "$want" ]]; then ok "Sources chrony : $got"
else fail "Sources chrony différentes de celles configurées" "attendu : $want| obtenu : ${got:-vide}"; fi

# 6.8 Synchronisation
if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]]; then
  ok "Horloge synchronisée (System clock synchronized: yes)"
  chronyc tracking 2>/dev/null | grep -E "Reference ID|Stratum|System time|Leap status" || true
else
  fail "Horloge non synchronisée après ${SYNC_TIMEOUT}s" \
       "$(chronyc tracking 2>&1 | head -n 6) | logs : journalctl -u chrony -n 10"
fi

# 6.9 Réception effective de paquets NTP
wait "$TCPDUMP_PID" 2>/dev/null || true
if grep -q "NTP" "$CAPTURE_FILE"; then
  ok "Paquet NTP reçu d'un serveur configuré (capture tcpdump)"
  grep "NTP" "$CAPTURE_FILE" | head -n 1 | sed 's/^/         ↳ /'
else
  fail "Aucun paquet NTP reçu de ${SRV[*]} en ${CAPTURE_TIMEOUT}s" \
       "service NTP arrêté sur le serveur ? UDP/123 filtré ? (voir $CAPTURE_FILE)"
fi

for s in "${SRV[@]}"; do
  reach=$(chronyc -c sources 2>/dev/null | awk -F, -v s="$s" '$3==s{print $6}')
  if [[ -n "$reach" && "$reach" != "0" ]]; then ok "chrony a reçu des réponses de $s (Reach = $reach)"
  else fail "Reach à 0 pour $s" "chrony n'a reçu aucune réponse valide"; fi
done

sel=$(chronyc -c sources 2>/dev/null | awk -F, '$2=="*"{print $3}')
if [[ -n "$sel" && " ${SRV[*]} " == *" $sel "* ]]; then ok "Serveur sélectionné par chrony : $sel"
else fail "Aucun serveur configuré n'est sélectionné par chrony" "obtenu : ${sel:-aucun}"; fi
rm -f "${CAPTURE_FILE:-}"

# ---------- Bilan ----------
echo "-----------------------------------------"
if [[ $ERRORS -eq 0 ]]; then echo -e "\e[32mTous les contrôles sont passés.\e[0m"
else echo -e "\e[31m$ERRORS contrôle(s) en échec.\e[0m"; fi
echo; chronyc sources -v; chronyc tracking
echo; timedatectl status
exit $ERRORS
