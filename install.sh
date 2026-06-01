#!/usr/bin/env bash
# ==============================================================================
#  osTicket v1.18.x – Proxmox LXC Installer
#  Style: community-scripts/ProxmoxVE helpers
# ==============================================================================

# Kein set -euo pipefail hier — wir fangen Fehler manuell ab
# damit Whiptail-Dialoge nicht den Exit-Code 0 erfordern

# ─── Farben ───────────────────────────────────────────────────────────────────
YW="\033[33m"; GN="\033[1;92m"; RD="\033[01;31m"
BL="\033[36m"; CL="\033[m"
CM="${GN}✔${CL}"; CROSS="${RD}✖${CL}"; INFO="${BL}ℹ${CL}"

msg_info()  { echo -e "  ${INFO}  ${1}"; }
msg_ok()    { echo -e "  ${CM}  ${1}"; }
msg_error() { echo -e "  ${CROSS}  ${RD}${1}${CL}"; exit 1; }

header_info() {
  clear
  cat << "EOF"
                 _____ _      _        _   
                |_   _(_) ___| | _____| |_ 
                  | | | |/ __| |/ / _ \ __|
                  | | | | (__|   <  __/ |_ 
                  |_| |_|\___|_|\_\___|\__|

           osTicket FREE – Proxmox LXC Installer
EOF
  echo ""
}

# ─── Preflight ────────────────────────────────────────────────────────────────
[[ "$(id -u)" != "0" ]] && msg_error "Bitte als root auf dem Proxmox-Host ausführen."
command -v pct    &>/dev/null || msg_error "pct nicht gefunden – kein Proxmox-Host?"
command -v pvesm  &>/dev/null || msg_error "pvesm nicht gefunden – kein Proxmox-Host?"

# whiptail sicherstellen
if ! command -v whiptail &>/dev/null; then
  echo "Installiere whiptail..."
  apt-get install -y whiptail &>/dev/null
fi

header_info

# ─── Defaults ─────────────────────────────────────────────────────────────────
DEF_CTID=$(pvesh get /cluster/nextid 2>/dev/null || echo "200")
DEF_HOSTNAME="osticket"
DEF_IP="172.15.15.20/16"
DEF_GW="172.15.15.1"
DEF_DISK="8"
DEF_RAM="1024"
DEF_CORES="2"
DEF_CT_STORAGE="BACKUP_NAS"
DEF_TMPL_STORAGE="BACKUP_NAS"
DEF_BRIDGE="vmbr0"
OSTICKET_VER="v1.18.3"
OSTICKET_URL="https://github.com/osTicket/osTicket/releases/download/${OSTICKET_VER}/osTicket-${OSTICKET_VER}.zip"
TEMPLATE="debian-12-standard_12.7-1_amd64.tar.zst"

# ─── Hilfsfunktion: whiptail mit Fehlerbehandlung ─────────────────────────────
wt_input() {
  # wt_input <title> <prompt> <default>  -> gibt Eingabe zurück
  local result
  result=$(whiptail --backtitle "osTicket LXC Installer" \
    --title "$1" --inputbox "$2" 10 52 "$3" 3>&1 1>&2 2>&3)
  local rc=$?
  [[ $rc -ne 0 ]] && { echo "Abgebrochen." ; exit 0; }
  echo "$result"
}

wt_pw() {
  # wt_pw <title> <prompt>  -> gibt Passwort zurück
  local result
  result=$(whiptail --backtitle "osTicket LXC Installer" \
    --title "$1" --passwordbox "$2" 10 52 3>&1 1>&2 2>&3)
  local rc=$?
  [[ $rc -ne 0 ]] && { echo "Abgebrochen."; exit 0; }
  echo "$result"
}

# ─── Dialoge ──────────────────────────────────────────────────────────────────
CTID=$(wt_input        "Container ID"        "Container ID:"                    "$DEF_CTID")
HOSTNAME=$(wt_input    "Hostname"            "Hostname des LXC:"                "$DEF_HOSTNAME")
IP=$(wt_input          "Netzwerk"            "IP-Adresse (CIDR):"               "$DEF_IP")
GW=$(wt_input          "Netzwerk"            "Gateway:"                         "$DEF_GW")
BRIDGE=$(wt_input      "Netzwerk"            "Netzwerk-Bridge:"                 "$DEF_BRIDGE")
DISK=$(wt_input        "Ressourcen"          "Disk-Größe (GB):"                 "$DEF_DISK")
RAM=$(wt_input         "Ressourcen"          "RAM (MB):"                        "$DEF_RAM")
CORES=$(wt_input       "Ressourcen"          "CPU-Kerne:"                       "$DEF_CORES")
CT_STORAGE=$(wt_input  "Storage"             "Storage für CT-Disk:"             "$DEF_CT_STORAGE")
TMPL_STORAGE=$(wt_input "Storage"            "Storage für Templates:"           "$DEF_TMPL_STORAGE")
ROOT_PW=$(wt_pw        "Passwörter"          "Root-Passwort für den Container:")
DB_PASS=$(wt_pw        "Passwörter"          "MySQL-Passwort für osticket-User:")

# Bestätigung
CT_IP="${IP%%/*}"
whiptail --backtitle "osTicket LXC Installer" --title "Zusammenfassung" --yesno \
"CT ${CTID}: ${HOSTNAME}
─────────────────────────────
IP:        ${IP}
Gateway:   ${GW}
Bridge:    ${BRIDGE}
─────────────────────────────
Disk:      ${DISK} GB
RAM:       ${RAM} MB
Cores:     ${CORES}
CT-Disk:   ${CT_STORAGE}
Template:  ${TMPL_STORAGE}
─────────────────────────────
osTicket:  ${OSTICKET_VER}

Jetzt installieren?" 22 52
[[ $? -ne 0 ]] && { echo "Abgebrochen."; exit 0; }

echo ""
msg_info "Starte Installation ..."

# ─── Template prüfen / herunterladen ─────────────────────────────────────────
msg_info "Prüfe Debian-12-Template ..."
TMPL_FILE=$(pvesm path "${TMPL_STORAGE}:vztmpl/${TEMPLATE}" 2>/dev/null || true)
if [[ -z "$TMPL_FILE" || ! -f "$TMPL_FILE" ]]; then
  msg_info "Lade Template herunter (${TEMPLATE}) ..."
  pveam update &>/dev/null || true
  pveam download "$TMPL_STORAGE" "$TEMPLATE" \
    || msg_error "Template-Download fehlgeschlagen. Storage '${TMPL_STORAGE}' korrekt?"
  msg_ok "Template heruntergeladen"
else
  msg_ok "Template bereits vorhanden"
fi

# ─── LXC erstellen ────────────────────────────────────────────────────────────
msg_info "Erstelle LXC CT${CTID} ..."
pct create "$CTID" "${TMPL_STORAGE}:vztmpl/${TEMPLATE}" \
  --hostname  "$HOSTNAME" \
  --cores     "$CORES" \
  --memory    "$RAM" \
  --swap      512 \
  --rootfs    "${CT_STORAGE}:${DISK}" \
  --net0      "name=eth0,bridge=${BRIDGE},ip=${IP},gw=${GW}" \
  --ostype    debian \
  --password  "$ROOT_PW" \
  --unprivileged 1 \
  --features  nesting=1 \
  --onboot    1 \
  --start     0 \
  || msg_error "pct create fehlgeschlagen."
msg_ok "CT${CTID} erstellt"

# ─── LXC starten ─────────────────────────────────────────────────────────────
msg_info "Starte CT${CTID} ..."
pct start "$CTID" || msg_error "pct start fehlgeschlagen."
sleep 8
msg_ok "CT${CTID} gestartet"

# ─── Funktion: Befehl im CT ausführen ─────────────────────────────────────────
ct() { pct exec "$CTID" -- bash -c "$1"; }

# ─── System-Update & Basis-Pakete ─────────────────────────────────────────────
msg_info "System-Update & Basis-Pakete ..."
ct "export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl wget unzip gnupg2 lsb-release \
      ca-certificates apt-transport-https software-properties-common 2>&1 | tail -1"
msg_ok "Basis-Pakete installiert"

# ─── PHP 8.2 Repo ─────────────────────────────────────────────────────────────
msg_info "Füge PHP 8.2 (sury.org) hinzu ..."
ct "curl -fsSL https://packages.sury.org/php/apt.gpg \
      | gpg --dearmor -o /usr/share/keyrings/php-archive-keyring.gpg
    echo 'deb [signed-by=/usr/share/keyrings/php-archive-keyring.gpg] https://packages.sury.org/php/ bookworm main' \
      > /etc/apt/sources.list.d/php.list
    apt-get update -qq"
msg_ok "PHP-Repo hinzugefügt"

# ─── LAMP installieren ────────────────────────────────────────────────────────
msg_info "Installiere Apache, MariaDB, PHP 8.2 (dauert ~1 Min) ..."
ct "export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq \
      apache2 \
      mariadb-server mariadb-client \
      php8.2 php8.2-cli \
      php8.2-mysql php8.2-gd php8.2-imap php8.2-intl \
      php8.2-mbstring php8.2-xml php8.2-zip php8.2-curl \
      php8.2-apcu php8.2-bcmath \
      libapache2-mod-php8.2 2>&1 | tail -1"
msg_ok "LAMP installiert"

# ─── PHP konfigurieren ────────────────────────────────────────────────────────
msg_info "PHP konfigurieren ..."
ct "sed -i 's/^upload_max_filesize.*/upload_max_filesize = 20M/' /etc/php/8.2/apache2/php.ini
    sed -i 's/^post_max_size.*/post_max_size = 25M/'            /etc/php/8.2/apache2/php.ini
    sed -i 's|^;date.timezone.*|date.timezone = Europe/Berlin|' /etc/php/8.2/apache2/php.ini"
msg_ok "PHP konfiguriert"

# ─── MariaDB ──────────────────────────────────────────────────────────────────
msg_info "Konfiguriere MariaDB ..."
ct "systemctl enable --now mariadb &>/dev/null
    mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS osticket CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'osticket'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON osticket.* TO 'osticket'@'localhost';
FLUSH PRIVILEGES;
SQL"
msg_ok "Datenbank 'osticket' angelegt"

# ─── osTicket herunterladen ────────────────────────────────────────────────────
msg_info "Lade osTicket ${OSTICKET_VER} herunter ..."
ct "cd /tmp
    wget -q '${OSTICKET_URL}' -O osticket.zip || { echo 'Download fehlgeschlagen'; exit 1; }
    unzip -q osticket.zip -d /var/www/osticket
    cp /var/www/osticket/upload/include/ost-sampleconfig.php \
       /var/www/osticket/upload/include/ost-config.php
    chmod 0666 /var/www/osticket/upload/include/ost-config.php
    chown -R www-data:www-data /var/www/osticket"
msg_ok "osTicket entpackt nach /var/www/osticket/upload"

# ─── Apache VHost ─────────────────────────────────────────────────────────────
msg_info "Konfiguriere Apache ..."
ct "cat > /etc/apache2/sites-available/osticket.conf << 'VHOST'
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
    systemctl restart apache2"
msg_ok "Apache konfiguriert"

# ─── Cron ─────────────────────────────────────────────────────────────────────
ct "echo '*/5 * * * * www-data /usr/bin/php /var/www/osticket/upload/api/cron.php' \
      > /etc/cron.d/osticket"

# ─── Services aktivieren ──────────────────────────────────────────────────────
ct "systemctl enable apache2 mariadb &>/dev/null"

# ─── Fertig ───────────────────────────────────────────────────────────────────
echo ""
echo -e "  ╔══════════════════════════════════════════════════════╗"
echo -e "  ║       ${GN}osTicket ${OSTICKET_VER} – Installation fertig!${CL}       ║"
echo -e "  ╠══════════════════════════════════════════════════════╣"
echo -e "  ║  ${YW}Web-Installer:${CL}  http://${CT_IP}/setup/              "
echo -e "  ║                                                      "
echo -e "  ║  ${YW}DB-Name:${CL}   osticket                                  "
echo -e "  ║  ${YW}DB-User:${CL}   osticket                                  "
echo -e "  ║  ${YW}DB-Host:${CL}   localhost                                 "
echo -e "  ╠══════════════════════════════════════════════════════╣"
echo -e "  ║  ${RD}Nach dem Web-Setup UNBEDINGT ausführen:${CL}               "
echo -e "  ║  pct exec ${CTID} -- rm -rf /var/www/osticket/upload/setup"
echo -e "  ║  pct exec ${CTID} -- chmod 0644 /var/www/osticket/upload/include/ost-config.php"
echo -e "  ╚══════════════════════════════════════════════════════╝"
echo ""
