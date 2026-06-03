# Architektur

## Big Picture

```
        ┌────────────┐        HTTPS          ┌──────────────────┐
        │   Browser  │ ────────────────────▶ │  Cloudflare Edge │
        └────────────┘   (deinedomain.de)    └────────┬─────────┘
                                                      │
                                          persistenter│Tunnel
                                       (ausgehend vom │Server initiiert)
                                                      ▼
                                            ┌──────────────────┐
                                            │   cloudflared    │
                                            │  (Ubuntu @home)  │
                                            └────────┬─────────┘
                                                     │ http://localhost:PORT
                                                     ▼
                                            ┌──────────────────┐
                                            │    Webservice    │
                                            │  (Caddy/Docker/  │
                                            │   App/whatever)  │
                                            └──────────────────┘
```

Der Pfeil vom Server zu Cloudflare wird **vom Server selbst** geöffnet (outbound). Cloudflare schickt eingehende Requests durch diese bestehende Verbindung zurück. Dein Router muss nichts durchlassen.

## Glossar — die Begriffe in einfach

**DNS** — Adressbuch des Internets. `deinedomain.de` → IP-Adresse. Cloudflare ist hier dein DNS-Anbieter (wenn du die Domain dort kaufst, sind die Cloudflare-Nameserver automatisch gesetzt).

**Cloudflare Tunnel** — kleines Programm (`cloudflared`) das auf deinem Server läuft und eine dauerhafte verschlüsselte Verbindung zu Cloudflare hält. Cloudflare schickt Web-Requests durch diesen Tunnel zu deinem Server. Vorteil: dein Server ist "von außen" gar nicht direkt sichtbar.

**Reverse Proxy** — Vermittler vor deinem eigentlichen Service. Nimmt Requests an, leitet sie intern weiter (z.B. an `localhost:8080`). `cloudflared` ist im Prinzip ein Reverse Proxy. Du kannst zusätzlich noch Caddy/nginx davorhängen wenn du mehrere Services routen willst.

**CGNAT** (Carrier-Grade NAT) — manche Internet-Provider geben dir keine eigene öffentliche IP, sondern teilst dir eine mit hunderten anderen Kunden. Folge: niemand kann dich direkt erreichen. **Cloudflare Tunnel ignoriert das Problem komplett**, weil dein Server die Verbindung selbst aufbaut.

**Dynamische IP** — deine öffentliche IP ändert sich regelmäßig (typisch bei Heim-Internet). Wäre ein Problem für normale DNS-Records. **Tunnel-Lösung umgeht das**, weil die DNS auf eine Cloudflare-Adresse zeigt, nicht auf dich.

**Port-Forwarding** — Router-Regel die einen externen Port an einen Rechner im Heimnetz weiterleitet. **Brauchst du mit Cloudflare Tunnel nicht.**

**Ingress (in der `config.yml`)** — die Routing-Tabelle: welcher Hostname → welcher lokale Service. Wie ein "Wenn `blog.x.de` reinkommt, schick es an `localhost:2368`".

## Warum dieses Setup gut für dich ist
- **Sicher**: keine offenen Ports, Cloudflare filtert DDoS/Bots ab
- **Wartungsarm**: HTTPS-Zertifikate macht Cloudflare automatisch
- **Flexibel**: Webservice austauschen ändert nur einen Wert in der Config
- **Gratis** auf Cloudflares Free-Tier (auch kommerziell nutzbar)

## Was dieses Repo NICHT enthält
- Den eigentlichen Webservice — der lebt separat (z.B. anderes Repo, Docker-Image, statische Files)
- Server-Provisioning (Ansible/Terraform) — kommt evtl. später dazu
- Die echten Credentials oder die ausgefüllte `config.yml`
