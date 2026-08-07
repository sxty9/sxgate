# sxgate

The network edge of ONE environment: the "linker" between a Cloudflare zone and the services
running on **this** host. Traffic rides a **Cloudflare Tunnel** (`cloudflared`) — no open router
ports, dynamic IP / CGNAT irrelevant, HTTPS + DDoS protection included.

```
 Browser ──HTTPS──▶ Cloudflare-Edge ──Tunnel──▶ cloudflared (this host) ──HTTP──▶ service (e.g. localhost:8080)
```

## Leitbild — one sxgate per environment

1. **Every** environment has an sxgate.
2. Each sxgate manages **everything** of its own environment — routes, mail egress, mail
   inbound, preview sandboxes.
3. Each sxgate manages **nothing** of an environment it does not belong to: no foreign zone, no
   foreign credentials, no foreign routes, no remote control of another host.

There is no "production" special case and no environment detection: the SAME program with the
SAME commands runs on every host. The ONLY difference between two hosts is their runtime
configuration — which zone, which tunnel, which credentials. Those values live in the runtime
config and never in this repository. Full model + the operator's one-time step:
[docs/deployment.md](docs/deployment.md).

## Bring a host up — one command

Clone the repo on the host, then provision it from that host's own runtime values:

```bash
git clone <sxgate-repo-url> ~/sxgate && cd ~/sxgate
sudo ./sxgate provision --zone <domain>          # stands up ALL five responsibilities for THIS host
```

`provision` installs and wires cloudflared + tunnel + routes, the mail egress relay, the mail
inbound scaffold, and the preview subsystem — for this host's own zone. Every step is idempotent,
so re-running it is safe. The one interactive step is the Cloudflare login during `setup` (a
browser URL is printed); on a host that already holds a cloudflared cert it is skipped.

Secrets (DKIM key, edge/inbound secrets, tunnel credentials) are generated **on this host** and
never travel between hosts. A fresh host needs only the values above.

**Wichtig:** `~/.cloudflared/<TUNNEL-ID>.json` holds credentials — **never commit it**. `.gitignore`
covers it.

## Attach a service

```bash
sudo ./sxgate service add blog http://localhost:2368
sudo ./sxgate route   add blog.<domain> blog
sudo ./sxgate route   ls
```

Das CLI legt den DNS-Record an (`cloudflared tunnel route dns …`), schreibt die Ingress-Regel atomisch in `/etc/cloudflared/config.yml` und reloaded den Tunnel. Details: [docs/cli.md](docs/cli.md).

## SSH über den Tunnel

Server-SSH über eine Subdomain (Standard `ssh.<domain>`) erreichbar machen — SSH ist einfach ein Service mit `ssh://`-Schema, kein Sonderbefehl:

```bash
sudo ./sxgate service add ssh ssh://localhost:22
sudo ./sxgate route   add ssh.example.com ssh
```

**Verbinden:** *Nicht* direkt per `ssh ssh.example.com` — der Tunnel spricht am Cloudflare-Edge nur HTTPS (kein offener Port 22). Der Client braucht einmalig `cloudflared` + einen ProxyCommand; danach ist der Alltag normales `ssh`:

```bash
# am Client, einmalig (cloudflared muss installiert sein):
cloudflared access ssh-config --hostname ssh.example.com \
  | sed -n '/^Host /,$p' >> ~/.ssh/config   # Helper druckt eine Hinweiszeile mit → strippen
# danach wie gewohnt:
ssh <user>@ssh.example.com
```

**Sicherheit — Key-only erzwingen:** Port 22 ist damit übers Internet erreichbar (nur durch SSH-Auth geschützt). Dringend empfohlen: ausschließlich Key-Auth. Auf dem Server:

```bash
# 1. Public-Key des Clients in ~/.ssh/authorized_keys des Server-Users hinterlegen UND testen
# 2. dann Passwort-Login abschalten (Drop-in, vor dem Reload validieren):
echo 'PasswordAuthentication no' | sudo tee /etc/ssh/sshd_config.d/99-hardening.conf
sudo sshd -t && sudo systemctl restart ssh.socket
```

