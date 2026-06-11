# `sxgate` CLI

Verwaltung von Subdomain↔Service-Routing für einen Cloudflare Tunnel auf einem Ubuntu-Server.

## Mental Model

- **Services** sind benannte Targets (z.B. `blog` → `http://localhost:2368`). Gespeichert in `/etc/sxgate/services`.
- **Routes** sind Hostname→Service-Bindings (z.B. `blog.henrysoase.org` → `blog`). Diese landen direkt im `ingress:` Block von `/etc/cloudflared/config.yml` (mit aufgelöster URL).
- `/etc/cloudflared/config.yml` ist die **Source of Truth** für aktives Routing — `sxgate` editiert sie direkt (atomisch, mit Backup).

## Installation

```bash
git clone <repo> && cd sxgate
sudo ./install.sh
sudo sxgate init --zone henrysoase.org
```

`init` erwartet, dass der Tunnel bereits via `cloudflared tunnel create sxgate` angelegt ist und die Credentials in `~/.cloudflared/` liegen.

## Befehle

### `sxgate init [--zone <domain>] [--tunnel <name>] [--config <path>]`

Einmaliger Setup. Findet die Tunnel-ID via `cloudflared tunnel list`, scaffoldet `/etc/cloudflared/config.yml` falls sie nicht existiert (mit Catch-all), schreibt `/etc/sxgate/sxgate.conf`. Bestehende `config.yml` wird unverändert übernommen und gebackupt.

### `sxgate service add <name> <url>`

Registriert oder aktualisiert einen Service. URL muss `http(s)://…` oder `http_status:NNN` sein. Service-Name muss `^[a-z][a-z0-9-]{0,30}$` matchen.

```bash
sudo sxgate service add blog http://localhost:2368
sudo sxgate service add api  http://localhost:3000
```

> **Hinweis:** Eine Service-URL zu ändern editiert das `services`-File, aber nicht automatisch die Routes in `config.yml`. Das CLI listet betroffene Routes und fordert dich auf, sie per `sxgate route add` neu zu schreiben.

### `sxgate service ls`

### `sxgate service rm <name> [--force]`

Schlägt fehl, wenn noch Routes diesen Service referenzieren. `--force` entfernt trotzdem (die Routes funktionieren weiter mit der eingebetteten URL).

### `sxgate route add <hostname> <service-name> [--no-dns] [--no-reload]`

Hot Path. Macht in dieser Reihenfolge:

1. Validierung (Hostname in `MANAGED_ZONE`, Service existiert)
2. Backup von `config.yml`
3. Atomisches Rewrite des `ingress:` Blocks (Catch-all bleibt immer letzter Eintrag)
4. `cloudflared tunnel ingress validate` — bei Failure: Rollback aus Backup
5. `cloudflared tunnel route dns <tunnel> <hostname>` (idempotent)
6. `systemctl reload cloudflared` (Fallback: `restart`)

```bash
sudo sxgate route add blog.henrysoase.org blog
```

Idempotent: Re-Run mit gleichem Service ist No-Op; Re-Run mit anderem Service updated.

### `sxgate route ls`

Zeigt alle Hostname→Service→URL Mappings. Routes deren URL zu keinem registrierten Service passt erscheinen mit `?`.

### `sxgate route rm <hostname> [--purge-dns] [--no-reload] [--yes]`

Entfernt die Ingress-Regel. DNS-Records kann `cloudflared` per CLI nicht löschen — `--purge-dns` zeigt nur einen Hinweis zur manuellen Cleanup im Cloudflare-Dashboard.

### `sxgate apply [--restart]`

Validiert die config.yml und reloaded den cloudflared-Dienst. Hilfreich nach manuellen Edits an `/etc/cloudflared/config.yml`. `--restart` erzwingt einen Hard-Restart statt SIGHUP-Reload.

### `sxgate status`

Tunnel-Info + systemd-Status.

## Umgebungsvariablen

| Var | Wirkung |
|---|---|
| `SXGATE_YES=1` | Skippt Confirmation-Prompts |
| `SXGATE_QUIET=1` | Nur Errors auf stderr |
| `SXGATE_DEBUG=1` | `set -x` Trace |
| `CONFIG_FILE` | Überschreibt `/etc/cloudflared/config.yml` (für Tests) |
| `SERVICES_FILE` | Überschreibt `/etc/sxgate/services` |
| `SXGATE_CONF` | Überschreibt `/etc/sxgate/sxgate.conf` |
| `BACKUP_DIR` | Überschreibt `/etc/sxgate/backups` |
| `LOCK_FILE` | Überschreibt `/var/lock/sxgate.lock` |

## Exit-Codes

| Code | Bedeutung |
|---|---|
| 0 | Success |
| 1 | Generischer Fehler |
| 2 | Usage / falsche Args |
| 3 | Validierung (Hostname out-of-zone, Service fehlt, …) |
| 4 | Externes Tool failed (cloudflared / systemctl) |
| 5 | Config-State korrupt (z.B. Catch-all fehlt) |
| 10 | User hat abgebrochen |

## State-Dateien

```
/etc/sxgate/sxgate.conf     # TUNNEL_NAME, MANAGED_ZONE, CONFIG_FILE
/etc/sxgate/services        # name=url, eine Zeile pro Service
/etc/sxgate/backups/        # config.yml.<UTC-Timestamp> — letzten 5
/etc/cloudflared/config.yml # Live-Config (sxgate editiert direkt)
/var/lock/sxgate.lock       # flock für concurrent CLI-Invocations
```

## FAQ

**Was, wenn ich die config.yml von Hand editiere?** Erlaubt — `sxgate apply` reloaded den Dienst. Beim nächsten `route add` rewriteed sxgate den ingress-Block; manuelle Kommentare im Block gehen verloren (Präambel-Kommentare bleiben).

**Warum kein separates `routes.yml`?** Bewusste Entscheidung: weniger Konzepte. Die config.yml ist die Wahrheit; das `services`-File ist nur eine Name→URL-Map, kein Routing-Mirror.

**Wie kann ich den Tunnel-Namen ändern?** Ändere `TUNNEL_NAME` in `/etc/sxgate/sxgate.conf` und passe `tunnel:` in `config.yml` an (oder `sxgate init --tunnel <neu>` neu laufen lassen).

**Wie deinstalliere ich?** `sudo rm /usr/local/bin/sxgate /etc/sxgate -rf` — die `config.yml` bleibt unangetastet.
