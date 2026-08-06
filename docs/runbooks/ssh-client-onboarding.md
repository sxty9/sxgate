# Runbook — SSH-Client onboarden (cloudflared evtl. nicht installiert)

**Ziel:** Von einem beliebigen Client per `ssh <user>@ssh.example.com` auf den Server,
**ohne** vorauszusetzen, dass `cloudflared` schon da ist. Am Ende tippst du normales
`ssh`/`scp`/`rsync`; einmalig wird der Client eingerichtet.

**Warum überhaupt cloudflared am Client?** `ssh.example.com` zeigt auf Cloudflares
Edge, die **nur HTTPS** annimmt — es gibt **keinen offenen Port 22**. `cloudflared`
verpackt die SSH-Session in WebSocket-über-HTTPS (`ProxyCommand`). Ohne diesen lokalen
Proxy ist der Server über den Tunnel nicht per SSH erreichbar — es führt also kein Weg
an cloudflared am Client vorbei (Alternative wäre nur ein browserbasiertes Terminal via
Cloudflare Access for Infrastructure, hier nicht eingerichtet).

**Pfad:**
```
ssh (Client) ─▶ cloudflared access (ProxyCommand) ─▶ Cloudflare-Edge
      ─▶ cloudflared-Tunnel (Server) ─▶ sshd @ localhost:22
```

## Vorbedingungen
| Was | Wo | Prüfen |
|---|---|---|
| Server-Tunnel + `ssh`-Route aktiv | Server | `sudo ./sxgate route ls` zeigt `ssh.example.com → ssh` |
| DNS zeigt auf den Tunnel | überall | `dig +short ssh.example.com` → `<id>.cfargotunnel.com` |
| Dein Public-Key liegt in `~/.ssh/authorized_keys` des Server-Users `<user>` | Server | sonst Schritt 4 |
| Lokales Keypair am Client | Client | `ls ~/.ssh/id_ed25519` — falls leer: `ssh-keygen -t ed25519` |

---

## Schritt 0 — Ist cloudflared schon da?
```bash
command -v cloudflared && cloudflared --version
```
- **Gibt einen Pfad + Version aus** → cloudflared ist installiert, weiter mit **Schritt 2**.
- **„command not found"** → **Schritt 1**.

---

## Schritt 1 — cloudflared installieren
Wähle deine Plattform. Danach immer `cloudflared --version` zum Verifizieren.

### macOS
```bash
brew install cloudflared
```
Ohne Homebrew (Binary direkt):
```bash
# Apple Silicon: …-darwin-arm64.tgz, Intel: …-darwin-amd64.tgz
curl -fsSL -o /tmp/cf.tgz \
  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-arm64.tgz
sudo tar -xzf /tmp/cf.tgz -C /usr/local/bin cloudflared && sudo chmod +x /usr/local/bin/cloudflared
```

### Linux (Debian/Ubuntu)
```bash
# .deb aus den offiziellen Releases (amd64; für arm64 das passende Asset)
curl -fsSL -o /tmp/cloudflared.deb \
  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
sudo dpkg -i /tmp/cloudflared.deb
```

### Linux (kein Paketmanager / nicht root → ins Home)
```bash
mkdir -p ~/.local/bin
curl -fsSL -o ~/.local/bin/cloudflared \
  https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x ~/.local/bin/cloudflared
export PATH="$HOME/.local/bin:$PATH"   # ggf. dauerhaft in ~/.bashrc / ~/.zshrc
```

