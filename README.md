# sxgate

Schlanker "Linker" zwischen einer Cloudflare-Domain und einem Webservice der zuhause auf einem Ubuntu-Server (24/7) läuft. Verbindung via **Cloudflare Tunnel** (`cloudflared`) — keine offenen Router-Ports, dynamische IP / CGNAT egal, HTTPS + DDoS-Schutz inklusive, gratis.

```
 Browser ──HTTPS──▶ Cloudflare-Edge ──Tunnel──▶ cloudflared (Server) ──HTTP──▶ Webservice (z.B. localhost:8080)
```

Dieses Repo enthält bewusst **keinen Webservice-Code** — nur die Tunnel-Config, Doku und das Runbook. Der eigentliche Service wird separat deployed.

## Status
- [x] Phase A — Repo-Scaffold (Configs als Platzhalter)
- [x] Domain: **henrysoase.org** (bei Cloudflare registriert, Zone aktiv)
- [x] CLI: `sxgate` für Subdomain↔Service-Verwaltung (siehe [docs/cli.md](docs/cli.md))
- [ ] Phase B — Tunnel auf Server eingerichtet + DNS-Record gesetzt
- [ ] Phase C — Webservice auf Server läuft + Tunnel zeigt auf den Port

## Phase B — Sobald die Domain bei Cloudflare steht
Auf dem Ubuntu-Server ausführen:

```bash
# 1. cloudflared installieren (Debian/Ubuntu)
sudo mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
  | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' \
  | sudo tee /etc/apt/sources.list.d/cloudflared.list
sudo apt update && sudo apt install -y cloudflared

# 2. Mit Cloudflare-Account verbinden (öffnet Browser-Login)
cloudflared tunnel login

# 3. Tunnel anlegen — liefert eine Tunnel-ID + Credentials-JSON in ~/.cloudflared/
cloudflared tunnel create sxgate

# 4. sxgate installieren — übernimmt ab hier die config.yml und DNS-Records
sudo ./install.sh
sudo sxgate init --zone henrysoase.org

# 5. Als systemd-Service installieren (startet bei Boot)
sudo cloudflared service install
sudo systemctl status cloudflared
```

**Wichtig:** Die `~/.cloudflared/<TUNNEL-ID>.json` enthält Credentials — **niemals committen**. `.gitignore` deckt das ab.

## Phase C — Webservice anbinden
Mit dem `sxgate` CLI:

```bash
sudo sxgate service add blog http://localhost:2368
sudo sxgate route   add blog.henrysoase.org blog
sudo sxgate route   ls
```

Das CLI legt den DNS-Record an (`cloudflared tunnel route dns …`), schreibt die Ingress-Regel atomisch in `/etc/cloudflared/config.yml` und reloaded den Tunnel. Details: [docs/cli.md](docs/cli.md).

## Troubleshooting
- `cloudflared tunnel list` — zeigt aktive Tunnels
- `journalctl -u cloudflared -f` — Live-Logs
- `cloudflared tunnel info sxgate` — Verbindungs-Status

## CLI

`sxgate` managt Subdomain↔Service-Mappings zentral. Konzept: **Services** sind benannte Targets (Name → URL), **Routes** binden Hostnames an Services. Die Live-Config bleibt `/etc/cloudflared/config.yml` — `sxgate` editiert sie direkt mit Backups + Validierung + Rollback.

```bash
sudo sxgate init --zone henrysoase.org      # einmalig
sudo sxgate service add blog http://localhost:2368
sudo sxgate route   add blog.henrysoase.org blog
sudo sxgate route   ls
sudo sxgate status
```

Tests laufen offline (mocken `cloudflared` und `systemctl`):

```bash
bash tests/run.sh
```

Vollständige Referenz: [docs/cli.md](docs/cli.md).

## Mehr
Siehe [docs/architecture.md](docs/architecture.md) für Glossar und Konzepte (DNS, Tunnel, Reverse Proxy, CGNAT).
