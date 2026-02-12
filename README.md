# friendbox
A fun project for a friend 
Ubuntu media + voice server bootstrap.

Includes:

- GNOME (Wayland)
- Remote Desktop (RDP)
- Docker + Docker Compose
- Jellyfin
- Portainer
- Sonarr
- Radarr
- DelugeVPN (binhex)
- TeamSpeak 6

Storage root: /mnt/friendbox


## Install

```bash
curl -fsSL https://raw.githubusercontent.com/xkronusx/friendbox/main/install.sh | sudo bash
```

After install, log out and back in so Docker group permissions apply.

Services:

Jellyfin → http://SERVER_IP:8096

Portainer → https://SERVER_IP:9443

Sonarr → http://SERVER_IP:8989

Radarr → http://SERVER_IP:7878

DelugeVPN → http://SERVER_IP:8112

TeamSpeak → UDP 9987
