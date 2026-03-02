# 📦 Friendbox

A fully automated, menu-driven Docker media server stack for Ubuntu 24.04.4 LTS.

**Includes:** Traefik · Portainer · Plex · Jellyfin · Sonarr · Radarr · Prowlarr · Bazarr · qBittorrent · qBittorrentVPN · DelugeVPN · NZBGet · Overseerr · Ombi · Jellyseerr · TeamSpeak 6 · Mumble · AMP (game servers) · NetbootXYZ

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

### 1. Bootstrap (run once)

```bash
curl -fsSL https://raw.githubusercontent.com/xkronusx/friendbox/main/setup.sh | sudo bash
```

This downloads the setup script to `/usr/local/bin/friendbox`. It does **not** install anything else — just makes the `friendbox` command available.

### 2. Launch the menu

```bash
sudo friendbox
```

Every time you run `sudo friendbox`, the script automatically pulls the latest files from GitHub before opening the menu, so you are always running the most current version. If GitHub is unreachable, it falls back to the local copy silently.

---

## 🗂 First-Time Setup — Step by Step

Follow these steps **in order**. Steps 1–4 are required. Steps 5–6 are optional but recommended.

---

### Step 1 — MergerFS storage pool *(skip if using a single drive)*
**`sudo friendbox` → option 7**

If you have multiple physical drives you want to pool into a single `/mnt/media` path, set this up first — before configuring your environment — because the pool path becomes your media root.

**Before running this step:**
- Mount each drive to its own path (e.g. `/mnt/disk1`, `/mnt/disk2`).
- Ensure drives are formatted (ext4 recommended) and in `/etc/fstab` so they survive reboots.

**During setup:**
1. Enter each disk path one at a time and assign a mode:
   - `RW` — Read/Write. New files can be written here.
   - `NC` — No-Create. Existing files are readable, but no new files land here. Good for an OS drive or an almost-full drive you want to drain gradually.
   - `RO` — Read-Only. No writes at all.
2. Set the pool mount point (default: `/mnt/media`).
3. Optionally mark the OS drive as `NC` to prevent media writes to your system disk.

MergerFS writes an `fstab` entry and mounts the pool live — no reboot needed.

**If you skip MergerFS**, make sure your intended media root exists and is writable before continuing:
```bash
mkdir -p /mnt/media && chown 1000:1000 /mnt/media
```

---

### Step 2 — Configure your environment
**`sudo friendbox` → option 3**

Sets the core variables written to `/opt/friendbox/.env`. All other steps depend on this.

You will be prompted for:

| Prompt | Description |
|---|---|
| **Domain** | Your registered domain (e.g. `example.com`). Must be a domain you control. |
| **ACME email** | Used by Let's Encrypt to issue HTTPS certificates. Use a real address. |
| **Media root** | Where your media library lives. If you completed Step 1, this should match your MergerFS pool path (default: `/mnt/media`). |
| **Config root** | Where container config data is stored (default: `/opt/friendbox/config`). |
| **PUID / PGID** | The Linux user and group ID containers will run as. Default `1000:1000` is correct for the first non-root user on a fresh Ubuntu install. Run `id` to confirm. |
| **Timezone** | e.g. `America/Toronto`. Used by all containers for correct timestamps. |

Press **Enter** on any prompt to keep the current value shown in brackets.

> ⚠️ The domain and ACME email cannot be changed after containers start without clearing `acme.json` and restarting Traefik. Set these correctly the first time.

---

### Step 3 — Select containers
**`sudo friendbox` → option 2**

Choose which services to deploy. Toggle with the item number. Press `d` when done.

**Recommended minimum for a media server:**
- ✔ Plex or Jellyfin (media playback)
- ✔ Sonarr + Radarr (TV show and movie library management)
- ✔ Prowlarr (indexer manager — required for Sonarr/Radarr)
- ✔ qBittorrent or qBittorrentVPN/DelugeVPN (download client)

