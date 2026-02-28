# 📦 Friendbox

A fully automated, menu-driven Docker media server stack for Ubuntu 24.04.4 LTS.

**Includes:** Traefik (automatic HTTPS) · Portainer · Plex · Jellyfin · Sonarr · Radarr · Prowlarr · Bazarr · qBittorrent · qBittorrentVPN · DelugeVPN · NZBGet · Overseerr · Ombi · Jellyseerr · TeamSpeak 6 · Mumble · AMP (game servers) · NetbootXYZ

---

## ⚙️ System Requirements

| Requirement | Details |
|---|---|
| **OS** | Ubuntu 24.04.4 LTS (Noble Numbat) — tested and supported |
| **Architecture** | x86_64 (amd64) |
| **RAM** | 4 GB minimum, 8 GB+ recommended |
| **Disk** | 20 GB minimum for OS + config; separate drives for media |
| **Network** | Public IP with ports 80 and 443 forwarded to this machine |
| **Domain** | A registered domain name (or DuckDNS free subdomain) |

> Friendbox will warn you and ask for confirmation if run on a non-Ubuntu 24.04 system. It may still work on other Debian-based distros but is not tested or supported.

---

## ⚡ Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/xkronusx/friendbox/main/setup.sh | sudo bash
```

This bootstraps the script to `/usr/local/bin/friendbox`. Then launch the menu at any time:

```bash
sudo friendbox
```

---

## 🗂 Setup Order (First Time)

Follow these steps **in order** for a fully functional installation. Steps 1–6 are **required**. Steps 7–9 are optional enhancements.

---

### ✅ Step 1 — Configure your environment (`.env`)
**Menu option 3**

This is the foundation. All other steps depend on values set here.

You will be prompted for:

- **Domain** — your registered domain (e.g. `example.com`). Must be a domain you control.
- **ACME email** — used by Let's Encrypt to issue your HTTPS certificates. Use a real email.
- **Media root** — where your media library lives (default: `/mnt/media`). If using MergerFS, set this after completing Step 2.
- **Config root** — where container config data is stored (default: `/opt/friendbox/config`).
- **PUID / PGID** — the Linux user ID and group ID containers will run as. Default is `1000:1000`, which is correct for the first non-root user created on a fresh Ubuntu install. Run `id` to confirm your UID/GID.
- **Timezone** — e.g. `America/Toronto`. Used by all containers for correct timestamps.
- **Traefik dashboard password** — secures the Traefik web UI. Requires `apache2-utils` (installed automatically).

> ⚠️ **The domain and ACME email cannot be changed after containers start without clearing `acme.json` and restarting Traefik.** Set these correctly the first time.

---

### ✅ Step 2 — Set up MergerFS storage (if using multiple drives)
**Menu option 5** *(skip if using a single disk)*

MergerFS pools multiple physical drives into a single mount point (default `/mnt/media`) so all containers see one unified path regardless of how many drives you have.

**Before running this step:**
- Mount each physical drive to its own path (e.g. `/mnt/disk1`, `/mnt/disk2`).
- Ensure drives are formatted (ext4 recommended) and listed in `/etc/fstab` so they survive reboots.

**During setup you will:**
1. Enter each disk path and choose its mode:
   - `RW` — Read/Write. Normal — new files can land here.
   - `NC` — No-Create. Reads allowed, but no new files written here. Use this for an OS drive or an almost-full drive you want to drain.
   - `RO` — Read-Only. No writes of any kind.
2. Set the pool mount point (default `/mnt/media`).
3. Optionally set the OS drive as `NC` to redirect new writes away from it.

MergerFS writes fstab entries and mounts the pool live. No reboot needed.

> **If you skip MergerFS**, make sure your Media root path from Step 1 exists and is writable: `mkdir -p /mnt/media && chown 1000:1000 /mnt/media`

---

### ✅ Step 3 — Select your containers
**Menu option 2**

Choose which optional services to install alongside the always-on Traefik and Portainer.

**Recommended minimum for a media server:**
- ✔ Plex or Jellyfin (media playback)
- ✔ Sonarr (TV shows)
- ✔ Radarr (movies)
- ✔ Prowlarr (indexers — required for Sonarr/Radarr to find content)
- ✔ qBittorrent or DelugeVPN (download client)

**Notes on specific containers:**
- **qBittorrentVPN / DelugeVPN** — you will be prompted for VPN credentials (provider, username, password, LAN CIDR). Have these ready.
- **AMP** — you will be prompted to set an admin username and password.
- **Mumble** — you will be prompted to set a superuser password.
- **Prowlarr** uses the `nightly` tag which has the latest indexer updates.

Your selection is saved and remembered between runs.

---

### ✅ Step 4 — Configure DNS A records
**Menu option 4**

Your domain must resolve to your server's public IP before Let's Encrypt can issue a certificate.

**Supported providers:**
| Provider | What it does |
|---|---|
| **Cloudflare** | Creates/updates A records for every selected service via API. Auto-detects Zone ID. |
| **DuckDNS** | Updates a single free subdomain (e.g. `myhome.duckdns.org`). |
| **GoDaddy** | Creates/updates A records via GoDaddy's API. Requires Production API key. |
| **Namecheap** | Updates records via Namecheap Dynamic DNS. One host per request. |

**What gets an A record:**
Every selected container gets its own subdomain pointing to your public IP:
```
traefik.yourdomain.com
portainer.yourdomain.com
plex.yourdomain.com
sonarr.yourdomain.com
... etc.
```

After configuring your provider, use **"Update DNS now"** to push all records immediately. Then optionally install the **cron job** to keep records updated automatically every 5 minutes (useful if your home IP changes).

> ⚠️ DNS propagation can take a few minutes to several hours depending on your registrar. Traefik will retry certificate issuance automatically — you do not need to restart anything.

> ⚠️ **Ports 80 and 443 must be open and forwarded** on your router/firewall to this machine before Let's Encrypt will issue certificates.

---

### ✅ Step 5 — Provision directories
**Menu option 7**

Creates all config and media subdirectories on disk and sets their ownership to your configured PUID:PGID (default `1000:1000`). This prevents containers from starting with root-owned files that they can't write to.

This runs automatically during Full Install (Step 6), but you can run it standalone at any time — for example after adding new containers or if permissions get out of sync.

**What gets created:**
- `/opt/friendbox/config/<container>/` for each selected container
- `/mnt/media/movies/`, `/mnt/media/tv/`, `/mnt/media/downloads/`, `/mnt/media/music/`
- `acme.json` at `chmod 600` (Traefik requirement)

---

### ✅ Step 6 — Full Install
**Menu option 1**

Runs the complete first-time setup in sequence:

1. OS compatibility check (warns if not Ubuntu 24.04.4)
2. Installs dependencies (Docker CE, curl, apache2-utils)
3. Pulls latest `docker-compose.yml` from GitHub
4. Runs environment configuration (Step 1)
5. Runs container selection (Step 3)
6. Creates the `medianet` Docker bridge network
7. Creates and permissions `acme.json`
8. Provisions all directories (Step 5)
9. Starts selected containers with `docker compose up -d`

> If you have already done Steps 1–5 manually, Full Install will use your saved config rather than re-prompting everything.

---

### ☑️ Step 7 — Verify everything is running
**Menu option 8 (Show status) and option 9 (View URLs)**

After startup, check that all containers are healthy:

```
sudo friendbox   →  option 8
```

Then open your browser and visit each service URL. Traefik will automatically issue HTTPS certificates — this typically completes within 1–2 minutes of first startup.

| Service | URL | First-time setup |
|---|---|---|
| Traefik | `https://traefik.yourdomain.com` | Login with your configured password |
| Portainer | `https://portainer.yourdomain.com` | Create admin account on first visit |
| Plex | `https://plex.yourdomain.com` | Sign in with Plex account, set library paths |
| Sonarr | `https://sonarr.yourdomain.com` | Add root folder `/tv`, connect to qBittorrent and Prowlarr |
| Radarr | `https://radarr.yourdomain.com` | Add root folder `/movies`, connect to qBittorrent and Prowlarr |
| Prowlarr | `https://prowlarr.yourdomain.com` | Add indexers, then sync to Sonarr/Radarr |
| qBittorrent | `https://qbt.yourdomain.com` | Default login: `admin` / `adminadmin` (change immediately) |

