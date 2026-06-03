# sxgate

Schlanker "Linker" zwischen einer Cloudflare-Domain und einem Webservice der zuhause auf einem Ubuntu-Server (24/7) läuft. Verbindung via **Cloudflare Tunnel** (`cloudflared`) — keine offenen Router-Ports, dynamische IP / CGNAT egal, HTTPS + DDoS-Schutz inklusive, gratis.

```
 Browser ──HTTPS──▶ Cloudflare-Edge ──Tunnel──▶ cloudflared (Server) ──HTTP──▶ Webservice (z.B. localhost:8080)
```

Dieses Repo enthält bewusst **keinen Webservice-Code** — nur die Tunnel-Config, Doku und das Runbook. Der eigentliche Service wird separat deployed.

## Status
- [x] Phase A — Repo-Scaffold (Configs als Platzhalter)
- [ ] Phase B — Domain bei Cloudflare gekauft + Tunnel erstellt
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

# 4. DNS-Record für deine (Sub-)Domain anlegen
cloudflared tunnel route dns sxgate sxgate.<DEINE-DOMAIN>

# 5. Config schreiben — siehe cloudflared/config.yml.example
sudo cp cloudflared/config.yml.example /etc/cloudflared/config.yml
sudo nano /etc/cloudflared/config.yml   # Platzhalter ausfüllen

# 6. Als systemd-Service installieren (startet bei Boot)
sudo cloudflared service install
sudo systemctl status cloudflared
```

**Wichtig:** Die `~/.cloudflared/<TUNNEL-ID>.json` enthält Credentials — **niemals committen**. `.gitignore` deckt das ab.

## Phase C — Webservice anbinden
In `/etc/cloudflared/config.yml` den `ingress`-Block auf den lokalen Port des Webservices zeigen lassen (z.B. `http://localhost:8080`). Dann `sudo systemctl restart cloudflared`.

## Troubleshooting
- `cloudflared tunnel list` — zeigt aktive Tunnels
- `journalctl -u cloudflared -f` — Live-Logs
- `cloudflared tunnel info sxgate` — Verbindungs-Status

## Mehr
Siehe [docs/architecture.md](docs/architecture.md) für Glossar und Konzepte (DNS, Tunnel, Reverse Proxy, CGNAT).
