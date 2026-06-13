# Runbook — SSH-over-Tunnel Loopback-Selbsttest

**Ziel:** Verifizieren, dass die komplette SSH-über-Cloudflare-Tunnel-Kette funktioniert,
indem der Server sich über den **öffentlichen** Hostnamen `ssh.henrysoase.org` bei
**sich selbst** einloggt.

**Pfad:**
```
ssh (Client) ─▶ cloudflared access (ProxyCommand) ─▶ Cloudflare-Edge
      ─▶ cloudflared-Tunnel (dieser Server) ─▶ sshd @ localhost:22
```
Der Login verlässt die Maschine Richtung Cloudflare und kommt über den Tunnel wieder
zurück — also ein echter End-to-End-Test, kein lokaler Shortcut.

## Vorbedingungen (geprüft 2026-06-13, Host `home`, User `nanu`)
| Check | Status |
|---|---|
| `cloudflared` installiert (2026.6.0) + Service `active` | ✓ |
| Ingress `ssh.henrysoase.org → ssh://localhost:22` in `/etc/cloudflared/config.yml` | ✓ |
| DNS `ssh.henrysoase.org` → Cloudflare-Edge | ✓ |
| Keypair `~/.ssh/id_ed25519` vorhanden | ✓ |
| `~/.ssh/authorized_keys` befüllt | ✗ (leer) → Schritt 1 |
| ProxyCommand in `~/.ssh/config` | ✗ → Schritt 2 |
| **sshd lauscht auf `localhost:22`** | ✗ **openssh-server fehlt** → Schritt 0 |

## Schritte

### 0 — sshd installieren *(sudo, vom Nutzer auszuführen)*
```bash
sudo apt-get update && sudo apt-get install -y openssh-server
```
Ubuntu aktiviert + startet `ssh` automatisch. **Verify:** `ss -tlnp | grep ':22'`

### 1 — Key-Auth für den Loopback vorbereiten *(User `nanu`, kein sudo)*
`authorized_keys` ist leer; eigenen Public-Key eintragen, damit der Self-Login per
Key (ohne Passwort) klappt:
```bash
cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

### 2 — Client-ProxyCommand eintragen *(User `nanu`, kein sudo)*
> **Achtung:** `cloudflared access ssh-config …` druckt eine Hinweiszeile
> (`Add to your … config:`) mit aus. Direkt `>> ~/.ssh/config` umgeleitet landet die
> in der Datei und bricht `ssh` mit „Bad configuration option". Daher entweder den
> Block direkt schreiben **oder** die Helper-Ausgabe filtern.

Direkt (robust):
```bash
cat >> ~/.ssh/config <<'EOF'
Host ssh.henrysoase.org
  ProxyCommand /usr/bin/cloudflared access ssh --hostname %h
EOF
chmod 600 ~/.ssh/config
```
Alternativ via Helper, aber Preamble strippen:
```bash
cloudflared access ssh-config --hostname ssh.henrysoase.org \
  | sed -n '/^Host /,$p' >> ~/.ssh/config
```
**Verify:** `ssh -G ssh.henrysoase.org | grep -i proxycommand`

### 3 — Test: Loopback-Login
```bash
ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=25 \
    nanu@ssh.henrysoase.org \
    'echo "LOGIN-OK: $(whoami)@$(hostname) — peer ${SSH_CONNECTION%% *}"'
```
**Erwartet:** `LOGIN-OK: nanu@home — peer 127.0.0.1`
Das `peer 127.0.0.1` beweist, dass die Verbindung über den lokalen cloudflared-Tunnel
(localhost:22) ankam, nicht über einen direkten Port.

## Rollback / Aufräumen (optional)
```bash
# ProxyCommand-Block wieder aus ~/.ssh/config entfernen
# Public-Key-Zeile aus ~/.ssh/authorized_keys entfernen
sudo systemctl disable --now ssh      # sshd wieder abschalten, falls unerwünscht
```

## Sicherheitshinweis
Sobald sshd läuft, ist Port 22 über `ssh.henrysoase.org` **öffentlich** erreichbar
(nur durch SSH-Auth geschützt). Empfehlung: in `/etc/ssh/sshd_config`
`PasswordAuthentication no` setzen und ausschließlich Key-Auth nutzen.
Optional vorgelagert: Cloudflare Access (Zero Trust).
