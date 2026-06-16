# `sxgate` CLI

Verwaltung von Subdomain↔Service-Routing für einen Cloudflare Tunnel auf einem Ubuntu-Server.

## Mental Model

- **Services** sind benannte Targets (z.B. `blog` → `http://localhost:2368`). Gespeichert in `/etc/sxgate/services`.
- **Routes** sind Hostname→Service-Bindings (z.B. `blog.henrysoase.org` → `blog`). Diese landen direkt im `ingress:` Block von `/etc/cloudflared/config.yml` (mit aufgelöster URL).
- `/etc/cloudflared/config.yml` ist die **Source of Truth** für aktives Routing — `sxgate` editiert sie direkt (atomisch, mit Backup).

## Installation

```bash
git clone https://github.com/sxty9/sxgate.git && cd sxgate
sudo ./sxgate setup                  # installiert cloudflared, Tunnel, systemd-Service
sudo ./sxgate zone henrysoase.org    # verwaltete DNS-Zone (entkoppelt)
```

Repo-lokal wie `./holistic` — **kein separates Install-Skript**. `setup` bootstrappt alles inkl. `cloudflared`; `zone` legt die DNS-Zone fest.

## Befehle

### `sxgate setup [--tunnel <name>]`

Turnkey-Bootstrap (als root), idempotent: installiert `cloudflared` (offizielles Cloudflare-apt-Repo) falls nötig → `cloudflared tunnel login` (interaktiv, Browser-URL; übersprungen wenn `cert.pem` existiert) → legt den Tunnel an falls nicht vorhanden → scaffoldet `/etc/cloudflared/config.yml` (Catch-all) + `/etc/sxgate/{sxgate.conf,services}` → `cloudflared service install` + Start. **Setzt bewusst keine Zone** — siehe `sxgate zone`.

### `sxgate zone [<domain>]`

Setzt (`sxgate zone henrysoase.org`) oder zeigt (`sxgate zone`) die verwaltete DNS-Zone in `/etc/sxgate/sxgate.conf`. `route add` validiert Hostnamen gegen diese Zone und verlangt sie.

### `sxgate init [--zone <domain>] [--tunnel <name>] [--config <path>]`

Low-Level-Scaffold (von `setup` intern genutzt). Findet die Tunnel-ID via `cloudflared tunnel list`, scaffoldet `/etc/cloudflared/config.yml` falls sie nicht existiert (mit Catch-all), schreibt `/etc/sxgate/sxgate.conf`. Bestehende `config.yml` wird unverändert übernommen und gebackupt. Die Zone ist **optional** (per `sxgate zone` nachsetzbar).

### `sxgate service add <name> <url>`