### Windows (PowerShell)
```powershell
winget install --id Cloudflare.cloudflared
```
Ohne winget: `.exe` aus den [GitHub-Releases](https://github.com/cloudflare/cloudflared/releases/latest)
(`cloudflared-windows-amd64.exe`) z.B. nach `C:\Tools\cloudflared.exe` legen und den Ordner zum `PATH` hinzufügen.

**Verify (alle Plattformen):**
```bash
cloudflared --version
```

---

## Schritt 2 — Pfad zu cloudflared ermitteln
Der `ProxyCommand` braucht idealerweise den **absoluten** Pfad (cron/GUI-SSH-Clients
wie VS Code haben nicht immer denselben `PATH`).
```bash
command -v cloudflared          # macOS/Linux  → z.B. /opt/homebrew/bin/cloudflared
```
Windows (PowerShell): `(Get-Command cloudflared).Source` → z.B. `C:\Tools\cloudflared.exe`.

---

## Schritt 3 — ProxyCommand in die SSH-Config eintragen *(einmalig)*

> **Achtung Fallstrick:** `cloudflared access ssh-config …` druckt eine Hinweiszeile
> (`Add to your … config:`) mit aus. Direkt nach `~/.ssh/config` umgeleitet bricht das
> später `ssh` mit „Bad configuration option". Deshalb hier **direkt schreiben** (robust).

### macOS / Linux
Pfad aus Schritt 2 einsetzen:
```bash
CF=$(command -v cloudflared)
cat >> ~/.ssh/config <<EOF
Host ssh.example.com
  ProxyCommand $CF access ssh --hostname %h
EOF
chmod 600 ~/.ssh/config
```

### Windows (PowerShell)
```powershell
$cfg = "$env:USERPROFILE\.ssh\config"
if (!(Test-Path $cfg)) { New-Item -ItemType File -Path $cfg -Force | Out-Null }
Add-Content $cfg "`nHost ssh.example.com`n  ProxyCommand C:\Tools\cloudflared.exe access ssh --hostname %h"
```

**Verify:**
```bash
ssh -G ssh.example.com | grep -i proxycommand
# erwartet: proxycommand <pfad>/cloudflared access ssh --hostname ssh.example.com
```

---

## Schritt 4 — (falls nötig) Public-Key auf den Server bringen
Nur wenn dein Key noch nicht in `authorized_keys` des Servers liegt. Geht über denselben
Tunnel — ist der ProxyCommand (Schritt 3) gesetzt und Passwort-Login am Server noch aktiv:
```bash
ssh-copy-id <user>@ssh.example.com
```
Kein Passwort-Login mehr aktiv? Dann den Inhalt von `~/.ssh/id_ed25519.pub` auf
anderem Weg (z.B. lokal am Server) in `~/.ssh/authorized_keys` eintragen.

---

## Schritt 5 — Verbinden + verifizieren
```bash
ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=25 \
    <user>@ssh.example.com \
    'echo "LOGIN-OK: $(whoami)@$(hostname) — peer ${SSH_CONNECTION%% *}"'
```
**Erwartet:** `LOGIN-OK: <user>@home — peer 127.0.0.1`
Das `peer 127.0.0.1` beweist: die Session kam über den lokalen cloudflared-Tunnel
(localhost:22) am Server an, nicht über einen direkten Port.

Ab jetzt einfach `ssh <user>@ssh.example.com`. `scp`/`rsync`/`sftp`/VS-Code-Remote-SSH
laufen transparent über denselben Host.

---

## Einmal-Verbindung ohne Config-Edit (Ad-hoc / fremder Rechner)
Wenn du `~/.ssh/config` nicht anfassen willst, den ProxyCommand inline mitgeben:
```bash
ssh -o ProxyCommand="$(command -v cloudflared) access ssh --hostname %h" \
    <user>@ssh.example.com
```

---

## Troubleshooting
| Symptom | Check / Fix |
|---|---|
| `ssh: connect ... Connection timed out` | DNS prüfen: `dig +short ssh.example.com` muss `<id>.cfargotunnel.com` liefern. |
| `Bad configuration option` | Hinweis-Preamble ist in `~/.ssh/config` gelandet — die `Add to your …`-Zeile entfernen. |
| `cloudflared: command not found` beim Connect | ProxyCommand nutzt relativen Namen, aber GUI-Client hat anderen `PATH` → absoluten Pfad eintragen (Schritt 2/3). |
| Proxy isoliert testen | `cloudflared access ssh --hostname ssh.example.com` (muss „hängen"/lauschen, kein Sofort-Fehler). |
| Verbose-Login | `ssh -v <user>@ssh.example.com` |

## Sicherheitshinweis
Port 22 ist über `ssh.example.com` öffentlich erreichbar (nur durch SSH-Auth
geschützt). Empfehlung am Server: `PasswordAuthentication no` (erst Key testen!),
optional Cloudflare Access (Zero Trust) als vorgelagertes Identitäts-Gate. Siehe
README → „SSH über den Tunnel" und [ssh-loopback-selftest.md](ssh-loopback-selftest.md).
