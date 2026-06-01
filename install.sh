#!/usr/bin/env bash
# ==============================================================================
#  osTicket v1.18.x – Proxmox LXC Installer
#  Inspired by community-scripts/ProxmoxVE helper style
# ==============================================================================

set -euo pipefail

# ─── Color / UI ───────────────────────────────────────────────────────────────
YW=$(echo "\033[33m"); GN=$(echo "\033[1;92m"); RD=$(echo "\033[01;31m")
BL=$(echo "\033[36m"); CL=$(echo "\033[m"); CM="${GN}✔${CL}"; CROSS="${RD}✖${CL}"
INFO="${BL}ℹ${CL}"; HOLD="-"

msg_info()  { echo -e "${INFO} ${1}"; }
msg_ok()    { echo -e "${CM} ${1}"; }
msg_error() { echo -e "${CROSS} ${RD}${1}${CL}"; exit 1; }

header_info() {
cat << "EOF"
   ___  ______________  __        __  
  / _ \/ __/_  __/ / / / /  ___  / /_ 
 / ___/\ \  / / / / /__/ /__/ _ \/ __/ 
/_/  /___/ /_/ /____/____/\___/\__/  

EOF
echo -e "${GN}osTicket FREE – LXC Installer${CL}\n"
}

# ─── Preflight ────────────────────────────────────────────────────────────────
if [[ "$(id -u)" != "0" ]]; then
  msg_error "Bitte als root auf dem Proxmox-Host ausführen."
fi
command -v pct &>/dev/null || msg_error "pct nicht gefunden – kein Proxmox-Host?"
command -v whiptail &>/dev/null || apt-get install -y whiptail &>/dev/null

# ─── Defaults ─────────────────────────────────────────────────────────────────
DEF_CTID=$(pvesh get /cluster/nextid 2>/dev/null || echo 200)
DEF_HOSTNAME="osticket"
DEF_IP="172.15.15.$(shuf -i 10-250 -n1)/16"
DEF_GW="172.15.15.1"
DEF_DISK=8
DEF_RAM=1024
DEF_CORES=2
DEF_STORAGE="BACKUP_NAS"
DEF_BRIDGE="vmbr0"
DEF_OSTICKET_VER="v1.18.3"
DEF_OSTICKET_URL="https://github.com/osTicket/osTicket/releases/download/${DEF_OSTICKET_VER}/osTicket-${DEF_OSTICKET_VER}.zip"
DEF_TEMPLATE_STORAGE="BACKUP_NAS"
TEMPLATE="debian-12-standard_12.7-1_amd64.tar.zst"

header_info

# ─── Whiptail Dialog ──────────────────────────────────────────────────────────
CTID=$(whiptail --title "osTicket LXC" --inputbox \
  "Container ID:" 8 40 "$DEF_CTID" 3>&1 1>&2 2>&3) || exit 0

HOSTNAME=$(whiptail --title "osTicket LXC" --inputbox \
  "Hostname:" 8 40 "$DEF_HOSTNAME" 3>&1 1>&2 2>&3) || exit 0

IP=$(whiptail --title "osTicket LXC" --inputbox \
  "IP-Adresse (CIDR):" 8 40 "$DEF_IP" 3>&1 1>&2 2>&3) || exit 0

GW=$(whiptail --title "osTicket LXC" --inputbox \
  "Gateway:" 8 40 "$DEF_GW" 3>&1 1>&2 2>&3) || exit 0

DISK=$(whiptail --title "osTicket LXC" --inputbox \
  "Disk-Größe (GB):" 8 40 "$DEF_DISK" 3>&1 1>&2 2>&3) || exit 0

RAM=$(whiptail --title "osTicket LXC" --inputbox \
  "RAM (MB):" 8 40 "$DEF_RAM" 3>&1 1>&2 2>&3) || exit 0

CORES=$(whiptail --title "osTicket LXC" --inputbox \
  "CPU-Kerne:" 8 40 "$DEF_CORES" 3>&1 1>&2 2>&3) || exit 0

STORAGE=$(whiptail --title "osTicket LXC" --inputbox \
  "Proxmox Storage (für CT-Disk):" 8 40 "$DEF_STORAGE" 3>&1 1>&2 2>&3) || exit 0

BRIDGE=$(whiptail --title "osTicket LXC" --inputbox \
  "Netzwerk-Bridge:" 8 40 "$DEF_BRIDGE" 3>&1 1>&2 2>&3) || exit 0

# Passwort setzen
ROOT_PW=$(whiptail --title "osTicket LXC" --passwordbox \
  "Root-Passwort für den Container:" 8 40 3>&1 1>&2 2>&3) || exit 0

# DB-Zugangsdaten
DB_PASS=$(whiptail --title "osTicket LXC" --passwordbox \
  "MySQL-Passwort für osticket-User:" 8 40 3>&1 1>&2 2>&3) || exit 0

# Bestätigung
whiptail --title "Zusammenfassung" --yesno \
"CT ${CTID}: ${HOSTNAME}
IP:      ${IP}
Gateway: ${GW}
Disk:    ${DISK} GB  |  RAM: ${RAM} MB  |  Cores: ${CORES}
Storage: ${STORAGE}
Bridge:  ${BRIDGE}

Fortfahren?" 18 55 || exit 0

# ─── Template herunterladen (falls nicht vorhanden) ───────────────────────────
msg_info "Prüfe Debian-Template ..."
TEMPLATE_PATH=$(pvesm path "${DEF_TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" 2>/dev/null || true)
if [[ -z "$TEMPLATE_PATH" || ! -f "$TEMPLATE_PATH" ]]; then
  msg_info "Template wird heruntergeladen ..."
  pveam update &>/dev/null
  pveam download "${DEF_TEMPLATE_STORAGE}" "$TEMPLATE" &>/dev/null \
    || msg_error "Template-Download fehlgeschlagen. Storage-Name korrekt?"