Registriert oder aktualisiert einen Service. URL muss `http(s)://…`, `ssh://host:port` oder `http_status:NNN` sein. Service-Name muss `^[a-z][a-z0-9-]{0,30}$` matchen. (`ssh://` → siehe [SSH-Zugang](#ssh-zugang-über-den-tunnel).)

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

## Preview-Sandboxes (`sxgate preview`)

Pro-Branch-Sandboxes für **jeden** über sxgate gehosteten Service — Feature-Testing auf einer
eigenen URL, ohne dass parallele Branches im selben Repo/Deploy kollidieren. Schema (flach,
gratis, vom bestehenden `*.<zone>`-Universal-Cert abgedeckt):

```
prod:    <service>.henrysoase.org
sandbox: <branch>-<service>.henrysoase.org      # z.B. feat-profile-holistic.henrysoase.org
```

Der Tunnel wird **einmalig** angefasst (eine Wildcard-Ingress `*.<zone>` → ein lokaler
Dispatcher-Caddy). Danach editieren `up`/`down` nur die Dispatcher-Drop-ins + systemd-Instanzen
— **nie** cloudflared/DNS. So bleibt sxgate pro Branch unbelastet.

```bash
sudo sxgate preview setup                 # einmalig: Wildcard-Ingress + Dispatcher + Units + User
# danach einmal manuell in Cloudflare: proxied  *  CNAME  <tunnel-id>.cfargotunnel.com
sudo sxgate preview up <branch>           # aus einem Repo mit .sxgate/preview.conf
sudo sxgate preview ls
sudo sxgate preview rebuild <slug|branch> # nach neuen Commits: pull + build + restart
sudo sxgate preview down <slug|branch>
```

### Service-Manifest: `.sxgate/preview.conf`

Ein **sourcebares** Shell-Fragment im Service-Repo. Platzhalter `{worktree} {state} {zone}
{port}` expandiert die Engine (Laufzeit-Werte über `{port}`, **nicht** `$PORT` — die Datei wird
gesourcet). Schlüssel:

| Key | Zweck |
|-----|-------|
| `SERVICE` | Basisname; Host = `<branch>-<service>.<zone>` |
| `BUILD` | Build-Kommando (im Worktree); optional |
| `MODE` | `static_proxy` (SPA + `/api`-Proxy) · `proxy` (reiner Reverse-Proxy) · `static` |
| `ROOT` | statisches Verzeichnis (für `static`/`static_proxy`) |
| `API_PREFIX` | an das Backend proxyter Pfad (Default `/api`) |
| `RUN` | Backend-Kommando, bindet `127.0.0.1:{port}` |
| `RUN_CWD` / `RUN_ENV` | Arbeitsverzeichnis + env (hier lebt die **Sandbox-Isolation**, z.B. Fake-Auth) |
| `SEED` | optional; läuft nach Anlegen von `{state}`, stdout erscheint als „notes“ |
| `HEALTHCHECK` | optionaler Pfad, auf 2xx gewartet wird |
| `HOOK` | Escape-Hatch-Script: `HOOK build <wt> <state>` · `HOOK serve <wt> <port> <state>` |

Die Sandbox-Sicherheit (Fake-PAM/-Daten, Wegwerf-State) ist **Service-Sache** und steht im
`RUN_ENV` — die Engine selbst kennt weder Sprache noch Auth des Service.

## SSH-Zugang über den Tunnel

SSH ist nur ein Service mit `ssh://`-Schema — **kein** Sonderbefehl nötig. Standard-Subdomain `ssh.<zone>`:

```bash
sudo ./sxgate service add ssh ssh://localhost:22
sudo ./sxgate route   add ssh.henrysoase.org ssh
```

Damit ist der lokale sshd (Port 22) als `ssh.henrysoase.org` über den Tunnel erreichbar. Andere Subdomain/Port: einfach `service add`-URL bzw. `route add`-Hostname anpassen (z.B. `service add ssh ssh://localhost:2222`, `route add admin.henrysoase.org ssh`).

### Verbinden (Client)

**Wichtig:** Man kann sich **nicht** direkt mit `ssh ssh.henrysoase.org` verbinden. Der Tunnel ist ein ausgehender HTTPS-Tunnel; `ssh.<zone>` zeigt auf Cloudflares Edge, die **nur HTTPS** annimmt — es gibt **keinen offenen Port 22**. Der Client wickelt SSH daher per `cloudflared` in WebSocket-über-HTTPS. Nach einmaliger Einrichtung tippst du trotzdem nur `ssh user@host`.

1. `cloudflared` am Client installieren:
   - macOS: `brew install cloudflared`
   - Windows: `winget install --id Cloudflare.cloudflared` (oder `.exe` aus den GitHub-Releases)
   - Linux: Binary aus den GitHub-Releases nach `/usr/local/bin/cloudflared` + `chmod +x`
2. Einmalig den ProxyCommand in `~/.ssh/config` eintragen — am einfachsten generiert:
   ```bash
   cloudflared access ssh-config --hostname ssh.henrysoase.org >> ~/.ssh/config
   ```
   Ergebnis:
   ```
   Host ssh.henrysoase.org
     ProxyCommand cloudflared access ssh --hostname %h
   ```
3. Verbinden: `ssh <user>@ssh.henrysoase.org` (Host-Key beim ersten Mal bestätigen). `scp`/`rsync`/`sftp`/`ssh-copy-id`/VS-Code-Remote-SSH laufen transparent über denselben Host.

Troubleshooting: `dig +short ssh.henrysoase.org` → CNAME auf `<tunnel-id>.cfargotunnel.com`; Proxy isoliert testen mit `cloudflared access ssh --hostname ssh.henrysoase.org`; `ssh -v <user>@ssh.henrysoase.org` für Verbose-Logs.

### Sicherheit

Der SSH-Endpoint ist jetzt über den öffentlichen Hostnamen erreichbar (geschützt nur durch SSH-Auth, solange keine Cloudflare-Access-Policy davorhängt). Empfehlung: in `/etc/ssh/sshd_config` `PasswordAuthentication no` setzen und ausschließlich Key-Auth nutzen (Public-Key vorher in `~/.ssh/authorized_keys` des Server-Users hinterlegen). **sxgate ändert sshd nicht automatisch.** Optionale weitere Härtung: Cloudflare Access (Zero Trust) als vorgelagertes Identitäts-Gate.

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

# Preview (sxgate preview):
/etc/sxgate/preview/Caddyfile      # Dispatcher-Basis (import sites.d/*.caddy)
/etc/sxgate/preview/sites.d/       # ein vhost-Drop-in pro lebendem Sandbox
/etc/sxgate/preview/instances/     # <slug>.env (systemd) + <slug>.meta (ls/teardown)
/srv/sxgate-previews/<slug>/       # git worktree + Build-Artefakte + state
/usr/local/lib/sxgate/preview-run  # generischer Instanz-Launcher
```

## FAQ

**Was, wenn ich die config.yml von Hand editiere?** Erlaubt — `sxgate apply` reloaded den Dienst. Beim nächsten `route add` rewriteed sxgate den ingress-Block; manuelle Kommentare im Block gehen verloren (Präambel-Kommentare bleiben).

**Warum kein separates `routes.yml`?** Bewusste Entscheidung: weniger Konzepte. Die config.yml ist die Wahrheit; das `services`-File ist nur eine Name→URL-Map, kein Routing-Mirror.

**Wie kann ich den Tunnel-Namen ändern?** Ändere `TUNNEL_NAME` in `/etc/sxgate/sxgate.conf` und passe `tunnel:` in `config.yml` an (oder `sxgate init --tunnel <neu>` neu laufen lassen).

**Wie deinstalliere ich?** `sudo rm /usr/local/bin/sxgate /etc/sxgate -rf` — die `config.yml` bleibt unangetastet.