**Notes on specific containers:**
- **qBittorrentVPN / DelugeVPN** — require VPN credentials. Set these via option 5 (Service credentials) before deploying.
- **AMP** — requires an admin username and password. Set these via option 5.
- **Mumble** — requires a superuser password. Set via option 5.
- **Prowlarr** — uses the `nightly` tag for the latest indexer support.

Your selection is saved and persists between runs.

---

### Step 4 — Full Install
**`sudo friendbox` → option 1**

Runs the complete first-time setup in sequence:

1. OS compatibility check (warns if not Ubuntu 24.04.4)
2. Installs dependencies: Docker CE, curl, apache2-utils. Reports mergerfs status (installed separately via option 7 if needed).
3. Pulls latest `docker-compose.yml` and config files from GitHub
4. Prompts for environment configuration (your `.env`)
5. Opens container selection
6. Creates the `medianet` Docker bridge network
7. Sets up `acme.json` with correct permissions for Traefik
8. Provisions all config and media directories
9. Starts all selected containers with `docker compose up -d`

If Friendbox is already installed, option 1 will warn you and ask for confirmation before proceeding — this prevents accidentally overwriting a running stack.

---

### Step 5 — Configure Traefik *(required if Traefik is selected)*
**`sudo friendbox` → option 4**

Sets the dashboard credentials for the Traefik web UI. This is separate from the main `.env` so you can update it without re-running the full environment setup.

| Sub-option | What it does |
|---|---|
| 1) Set dashboard credentials | Prompts for username and password, generates a bcrypt hash |
| 2) Update domain / ACME email | Updates just the domain and ACME email in `.env` |

Press Enter on the password prompt to keep the existing credentials.

---

### Step 6 — Set service credentials *(required for VPN, AMP, Mumble)*
**`sudo friendbox` → option 5**

The menu is dynamic — it only shows options for services you have selected. Press Enter to keep any existing value.

| Service | What is configured |
|---|---|
| **VPN** (qBittorrentVPN / DelugeVPN) | Provider (pia, mullvad, airvpn, custom), client type (openvpn/wireguard), username, password, LAN CIDR |
| **AMP** | Admin username and password |
| **Mumble** | Superuser password |

---

### Step 7 — Configure DNS A records *(required for HTTPS)*
**`sudo friendbox` → option 6**

Your domain must resolve to your server's public IP before Let's Encrypt can issue a certificate. Each selected container gets its own subdomain:

```
traefik.yourdomain.com
portainer.yourdomain.com
plex.yourdomain.com
sonarr.yourdomain.com
... etc.
```

**Supported providers:**

| Provider | Notes |
|---|---|
| **Cloudflare** | Creates/updates A records via API. Zone ID is auto-detected. |
| **DuckDNS** | Updates a single free subdomain (e.g. `myhome.duckdns.org`). |
| **GoDaddy** | Creates/updates A records via GoDaddy Production API. |
| **Namecheap** | Updates via Namecheap Dynamic DNS (one host per request). |

After configuring your provider, use **"Update DNS now"** (sub-option 5) to push all records immediately. Optionally install the **cron job** (sub-option 7) to keep records current every 5 minutes — useful if your home IP changes.

> ⚠️ DNS propagation can take minutes to hours. Traefik retries certificate issuance automatically — you do not need to restart anything.

> ⚠️ Ports 80 and 443 must be open and forwarded to this machine before Let's Encrypt will issue certificates.

---

### Step 8 — Verify everything is running
**`sudo friendbox` → option 10 and option 11**

Check that all containers are healthy:

```
sudo friendbox  →  option 10  (Show container status)
sudo friendbox  →  option 11  (View service URLs)
```

Option 11 shows the real URLs for your stack — with Traefik it shows the full HTTPS subdomain addresses; without Traefik it detects your server's local IPv4 and shows direct `http://ip:port` addresses.

Traefik issues HTTPS certificates automatically — this typically completes within 1–2 minutes of first startup.

**First-time login reference:**