fi
msg_ok "Template bereit"

# ─── LXC erstellen ────────────────────────────────────────────────────────────
msg_info "Erstelle LXC CT${CTID} ..."
pct create "$CTID" "${DEF_TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
  --hostname "$HOSTNAME" \
  --cores "$CORES" \
  --memory "$RAM" \
  --swap 512 \
  --rootfs "${STORAGE}:${DISK}" \
  --net0 "name=eth0,bridge=${BRIDGE},ip=${IP},gw=${GW}" \
  --ostype debian \
  --password "$ROOT_PW" \
  --unprivileged 1 \
  --features nesting=1 \
  --start 0
msg_ok "CT${CTID} erstellt"

# ─── CT starten ───────────────────────────────────────────────────────────────
msg_info "Starte CT${CTID} ..."
pct start "$CTID"
sleep 5
msg_ok "CT gestartet"

# ─── Installations-Payload via pct exec ───────────────────────────────────────
msg_info "Installiere Abhängigkeiten (LAMP + PHP 8.2) ..."
pct exec "$CTID" -- bash -c "
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Grundpakete & Repos
apt-get update -qq
apt-get install -y -qq curl wget unzip gnupg2 lsb-release ca-certificates apt-transport-https software-properties-common

# PHP 8.2 via sury.org
curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /usr/share/keyrings/php-archive-keyring.gpg
echo 'deb [signed-by=/usr/share/keyrings/php-archive-keyring.gpg] https://packages.sury.org/php/ bookworm main' \
  > /etc/apt/sources.list.d/php.list
apt-get update -qq

# LAMP
apt-get install -y -qq \
  apache2 \
  mariadb-server mariadb-client \
  php8.2 php8.2-cli php8.2-fpm \
  php8.2-mysql php8.2-gd php8.2-imap php8.2-intl \
  php8.2-mbstring php8.2-xml php8.2-zip php8.2-curl \
  php8.2-apcu php8.2-bcmath \
  libapache2-mod-php8.2

# PHP config
sed -i 's/^upload_max_filesize.*/upload_max_filesize = 20M/' /etc/php/8.2/apache2/php.ini
sed -i 's/^post_max_size.*/post_max_size = 25M/'            /etc/php/8.2/apache2/php.ini
sed -i 's/^;date.timezone.*/date.timezone = Europe\/Berlin/' /etc/php/8.2/apache2/php.ini
" 2>&1 | grep -v "^debconf\|^Selecting\|^(Reading\|^Unpacking\|^Setting up\|^Processing" || true
msg_ok "LAMP + PHP 8.2 installiert"

# ─── Datenbank anlegen ────────────────────────────────────────────────────────
msg_info "Konfiguriere MariaDB ..."
pct exec "$CTID" -- bash -c "
set -euo pipefail
systemctl enable --now mariadb &>/dev/null
mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS osticket CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'osticket'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON osticket.* TO 'osticket'@'localhost';
FLUSH PRIVILEGES;
SQL
"
msg_ok "Datenbank 'osticket' angelegt"

# ─── osTicket herunterladen & entpacken ───────────────────────────────────────
msg_info "Lade osTicket ${DEF_OSTICKET_VER} herunter ..."
pct exec "$CTID" -- bash -c "
set -euo pipefail
cd /tmp
wget -q '${DEF_OSTICKET_URL}' -O osticket.zip
unzip -q osticket.zip -d /var/www/osticket
cp /var/www/osticket/upload/include/ost-sampleconfig.php \
   /var/www/osticket/upload/include/ost-config.php
chmod 0666 /var/www/osticket/upload/include/ost-config.php
chown -R www-data:www-data /var/www/osticket
"
msg_ok "osTicket entpackt"

# ─── Apache VHost ─────────────────────────────────────────────────────────────
msg_info "Konfiguriere Apache VHost ..."
pct exec "$CTID" -- bash -c "
cat > /etc/apache2/sites-available/osticket.conf << 'VHOST'
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot /var/www/osticket/upload
    <Directory /var/www/osticket/upload>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog \${APACHE_LOG_DIR}/osticket_error.log
    CustomLog \${APACHE_LOG_DIR}/osticket_access.log combined
</VirtualHost>
VHOST

a2dissite 000-default.conf &>/dev/null
a2ensite osticket.conf &>/dev/null
a2enmod rewrite &>/dev/null
systemctl restart apache2
"
msg_ok "Apache konfiguriert"

# ─── Cron für osTicket ────────────────────────────────────────────────────────
pct exec "$CTID" -- bash -c "
echo '*/5 * * * * www-data /usr/bin/php /var/www/osticket/upload/api/cron.php' \
  > /etc/cron.d/osticket
"

# ─── Firewall-Info ────────────────────────────────────────────────────────────
CT_IP=$(echo "$IP" | cut -d'/' -f1)

echo ""
msg_ok "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
msg_ok " osTicket ${DEF_OSTICKET_VER} Installation abgeschlossen!"
msg_ok "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  ${YW}Web-Installer:${CL}  http://${CT_IP}/setup/"
echo -e "  ${YW}DB-Name:${CL}        osticket"
echo -e "  ${YW}DB-User:${CL}        osticket"
echo -e "  ${YW}DB-Host:${CL}        localhost"
echo -e ""
echo -e "  ${RD}Nach dem Web-Setup unbedingt ausführen:${CL}"
echo -e "  pct exec ${CTID} -- rm -rf /var/www/osticket/upload/setup"
echo -e "  pct exec ${CTID} -- chmod 0644 /var/www/osticket/upload/include/ost-config.php"
echo -e ""
