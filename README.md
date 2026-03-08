# 📦 Friendbox

A fully automated, menu-driven Docker media server stack for Ubuntu 24.04 LTS.

**Includes:** Traefik · Portainer · Plex · Jellyfin · Sonarr · Radarr · Prowlarr · Bazarr · qBittorrent · qBittorrentVPN · DelugeVPN · NZBGet · Overseerr · Ombi · Jellyseerr · TeamSpeak 6 · Mumble · AMP (game servers) · NetbootXYZ

---

## ⚙️ System Requirements

| Requirement | Details |
|---|---|
| **OS** | Ubuntu 24.04 LTS (Noble Numbat) — tested and supported |
| **Architecture** | x86_64 (amd64) |
| **RAM** | 4 GB minimum, 8 GB+ recommended |
| **Disk** | 20 GB minimum for OS + config; separate drives recommended for media |
| **Domain** | A registered domain or free DuckDNS subdomain (e.g. `myhome.duckdns.org`) |

> Friendbox will warn you and ask for confirmation if run on a non-Ubuntu 24.04 system. It may work on other Debian-based distros but is not tested or supported.

---

## ⚡ Quick Start

### 1. Bootstrap (run once)

```bash
curl -fsSL https://raw.githubusercontent.com/xkronusx/friendbox/main/setup.sh | sudo bash
```

This installs the `friendbox` command to `/usr/local/bin/friendbox`. It does **not** install Docker or start any containers.

### 2. Launch the menu

```bash
sudo friendbox
```

Every launch automatically pulls the latest files from GitHub before opening the menu. If GitHub is unreachable, it falls back to the local copy silently.

### 3. Run Full Install

At the menu, select **option 1 — Full Install**. This walks you through every setup step in sequence: environment config, container selection, Docker install, network creation, directory provisioning, and starting your containers.

