# osTicket FREE – Proxmox LXC Installer

## One-Liner (auf dem Proxmox-Host als root ausführen)

```bash
bash -c "$(wget -qO- https://raw.githubusercontent.com/yodaeichen/osticket/install.sh)"
```

> Ersetze `yodaeichen` durch dein GitHub-Repo, sobald du das Script dort abgelegt hast.

## Was wird installiert?

| Komponente | Version |
|---|---|
| Debian | 12 (Bookworm) |
| PHP | 8.2 (sury.org) |
| Apache | 2.4 |
| MariaDB | 10.x |
| osTicket | v1.18.3 |

## Nach dem Installer

1. Öffne `http://<CT-IP>/setup/` im Browser
2. Folge dem Web-Installer (DB-Daten aus dem Dialog verwenden)
3. **Wichtig nach Setup:**
   ```bash
   pct exec <CTID> -- rm -rf /var/www/osticket/upload/setup
   pct exec <CTID> -- chmod 0644 /var/www/osticket/upload/include/ost-config.php
   ```