---

### ☑️ Step 8 — Connect your services (Sonarr/Radarr/Prowlarr)

Because all containers are on the same Docker bridge network (`medianet`), they communicate by container name — **not** by external domain or localhost. Use these internal addresses when connecting apps to each other:

| Service | Internal URL |
|---|---|
| qBittorrent | `http://qbittorrent:8080` |
| qBittorrentVPN | `http://qbittorrentvpn:8080` |
| Deluge (VPN) | `http://delugevpn:8112` |
| NZBGet | `http://nzbget:6789` |
| Prowlarr | `http://prowlarr:9696` |
| Sonarr | `http://sonarr:8989` |
| Radarr | `http://radarr:7878` |
| Jellyfin | `http://jellyfin:8096` |

**Recommended connection order:**
1. Prowlarr → add your indexers
2. Sonarr → Settings → Download Clients → add qBittorrent (`http://qbittorrent:8080`)
3. Sonarr → Settings → Apps → connect Prowlarr
4. Radarr → same as Sonarr
5. Overseerr / Jellyseerr → connect to Plex/Jellyfin, then Sonarr and Radarr

---

### ☑️ Step 9 — Set up automatic DNS updates (optional)
**Menu option 4 → option 7**

If your home IP address changes periodically (most residential ISPs), install the cron job to check and update DNS every 5 minutes automatically. It only makes API calls when the IP actually changes — no unnecessary traffic.

