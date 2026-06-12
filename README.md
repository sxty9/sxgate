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

## Phase B — Tunnel aufsetzen (ein Befehl)
Repo klonen und `setup` laufen lassen — repo-lokal wie `./holistic`, **kein separates `install.sh`**:

```bash
git clone https://github.com/sxty9/sxgate.git ~/sxgate && cd ~/sxgate
sudo ./sxgate setup                  # installiert cloudflared, Cloudflare-Login (Browser-URL),
                                     # legt den Tunnel an, scaffoldet config.yml + systemd-Service
sudo ./sxgate zone henrysoase.org    # die verwaltete DNS-Zone (entkoppelt von setup)
```

`setup` ist idempotent — vorhandenes cloudflared / Tunnel / systemd-Service werden erkannt und übersprungen. Der einzige interaktive Schritt ist der `cloudflared tunnel login` (Browser-URL); bei vorhandenem `cert.pem` entfällt er.

**Wichtig:** Die `~/.cloudflared/<TUNNEL-ID>.json` enthält Credentials — **niemals committen**. `.gitignore` deckt das ab.

## Phase C — Webservice anbinden
Mit dem `sxgate` CLI:

```bash
sudo ./sxgate service add blog http://localhost:2368
sudo ./sxgate route   add blog.henrysoase.org blog
sudo ./sxgate route   ls
```

Das CLI legt den DNS-Record an (`cloudflared tunnel route dns …`), schreibt die Ingress-Regel atomisch in `/etc/cloudflared/config.yml` und reloaded den Tunnel. Details: [docs/cli.md](docs/cli.md).

## Troubleshooting
- `cloudflared tunnel list` — zeigt aktive Tunnels
- `journalctl -u cloudflared -f` — Live-Logs
- `cloudflared tunnel info sxgate` — Verbindungs-Status

## CLI

`sxgate` managt Subdomain↔Service-Mappings zentral. Konzept: **Services** sind benannte Targets (Name → URL), **Routes** binden Hostnames an Services. Die Live-Config bleibt `/etc/cloudflared/config.yml` — `sxgate` editiert sie direkt mit Backups + Validierung + Rollback.

```bash
sudo ./sxgate setup                          # einmalig: cloudflared + Tunnel + systemd-Service
sudo ./sxgate zone henrysoase.org            # verwaltete DNS-Zone
sudo ./sxgate service add blog http://localhost:2368
sudo ./sxgate route   add blog.henrysoase.org blog
sudo ./sxgate route   ls
sudo ./sxgate status
```

Tests laufen offline (mocken `cloudflared` und `systemctl`):

```bash
bash tests/run.sh
```

Vollständige Referenz: [docs/cli.md](docs/cli.md).

## Mehr
Siehe [docs/architecture.md](docs/architecture.md) für Glossar und Konzepte (DNS, Tunnel, Reverse Proxy, CGNAT).