**Wichtig:** Erst Key hinterlegen und einen Login testen — sonst sperrst du dich aus. Optional vorgelagert: Cloudflare Access (Zero Trust). Client onboarden (cloudflared evtl. nicht installiert, OS-für-OS): [docs/runbooks/ssh-client-onboarding.md](docs/runbooks/ssh-client-onboarding.md). End-to-End-Loopback-Test: [docs/runbooks/ssh-loopback-selftest.md](docs/runbooks/ssh-loopback-selftest.md); Hintergrund: [docs/cli.md](docs/cli.md#ssh-zugang-über-den-tunnel).

## Troubleshooting
- `cloudflared tunnel list` — zeigt aktive Tunnels
- `journalctl -u cloudflared -f` — Live-Logs
- `cloudflared tunnel info sxgate` — Verbindungs-Status

## CLI

`sxgate` managt Subdomain↔Service-Mappings zentral. Konzept: **Services** sind benannte Targets (Name → URL), **Routes** binden Hostnames an Services. Die Live-Config bleibt `/etc/cloudflared/config.yml` — `sxgate` editiert sie direkt mit Backups + Validierung + Rollback.

```bash
sudo ./sxgate setup                          # einmalig: cloudflared + Tunnel + systemd-Service
sudo ./sxgate zone example.com            # verwaltete DNS-Zone
sudo ./sxgate service add blog http://localhost:2368
sudo ./sxgate route   add blog.example.com blog
sudo ./sxgate route   ls
sudo ./sxgate status
sudo ./sxgate teardown --dry-run             # Umkehrung von setup: zeigt, was entfernt/behalten wird
```

Tests laufen offline (mocken `cloudflared` und `systemctl`):

```bash
bash tests/run.sh
```

Vollständige Referenz: [docs/cli.md](docs/cli.md).

## Preview-Sandboxes

Pro-Branch-Feature-Sandboxes für **jeden** über sxgate gehosteten Service — eigene URL, kein
Kollidieren paralleler Branches im selben Repo/Deploy:

```bash
sudo ./sxgate preview setup          # einmalig: Wildcard-Ingress *.zone → Dispatcher (+ DNS-Hinweis)
sudo ./sxgate preview up <branch>    # aus einem Repo mit .sxgate/preview.conf
#  → https://<branch>-<service>.example.com
sudo ./sxgate preview ls | rebuild <x> | down <x>
```

Der Tunnel wird nur einmal angefasst; danach editieren `up`/`down` nur einen lokalen
Dispatcher-Caddy + systemd-Instanzen. Jeder Service beschreibt Build/Run in `.sxgate/preview.conf`
(inkl. eigener Sandbox-Isolation, z.B. Fake-Auth). Voll dokumentiert: [docs/cli.md](docs/cli.md#preview-sandboxes-sxgate-preview).

## Mail-Edge (für den holistic Mailserver `maild`)

Der öffentliche Mail-Ein-/Ausgang für den holistic Mailserver — der Tunnel trägt nur HTTP,
klassisches SMTP lässt sich nicht durchreichen. `maild` besitzt Postfächer + API und stellt
interne Mail direkt zu; **sxgate besitzt die Netzwerkkante**:

- **Eingang:** Cloudflare Email Routing → ein Email Worker → HTTPS-Webhook an `maild`
  (`POST /api/services/mail/inbound`, per gemeinsamem Secret authentifiziert).
- **Ausgang:** `maild` spoolt → lokaler Egress-Relay (`sxgate-mail-egress`) → **DKIM-signiert**
  → Übergabe an einen Smarthost (SMTP-Submission).
- **DNS:** MX (via Email Routing), SPF, DKIM, DMARC.

```bash
sudo ./sxgate mail setup --domain example.com              # Secrets, DKIM, Egress-Relay,
                                                              # maild-Drop-in, Email-Worker + DNS-Records
sudo ./sxgate mail relay set smtp.provider.com:587 --user me  # Smarthost für den Ausgang
sudo ./sxgate mail dkim-record                                # DKIM-TXT-Record fürs DNS
sudo ./sxgate mail test-inbound --to user@example.com      # Eingangs-Kontrakt gegen maild prüfen
sudo ./sxgate mail status
```

`setup` legt die lokalen Teile selbst an (Secrets, DKIM-Keypair, Egress-Build, systemd-Units,
Worker); die Cloudflare-Schritte (Email Routing aktivieren, `wrangler deploy`, Inbound-Secret als
Worker-Secret, DNS-Records) werden ausgegeben. Der Egress-Relay (`edge/egress/`, reines Go-Stdlib)
signiert DKIM (relaxed/relaxed, rsa-sha256) und relayed über den Smarthost. Quelle: `lib/mail.sh`
+ `edge/`.

## Mehr
Siehe [docs/architecture.md](docs/architecture.md) für Glossar und Konzepte (DNS, Tunnel, Reverse Proxy, CGNAT).