| Service | URL (with Traefik) | First-time setup |
|---|---|---|
| Traefik | `https://traefik.yourdomain.com` | Login with your configured dashboard credentials |
| Portainer | `https://portainer.yourdomain.com` | Create admin account on first visit |
| Plex | `https://plex.yourdomain.com` | Sign in with Plex account, set library paths |
| Sonarr | `https://sonarr.yourdomain.com` | Add root folder `/tv`, connect to download client and Prowlarr |
| Radarr | `https://radarr.yourdomain.com` | Add root folder `/movies`, connect to download client and Prowlarr |
| Prowlarr | `https://prowlarr.yourdomain.com` | Add indexers, then sync to Sonarr/Radarr |
| qBittorrent | `https://qbt.yourdomain.com` | Default login: `admin` / `adminadmin` — **change immediately** |

---

### Step 9 — Connect Sonarr / Radarr / Prowlarr

All containers share the `medianet` Docker bridge network and communicate by container name — not by external domain or IP. Use these internal addresses when connecting services to each other:

| Service | Internal address |
|---|---|
| qBittorrent | `http://qbittorrent:8080` |
| qBittorrentVPN | `http://qbittorrentvpn:8080` |
| DelugeVPN | `http://delugevpn:8112` |
| NZBGet | `http://nzbget:6789` |
| Prowlarr | `http://prowlarr:9696` |
| Sonarr | `http://sonarr:8989` |
| Radarr | `http://radarr:7878` |
| Jellyfin | `http://jellyfin:8096` |

**Recommended connection order:**
1. Prowlarr → add your indexers
2. Sonarr → Settings → Download Clients → add qBittorrent at `http://qbittorrent:8080`
3. Sonarr → Settings → Apps → connect Prowlarr
4. Radarr → repeat the same as Sonarr
5. Overseerr / Jellyseerr → connect to Plex or Jellyfin, then Sonarr and Radarr

---

## 📋 Full Menu Reference

### Setup