> See [First-Time Setup — Step by Step](#️-first-time-setup--step-by-step) below for what to prepare before running it.

---

## 🗂 First-Time Setup — Step by Step

**Full Install (option 1) handles the entire sequence automatically** — it calls environment configuration and container selection itself as part of its flow. You don't need to run options 2 and 3 separately before running option 1.

The steps below explain what happens during that flow and what to prepare in advance. Steps marked *(skip if not applicable)* are optional.

---

### Step 1 — MergerFS storage pool *(skip if using a single drive)*
**`sudo friendbox` → option 7** — run this *before* Full Install if applicable

If you have multiple physical drives to pool into a single path, set this up first — before configuring your environment — so the pool path can be used as your media root.

**Before running:**
- Mount each drive to its own path (e.g. `/mnt/disk1`, `/mnt/disk2`)
- Format drives as ext4 and add them to `/etc/fstab` for persistence across reboots

**During setup, assign each disk a mode:**

| Mode | Meaning |
|---|---|
| `RW` | Read/Write — new files can be created here |
| `NC` | No-Create — existing files readable, no new files written here. Useful for an almost-full drive you want to drain gradually |
| `RO` | Read-Only — no writes at all |

MergerFS writes an `/etc/fstab` entry and mounts the pool live at `/mnt/media`. No reboot needed.

**If you skip MergerFS**, ensure your media root exists before continuing:
```bash
mkdir -p /mnt/media && chown 1000:1000 /mnt/media
```

**MergerFS sub-menu (option 7):**

| Sub-option | Function |
|---|---|
| 1 | Initial pool setup (first time) |
| 2 | Add a disk to the pool |
| 3 | Change a disk's mode (RW / NC / RO) |
| 4 | Remove a disk from the pool |
| 5 | Show pool & drive details (size, used, free, mount status per disk) |
| 6 | Mount / remount pool |
| 7 | Fix ownership & create subdirs on all drives |
| 8 | Unmount pool |

> **Drive details (option 5)** uses `findmnt` to detect whether a real filesystem is mounted at each drive path — not just whether the directory exists. It shows the device name (e.g. `● /dev/sdb1`) in green when mounted, `○ not mounted` in yellow when not, and `? path missing` in red when the directory is absent entirely.

> **Subdirectory creation (option 7)** writes `movies/`, `tv/`, and `downloads/` (if any download client, Sonarr, or Radarr is selected) directly on each RW/NC branch disk. RO branches are never written to. Subdirs are never created through the mounted pool path.

---

### Step 2 — Configure your environment
**Handled automatically by Full Install** — or run manually via `sudo friendbox` → option 3

Sets core variables in `/opt/friendbox/.env`. All other steps depend on this.

| Prompt | Description |
|---|---|
| **Domain** | Your domain (e.g. `myhome.duckdns.org`). Must be a domain you control. |
| **ACME email** | Used by Let's Encrypt for certificate notifications. Use a real address. |
| **Config root** | Where container config data lives (default: `/opt/friendbox/config`) |
| **Media root** | Where media files live (default: `/mnt/media`). Set to your MergerFS pool path if applicable. |
| **PUID / PGID** | Linux user/group ID containers run as. Default `1000:1000` is correct for the first non-root user. Run `id` to confirm. |
| **Timezone** | e.g. `America/Toronto` |
| **Plex claim token** | Optional. Get one at [plex.tv/claim](https://plex.tv/claim) — valid for 4 minutes. Lets Plex auto-link to your account on first start. Leave blank to claim manually later. |

Press **Enter** on any prompt to keep the current value.

---

### Step 3 — Select containers
**Handled automatically by Full Install** — or run manually via `sudo friendbox` → option 2

Toggle services with their number, press `d` when done. Your selection persists between runs.

**Available containers:**

| Container | Description |
|---|---|
| `traefik` | Reverse proxy with automatic HTTPS via Let's Encrypt |
| `portainer` | Docker management web UI |
| `plex` | Media server (requires Plex account) |
| `jellyfin` | Open-source media server (no account required) |
| `sonarr` | TV show library manager |
| `radarr` | Movie library manager |
| `prowlarr` | Indexer manager for Sonarr/Radarr |
| `bazarr` | Subtitle downloader for Sonarr/Radarr |
| `qbittorrent` | BitTorrent download client |
| `qbittorrentvpn` | qBittorrent with built-in VPN kill switch |
| `delugevpn` | Deluge with built-in VPN kill switch |
| `nzbget` | Usenet download client |
| `overseerr` | Media request manager (Plex) |
| `ombi` | Media request manager — **deprecated**, consider Overseerr or Jellyseerr |
| `jellyseerr` | Media request manager (Jellyfin) |
| `netbootxyz` | Network boot server |
| `teamspeak6` | TeamSpeak 6 voice server — connect via TS6 client on UDP 9987 |
| `mumble` | Mumble voice server — connect via Mumble client on port 64738 |
| `ampmc` | AMP game server management panel |

**Recommended minimum for a media server:**
- Plex or Jellyfin
- Sonarr + Radarr + Prowlarr
- qBittorrent or a VPN download client

---

### Step 4 — Full Install
**`sudo friendbox` → option 1**

Runs the complete first-time setup in sequence:

1. OS compatibility check
2. Installs Docker CE, curl, apache2-utils
3. Pulls latest `docker-compose.yml` and config files from GitHub
4. Opens container selection (selection is needed before environment prompts)
5. Prompts to confirm environment settings (Plex claim token is skipped if Plex not selected)
6. Creates the `medianet` Docker bridge network
7. Creates `acme.json` with correct permissions (`root:root 600`)
8. Provisions config and media directories (creates `traefik.yml`, `acme.json`, all config and media dirs)
9. Starts all selected containers with `docker compose up -d`

If Friendbox is already installed, option 1 warns before proceeding.

---

### Step 5 — Configure Traefik *(required if Traefik is selected)*
**`sudo friendbox` → option 4**

| Sub-option | Function |
|---|---|
| 1 | Set dashboard credentials (username + bcrypt password) |
| 2 | Update domain / ACME email |
| 3 | Configure ACME challenge provider |
| 4 | Toggle staging / production CA |
| 5 | Run pre-flight checks |
| 6 | Live routing diagnostics |
| 7 | Emergency recovery (clear certs + restart Traefik) |
| 8 | Set root domain redirect target |

**ACME challenge providers:**

| Provider | Challenge type | Notes |
|---|---|---|
| `http` | HTTP-01 | Requires ports 80/443 forwarded to this machine |
| `cloudflare` | DNS-01 | Requires CF API token with Zone:DNS:Edit permission |
| `duckdns` | DNS-01 | Requires DuckDNS token. Wildcard cert only — see note below |
| `godaddy` | DNS-01 | Requires GoDaddy API key + secret |
| `namecheap` | DNS-01 | Requires Namecheap Dynamic DNS credentials |

> **DuckDNS note:** The DuckDNS API can only set TXT records on the root subdomain — not on sub-subdomains. Per-host certificates (e.g. `portainer.myhome.duckdns.org`) cannot be validated individually. Friendbox automatically requests a single wildcard cert (`*.yourdomain.duckdns.org`) that covers all subdomains at once. No manual configuration needed — the domain is read from your `.env` settings.

**Staging CA (option 4):**

Use the Let's Encrypt staging CA while testing. Staging has much higher rate limits — the production CA allows only 5 duplicate certs per week per domain. Staging certs are signed by a fake CA so browsers show an untrusted cert warning, but the full ACME flow is identical to production. Switch to production once you confirm cert issuance works end-to-end.

When staging is active, the Traefik status line shows:
```
ACME CA : STAGING (untrusted certs — use option 4 to switch to production)
```

**Live routing diagnostics (option 6):**

Queries the Traefik API at `localhost:8080` and shows:
- All registered HTTP routers with rules and enabled/error status
- All service backends with health (UP/DOWN) and resolved IP:port
- Container IP addresses on `medianet`
- `DOMAIN` whitespace check (trailing spaces silently break `Host()` rules)
- Certificates currently stored in `acme.json`

**Traefik dashboard access:**

Port 8080 is bound to all interfaces — the dashboard is reachable from the host machine at `http://localhost:8080/dashboard/` or from any machine on your LAN at `http://YOUR_SERVER_IP:8080/dashboard/`. This is useful when HTTPS isn't working yet and you need to inspect routing. The secured HTTPS dashboard at `https://traefik.yourdomain.com` requires a valid cert and the credentials set in option 1.

> ⚠️ Port 8080 has no authentication. Do not forward it through your router to the internet.

---

### Step 6 — Set service credentials *(required for VPN, AMP, Mumble)*
**`sudo friendbox` → option 5**

Only shows options for services you have selected.

| Service | What is configured |
|---|---|
| **qBittorrentVPN / DelugeVPN** | VPN provider, client type (openvpn/wireguard), username, password, LAN CIDR |
| **AMP** | Admin username and password |
| **Mumble** | Superuser password |
| **Jellyfin** | Hardware acceleration method (VA-API / NVENC / None) + full diagnostic tool |

> **VPN LAN CIDR note:** The default value includes your home LAN subnet (`192.168.1.0/24`) and the Docker bridge subnet assigned to `medianet` (detected automatically from the live network). Both are required — the home subnet allows your LAN devices through the VPN firewall, and the Docker bridge subnet allows Traefik to reverse-proxy the VPN container while the tunnel is active. If your home network uses a different subnet (e.g. `192.168.0.0/24`), update the first entry accordingly.

---

### Step 7 — Configure DNS records *(required for HTTPS)*
**`sudo friendbox` → option 6**

Each selected container gets its own subdomain (e.g. `portainer.yourdomain.com`, `sonarr.yourdomain.com`). Your domain must resolve to your server's public IP before Let's Encrypt can issue certificates.

| Sub-option | Function |
|---|---|
| 1–4 | Configure Cloudflare / DuckDNS / GoDaddy / Namecheap credentials |
| 5 | Update DNS now (push current public IP to all A records, then verify propagation via 1.1.1.1) |
| 6 | Show subdomains that will be managed |
| 7 | Install auto-update cron job (runs every 5 minutes) |
| 8 | Remove auto-update cron job |

> DNS propagation can take minutes to hours. Traefik retries certificate issuance automatically — no restart needed.

---

### Step 8 — Verify everything is running
**`sudo friendbox` → option 10 and option 11**

```
sudo friendbox  →  option 10   (Show container status)
sudo friendbox  →  option 11   (View service URLs)
```

Option 11 shows your full URL list. With Traefik selected it shows HTTPS subdomain addresses; without Traefik it shows direct `http://ip:port` addresses. If TeamSpeak 6 is selected, the admin privilege token is surfaced here automatically if it has been printed to the container logs.

> **Pre-flight warnings:** Full Install (option 1) runs a pre-flight check before starting containers. If your domain, ACME email, or ACME provider look incomplete, it will list the issues and ask whether to continue. These are warnings — you can proceed and fix them afterward via option 4. Port conflicts are also checked automatically before any `compose up`.

**First-time login reference:**

| Service | Default URL | First login |
|---|---|---|
| Traefik dashboard | `http://YOUR_SERVER_IP:8080/dashboard/` or `http://localhost:8080/dashboard/` | No auth — LAN accessible. Do not expose port 8080 to the internet. |
| Traefik (HTTPS) | `https://traefik.yourdomain.com` | Credentials set in option 4 → option 1 |
| Portainer | `https://portainer.yourdomain.com` | Create admin account on first visit |
| Plex | `https://plex.yourdomain.com` | Sign in with Plex account, set library paths to `/movies`, `/tv` |
| Jellyfin | `https://jellyfin.yourdomain.com` | Create admin account, set library paths to `/data/tv`, `/data/movies` |
| Sonarr | `https://sonarr.yourdomain.com` | Add root folder `/tv`, connect Prowlarr + download client |
| Radarr | `https://radarr.yourdomain.com` | Add root folder `/movies`, connect Prowlarr + download client |
| Prowlarr | `https://prowlarr.yourdomain.com` | Add indexers, sync to Sonarr/Radarr |
| Bazarr | `https://bazarr.yourdomain.com` | Connect Sonarr + Radarr, configure subtitle providers |
| qBittorrent | `https://qbt.yourdomain.com` (`http://IP:8082` direct) | Default: `admin` / `adminadmin` — **change immediately** |
| qBittorrentVPN | `https://qbtvpn.yourdomain.com` (`http://IP:8181` direct) | Same default credentials — **change immediately** |
| DelugeVPN | `https://deluge.yourdomain.com` (`http://IP:8112` direct) | Default password: `deluge` — **change immediately** |
| NZBGet | `https://nzbget.yourdomain.com` (`http://IP:6789` direct) | Default: `nzbget` / `tegbzn6789` — **change immediately** |
| Overseerr | `https://overseerr.yourdomain.com` | Sign in with Plex account |
| Ombi | `https://ombi.yourdomain.com` (`http://IP:3579` direct) | Create admin account on first visit |
| Jellyseerr | `https://jellyseerr.yourdomain.com` (`http://IP:5056` direct) | Sign in with Jellyfin account |
| AMP | `https://amp.yourdomain.com` (`http://IP:8085` direct) | Credentials set in option 5 |
| NetbootXYZ | `https://netboot.yourdomain.com` (`http://IP:3000` direct) | No auth by default |
| TeamSpeak 6 | No web UI — connect with the TS6 client to `yourserver:9987` (UDP) | Server admin token printed in container logs on first start: `docker logs teamspeak6` |
| Mumble | No web UI — connect with a Mumble client to `yourserver:64738` | Superuser password set in option 5 |

---

### Step 9 — Connect Sonarr / Radarr / Prowlarr

All containers share the `medianet` Docker bridge and communicate by container name. Use these internal addresses when connecting services to each other — not external domains or host IPs:

| Service | Internal address |
|---|---|
| Prowlarr | `http://prowlarr:9696` |
| Sonarr | `http://sonarr:8989` |
| Radarr | `http://radarr:7878` |
| Bazarr | `http://bazarr:6767` |
| Plex | `http://plex:32400` |
| Jellyfin | `http://jellyfin:8096` |
| qBittorrent | `http://qbittorrent:8080` |
| qBittorrentVPN | `http://qbittorrentvpn:8080` |
| DelugeVPN | `http://delugevpn:8112` |
| NZBGet | `http://nzbget:6789` |
| Overseerr | `http://overseerr:5055` |
| Ombi | `http://ombi:3579` |
| Jellyseerr | `http://jellyseerr:5055` |

> Note: Jellyseerr's **internal** port is `5055`. The host binding is `5056` (to avoid clashing with Overseerr when both are running), but container-to-container traffic always uses the internal port.

**Recommended connection order:**
1. Prowlarr → add your indexers
2. Sonarr → Settings → Download Clients → add qBittorrent at `http://qbittorrent:8080`
3. Sonarr → Settings → Apps → connect Prowlarr at `http://prowlarr:9696`
4. Radarr → repeat the same steps as Sonarr
5. Overseerr / Jellyseerr → connect to Plex or Jellyfin, then Sonarr and Radarr

---

## 📋 Full Menu Reference

### Setup

| Option | Function | Notes |
|---|---|---|
| 1 | Full Install | Runs all setup steps in sequence. Warns if already installed. |
| 2 | Select containers | Toggle which services to deploy. |
| 3 | Configure .env | Domain, paths, PUID/PGID, timezone. |
| 4 | Traefik configuration | Credentials, domain, ACME provider, staging toggle, pre-flight checks, live diagnostics, emergency recovery, root redirect target. |
| 5 | Service credentials & hardware acceleration | VPN, AMP, Mumble credentials + Jellyfin hardware acceleration setup and diagnostics. Only shows options for selected services. |
| 6 | DNS A record manager | Cloudflare / DuckDNS / GoDaddy / Namecheap. |
| 7 | MergerFS storage manager | Pool setup, disk management, drive details, ownership fix. |

### Operations

| Option | Function | Notes |
|---|---|---|
| 8 | Provision / fix directory ownership | Creates config and media dirs, fixes permissions. |
| 9 | Sync latest files from GitHub | Re-downloads compose file and setup script. Validates both before applying. |
| 10 | Show container status | Runs `docker compose ps` for selected containers. |
| 11 | View service URLs | HTTPS URLs (Traefik) or `ip:port` URLs (no Traefik). Also surfaces the TeamSpeak 6 admin token if available. |
| 12 | Redeploy containers | Pull latest images, redeploy all or single container, restart, change selection. |
| 13 | Update stack | Sync files from GitHub, pull latest images, restart. Reports which images actually changed versus already current. |
| 14 | View logs | Follow live logs or dump last 200 lines for all containers or a specific one. |
| 15 | Check port conflicts | Checks whether any ports needed by selected containers are already in use. Available before Full Install. |
| 16 | Backup & Restore | Create, restore, and delete timestamped config backups. Backups stored in `/opt/friendbox/backups/`. Available before Full Install. |
| 17 | Teardown | Stops and removes containers, removes Docker network. Config and data preserved. |
| 18 | Full Reset | Uninstalls everything — containers, images, configs, and the `friendbox` binary. Media files and backups are NOT deleted. Requires typing `RESET` to confirm. |

> **Options 10–14 and 17 are blocked until Full Install has been completed.** Options 15 (Check port conflicts) and 16 (Backup & Restore) are available before install. The menu header shows `✔ INSTALLED` or `○ NOT YET INSTALLED`.

---

## 🔒 Traefik & HTTPS Details

### How routing works

- `exposedByDefault: false` — only containers with `traefik.enable=true` get routes
- Every container has `traefik.enable=true` and `traefik.docker.network=medianet` hardcoded in its labels
- The Docker `profiles:` key controls whether a container starts — a stopped container is simply not routed
- Each router has `tls=true` and `tls.certresolver=letsencrypt` — Traefik requests and renews certs automatically
- All containers also expose direct host ports for LAN access without Traefik

### DuckDNS wildcard certificate

When DuckDNS is selected as the ACME provider, Friendbox configures the `websecure` entrypoint to request a single wildcard cert covering all subdomains at once. The domain is read from your `.env` at config-generation time — nothing is hardcoded:

```yaml
websecure:
  address: ":443"
  http:
    tls:
      domains:
        - main: "yourdomain.duckdns.org"
          sans:
            - "*.yourdomain.duckdns.org"
```

The DuckDNS API sets `_acme-challenge.yourdomain.duckdns.org` — Let's Encrypt validates it once for the wildcard rather than attempting per-subdomain validation (which DuckDNS cannot support). Individual routers inherit this cert automatically; no `certresolver` label is set on them when DuckDNS is the provider.

### acme.json permissions

`acme.json` must be `root:root 600`. Traefik v3 runs as root inside the container — if the file is owned by another user, Traefik can read existing certs but cannot write renewals, causing an endless `Testing certificate renew` loop in the logs.

### Testing behind a firewall (LAN-only HTTPS)

If ports 80/443 on your router point to a different machine, you can still test HTTPS internally by adding DNS overrides in OPNsense (or your local DNS resolver):

**Services → Unbound DNS → Host Overrides — add two entries:**

| Host | Domain | IP |
|---|---|---|
| `*` | `yourdomain.duckdns.org` | Friendbox LAN IP |
| `yourdomain` | `duckdns.org` | Friendbox LAN IP |

This makes `*.yourdomain.duckdns.org` resolve to your Friendbox machine from inside the LAN only. Internet traffic is unaffected. DNS-01 cert acquisition still works because it uses the DuckDNS API directly and requires no inbound connections.

### Running alongside another reverse proxy (OPNsense HAProxy SNI routing)

If another reverse proxy is already handling ports 80/443 on your LAN for a different domain, use OPNsense HAProxy with SNI passthrough:

- HAProxy reads the TLS SNI hostname before decryption and routes accordingly
- `*.yourdomain.duckdns.org` → Friendbox machine port 443
- `*.otherdomain.com` → other machine port 443
- Each machine handles its own certificates independently with no conflicts

Enable HAProxy via: **System → Firmware → Plugins → `os-haproxy`**

---

## 🔁 Updating and Redeploying

### Auto-update on launch

Every `sudo friendbox` launch downloads the latest `docker-compose.yml` and `setup.sh` from GitHub. Both files are validated (syntax check for the script, YAML parse for the compose file) before replacing the live copies. If an update is found the script re-executes itself automatically. No manual sync needed.

### Pull latest container images

```bash
sudo friendbox  →  option 13
```

### Backup and restore config

```bash
sudo friendbox  →  option 16
```

Option 16 opens the Backup & Restore menu. It creates a timestamped `.tar.gz` of all container config directories plus key state files (`.env`, `.selected_containers`, `.dns_config`). `acme.json` is intentionally excluded — it is environment-specific and will be regenerated. Backups are stored in `/opt/friendbox/backups/` (root:root 600) and the 10 most recent are kept automatically.

To restore: option 16 → option 2 → select an archive. The restore extracts over the current config and re-applies correct acme.json permissions. Running containers are not stopped — redeploy after restore to apply changes.

### Full uninstall

```bash
sudo friendbox  →  option 18
```

Removes all containers, pulled images, the `medianet` network, all config data, state files, and the `friendbox` binary. Requires typing `RESET` to confirm. Media files in your media root and any existing backups in `/opt/friendbox/backups/` are **not** touched.

### Redeploy a single container

```bash
sudo friendbox  →  option 12  →  option 2  →  select from numbered list
```

### Redeploy via helper script

```bash
sudo /opt/friendbox/scripts/redeploy.sh              # redeploy all
sudo /opt/friendbox/scripts/redeploy.sh sonarr        # redeploy one
sudo /opt/friendbox/scripts/redeploy.sh --restart     # restart without pulling
sudo /opt/friendbox/scripts/redeploy.sh --health      # health check
```

---

## 📁 File Layout

```
/usr/local/bin/friendbox              # The friendbox command (auto-updated on launch)

/opt/friendbox/
├── .env                              # Environment variables (domain, paths, UID/GID)
├── backups/                          # Config backups created by option 16 (root:root 600)
│   └── friendbox_backup_YYYYMMDD_HHMMSS.tar.gz
├── .state                            # Internal state
├── .installed                        # Written by Full Install, cleared by Teardown
├── .selected_containers              # Active container selection
├── .mergerfs_modes                   # Per-disk MergerFS mode (RW/NC/RO)
├── .mergerfs_pool                    # MergerFS pool mount path
├── .dns_config                       # DNS provider credentials (chmod 600)
├── docker-compose.yml                # Full service stack
├── config/
│   ├── traefik/
│   │   ├── traefik.yml               # Generated by Friendbox — do not edit manually
│   │   ├── acme.json                 # Let's Encrypt certificates (root:root 600)
│   │   └── dynamic/
│   │       └── headers.yml           # Security headers middleware (HSTS, X-Frame, etc)
│   ├── portainer/
│   ├── plex/
│   ├── sonarr/
│   └── ...                           # One folder per container
└── scripts/
    └── redeploy.sh                   # Standalone redeploy helper
```

> `traefik.yml` is fully generated from your `.env` settings and ACME provider selection. Do not edit manually — it will be overwritten. Use option 4 to make changes.

---

## 🔒 Security Notes

- `acme.json` is always `root:root 600` — required for Traefik v3 to write cert renewals
- `.dns_config` is `chmod 600` — contains DNS provider API keys
- The Traefik HTTPS dashboard requires bcrypt Basic Auth credentials (option 4 → option 1)
- The Traefik API at `:8080` has no authentication — it is accessible from any machine on your LAN. Do not forward port 8080 through your router to the internet
- qBittorrent default credentials (`admin` / `adminadmin`) must be changed immediately after first login
- `exposedByDefault: false` — only explicitly labeled containers get Traefik routes
- All inter-container traffic uses the `medianet` bridge — nothing reaches the internet except through Traefik on ports 80 and 443
- qBittorrent binds host port `8082` (not 8080) to avoid conflicting with Traefik's API on port 8080
- Jellyseerr binds host port `5056` (not 5055) to avoid conflicting with Overseerr when both are selected
- TeamSpeak 6 WebAuth port `10080` is commented out by default — enable manually only if needed and with appropriate firewall rules

---

## 🐛 Troubleshooting

**`Testing certificate renew` loop in Traefik logs**
- `acme.json` is owned by the wrong user. Fix: `sudo chown root:root /opt/friendbox/config/traefik/acme.json && sudo chmod 600 /opt/friendbox/config/traefik/acme.json`
- Clear stale data and restart: `sudo truncate -s 0 /opt/friendbox/config/traefik/acme.json && docker restart traefik`

**Hit Let's Encrypt rate limit (5 certs/week)**
- Switch to staging CA to continue testing: option 4 → option 4
- The pre-flight check (option 4 → option 5) queries crt.sh and shows remaining slots and reset time

**404 on HTTPS subdomain after accepting cert warning**
- Run live routing diagnostics: option 4 → option 6
- Check all routers are registered and backends show UP
- Confirm `DOMAIN` in `.env` has no trailing whitespace — the diagnostics check will flag this
- Restart containers to apply latest labels: `docker compose down && docker compose up -d`

**Subdomain accessible via IP:port but not via HTTPS**
- Confirm container is on `medianet`: `docker inspect <container> --format '{{json .NetworkSettings.Networks}}'`
- Check Traefik sees the backend: `curl -s http://localhost:8080/api/http/services/<n>@docker | python3 -m json.tool`
- Confirm DNS resolves correctly: `nslookup portainer.yourdomain.com`

**MergerFS: writes appearing on RO drive**
- RO branches must never have subdirectories created on them
- Run option 7 → option 7 to fix ownership and recreate subdirs only on RW/NC branches
- Remount pool to apply current mode settings: option 7 → option 6

**MergerFS pool not mounted after reboot**
- Check fstab entry: `grep mergerfs /etc/fstab`
- Manually remount: option 7 → option 6
- Check individual drive mount status: option 7 → option 5

**Containers running but ports unreachable (127.0.0.1:9000, LAN IP:port refused)**
- This is most commonly Ubuntu's `ufw` firewall conflicting with Docker. ufw's default `FORWARD` policy is `DROP`, which blocks Docker's iptables DNAT rules even for connections on localhost.
- Fix: set `DEFAULT_FORWARD_POLICY=ACCEPT` in `/etc/default/ufw` and run `sudo ufw reload`
- Verify after fix: `curl -s http://localhost:9000` (Portainer) or `curl -s http://localhost:8096` (Jellyfin)

**Container fails to start, port already in use**
- Full Install automatically runs a port conflict check before `compose up`. If a conflict was detected and you chose to continue, the conflicting process needs to be stopped.
- Find what's using a port: `sudo ss -tlnp | grep :<port>`
- If the holder is a prior Docker process: `docker ps -a` then `docker rm -f <name>`

**Permission errors in container logs**
- Run option 8 to fix all directory ownership
- Confirm PUID/PGID match your media files: `ls -lan /mnt/media`

**VPN containers not connecting**
- Confirm credentials are saved: option 5
- Check required vars are present: `grep -E "VPN_PROV|VPN_CLIENT|VPN_USER|VPN_PASS|LAN_NETWORK" /opt/friendbox/.env`
- Check logs: option 14 → `qbittorrentvpn` or `delugevpn`

**VPN container Traefik backend shows DOWN**
- The binhex VPN images use `LAN_NETWORK` to build iptables rules for traffic allowed through the VPN firewall. If the `medianet` Docker bridge subnet is not included in `LAN_NETWORK`, Traefik's reverse proxy traffic to the container is silently dropped.
- Fix: option 5 → VPN credentials → ensure `LAN_NETWORK` includes the Docker bridge subnet alongside your home subnet. The correct subnet is shown as the default when you run the VPN credentials prompt — it is detected automatically from the live `medianet` network.
- After saving, redeploy the VPN container: option 12 → option 2

**TeamSpeak 6 WebAuth (port 10080) not accessible**
- Port 10080 is commented out by default. To enable it, edit `/opt/friendbox/docker-compose.yml` and uncomment the `10080:10080` port line and the four Traefik label lines in the `teamspeak6` service, then redeploy: option 12 → option 2 → select TeamSpeak 6

**TeamSpeak 6 admin token not showing after install**
- Option 1 automatically checks container logs and displays the token in the post-install summary. If it didn't appear, the container may not have started yet when the check ran.
- Retrieve it manually: `docker logs teamspeak6 | grep -i token`
- The token is only printed once on first start. Once used it is consumed and will not appear again.

**Script not updating on launch**
- Always use `sudo friendbox` — auto-update requires root
- Manually trigger sync: option 9