Logs are written to `/var/log/friendbox-dns.log`.

---

## 📋 Full Menu Reference

| Option | Function | Requires root |
|---|---|---|
| 1 | Full Install | ✔ |
| 2 | Select containers | — |
| 3 | Configure .env | — |
| 4 | DNS A record manager | — |
| 5 | MergerFS storage manager | ✔ |
| 6 | Sync files from GitHub | ✔ |
| 7 | Provision / fix directory ownership | ✔ |
| 8 | Show container status | — |
| 9 | View service URLs | — |
| 10 | Redeploy containers | — |
| 11 | Update stack (pull latest images) | ✔ |
| 12 | View logs | — |
| 13 | Teardown (stop & remove containers) | — |

---

## 🔁 Redeploy / Update

To update all containers to their latest image versions:

```bash
sudo friendbox   →  option 11
```

To redeploy a single container without affecting others:

```bash
sudo friendbox   →  option 10 → option 2 → enter container name
```

Or directly via the helper script:

```bash
sudo /opt/friendbox/scripts/redeploy.sh          # redeploy all
sudo /opt/friendbox/scripts/redeploy.sh sonarr   # redeploy one
sudo /opt/friendbox/scripts/redeploy.sh --restart # restart without pulling
sudo /opt/friendbox/scripts/redeploy.sh --health  # health check
```

---

## 📁 File Layout

```
/opt/friendbox/
├── .env                          # Environment variables (domain, paths, UID/GID)
├── .state                        # Internal state (media root path)
├── .selected_containers          # Which optional containers are active
├── .mergerfs_modes               # Per-disk MergerFS mode (RW/NC/RO)
├── .mergerfs_pool                # MergerFS pool mount path
├── .dns_config                   # DNS provider credentials (chmod 600)
├── docker-compose.yml            # Full service stack
├── config/
│   ├── traefik/
│   │   ├── traefik.yml           # Traefik static config
│   │   └── acme.json             # Let's Encrypt certificates (chmod 600, root-owned)
│   ├── portainer/                # Portainer data
│   ├── plex/                     # Plex config (if selected)
│   ├── sonarr/                   # Sonarr config (if selected)
│   └── ...                       # One folder per selected container
└── scripts/
    └── redeploy.sh               # Standalone redeploy helper
```

---

## 🔒 Security Notes

- `acme.json` is always `chmod 600` and root-owned — Traefik requires this.
- `.dns_config` is `chmod 600` — contains API keys.
- The Traefik dashboard is protected by HTTP Basic Auth. Set a strong password.
- qBittorrent's default credentials (`admin` / `adminadmin`) should be changed immediately after first login.
- `exposedByDefault: false` in Traefik — only containers with explicit labels get public routes.
- All containers communicate internally via the `medianet` bridge — nothing is exposed to the internet except through Traefik on ports 80/443.

---

## 🐛 Troubleshooting

**Certificates not issuing**
- Confirm ports 80 and 443 are open and forwarded.
- Confirm DNS A records are pointing to your server's public IP (`dig +short traefik.yourdomain.com`).
- Check Traefik logs: `sudo friendbox` → option 12 → enter `traefik`.

**Container won't start**
- Check logs: `sudo friendbox` → option 12 → enter the container name.
- Re-run directory provisioning: option 7.
- Verify `.env` is correct: `cat /opt/friendbox/.env`.

**Permission errors in container logs**
- Run `sudo friendbox` → option 7 to fix directory ownership.
- Confirm PUID/PGID in `.env` match the owner of your media files (`ls -lan /mnt/media`).

**Wrong OS warning**
- Friendbox is tested on Ubuntu 24.04.4 LTS. Other distros may require manual adjustment of the Docker install steps in `check_deps()`.