| Option | Function | Notes |
|---|---|---|
| 1 | Full Install | Runs all setup steps in sequence. Warns if already installed. |
| 2 | Select containers | Toggle which services to deploy. |
| 3 | Configure .env | Domain, paths, PUID/PGID, timezone. |
| 4 | Traefik configuration | Dashboard credentials, domain, ACME email. |
| 5 | Service credentials | VPN, AMP, Mumble credentials (dynamic — shows only what's selected). |
| 6 | DNS A record manager | Configure Cloudflare / DuckDNS / GoDaddy / Namecheap. |
| 7 | MergerFS storage manager | Pool setup, disk management, drive detail view. |

### Operations

| Option | Function | Notes |
|---|---|---|
| 8 | Provision / fix directory ownership | Creates config and media dirs, fixes permissions. |
| 9 | Sync latest files from GitHub | Re-downloads compose file, Traefik config, and the friendbox script. |
| 10 | Show container status | Runs `docker compose ps` for all selected containers. |
| 11 | View service URLs | Shows HTTPS URLs (Traefik) or `ip:port` URLs (no Traefik). |
| 12 | Redeploy containers | Pull latest images, redeploy all or a single container, restart, or change selection. |
| 13 | Update stack | Pulls latest images and restarts the stack. |
| 14 | View logs | Tail logs for all containers or a specific one. |
| 15 | Teardown | Stops and removes all containers. Config and data are preserved. Clears the installed flag so option 1 can be used again. |

> **Operations (10–15) are blocked until a Full Install has been completed.** The menu shows `● INSTALLED` or `○ NOT YET INSTALLED` at the top so you always know the current state.

---

## 🔁 Updating and Redeploying

### Auto-update on launch

Every time you run `sudo friendbox`, the script silently downloads the latest `docker-compose.yml`, Traefik config, and `setup.sh` from GitHub before opening the menu. If an update is downloaded, the script re-launches itself so you are always running the freshest code. No manual sync is needed.

### Pull latest container images

```bash
sudo friendbox  →  option 13
```

### Redeploy a single container

```bash
sudo friendbox  →  option 12  →  option 2  →  enter container name
```

### Redeploy all containers

```bash
sudo friendbox  →  option 12  →  option 1
```

### Redeploy via helper script

```bash
sudo /opt/friendbox/scripts/redeploy.sh            # redeploy all
sudo /opt/friendbox/scripts/redeploy.sh sonarr     # redeploy one
sudo /opt/friendbox/scripts/redeploy.sh --restart  # restart without pulling
sudo /opt/friendbox/scripts/redeploy.sh --health   # health check
```

---

## 📁 File Layout

```
/usr/local/bin/friendbox          # The friendbox command (auto-updated on launch)

/opt/friendbox/
├── .env                          # Environment variables (domain, paths, UID/GID)
├── .state                        # Internal state (media root path)
├── .installed                    # Install timestamp — written by Full Install, cleared by Teardown
├── .selected_containers          # Which containers are active
├── .mergerfs_modes               # Per-disk MergerFS mode (RW/NC/RO)
├── .mergerfs_pool                # MergerFS pool mount path
├── .dns_config                   # DNS provider credentials (chmod 600)
├── docker-compose.yml            # Full service stack (auto-updated on launch)
├── config/
│   ├── traefik/
│   │   ├── traefik.yml           # Traefik static config (auto-updated on launch)
│   │   └── acme.json             # Let's Encrypt certificates (chmod 600, root-owned)
│   ├── portainer/
│   ├── plex/                     # One folder per selected container
│   ├── sonarr/
│   └── ...
└── scripts/
    └── redeploy.sh               # Standalone redeploy helper (auto-updated on launch)
```

---

## 🔒 Security Notes

- `acme.json` is always `chmod 600` and root-owned — Traefik requires this.
- `.dns_config` is `chmod 600` — contains API keys.
- The Traefik dashboard is protected by bcrypt HTTP Basic Auth (set via option 4).
- qBittorrent's default credentials (`admin` / `adminadmin`) must be changed immediately after first login.
- `exposedByDefault: false` in Traefik — only containers with explicit labels get public routes.
- All containers communicate internally via the `medianet` bridge — nothing is exposed to the internet except through Traefik on ports 80 and 443.

---

## 🐛 Troubleshooting

**Certificates not issuing**
- Confirm ports 80 and 443 are open and forwarded to this machine.
- Confirm DNS A records point to your server's public IP: `dig +short traefik.yourdomain.com`
- Check Traefik logs: `sudo friendbox` → option 14 → enter `traefik`

**Container won't start**
- Check logs: `sudo friendbox` → option 14 → enter the container name
- Re-run directory provisioning: option 8
- Verify `.env` is correct: `cat /opt/friendbox/.env`

**Permission errors in container logs**
- Run `sudo friendbox` → option 8 to fix directory ownership
- Confirm PUID/PGID in `.env` match the owner of your media files: `ls -lan /mnt/media`

**VPN containers not connecting**
- Confirm credentials are saved: `sudo friendbox` → option 5
- Check that `VPN_PROV`, `VPN_CLIENT`, `VPN_USER`, `VPN_PASS`, and `LAN_NETWORK` are all set in `/opt/friendbox/.env`
- Check container logs: `sudo friendbox` → option 14 → enter `qbittorrentvpn` or `delugevpn`

**MergerFS pool not mounted after reboot**
- Confirm the pool entry exists in `/etc/fstab`: `grep mergerfs /etc/fstab`
- Check pool status: `sudo friendbox` → option 7 → option 6
- Manually mount: `sudo mount /mnt/media`

**Script not updating on launch**
- The auto-update requires root. Always run `sudo friendbox`, not `friendbox`.
- If offline, the script falls back to the local copy — run `sudo friendbox` → option 9 when connectivity is restored.

**Wrong OS warning**
- Friendbox is tested on Ubuntu 24.04.4 LTS. Other distros may require manual adjustment of the Docker install steps in `check_deps()`.
