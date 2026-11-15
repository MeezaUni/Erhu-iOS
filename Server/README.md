# Erhu Server

Erhu Server lets Erhu on your iPhone **stream** or **download** music from your own computer
or NAS. Your music never leaves your own devices: Erhu talks straight to your server, and no Erhu
account or online service is involved.

Erhu Server is [Navidrome](https://www.navidrome.org), an open-source music server (GPL-3.0),
used unmodified with settings chosen for Erhu. Erhu also works with any other server that speaks
the Subsonic API (an existing Navidrome, Gonic, Airsonic, Ampache, Jellyfin with its Subsonic
plugin…). This branch (`test-server-option`) is a test build.

## What you need

- A computer or NAS that stays on while you listen (Windows, macOS, Linux, Synology, QNAP,
  Unraid, TrueNAS, a Raspberry Pi…), with your music in a folder.
- The iPhone on the same network (Wi-Fi) for home use. For use away from home, see
  [Outside your home](#outside-your-home).

## 1. Start Erhu Server

### With Docker (recommended: Windows, macOS, Linux and most NAS)

1. Install Docker: [Docker Desktop](https://www.docker.com/products/docker-desktop/) on Windows
   or macOS; on a NAS, its Docker / Container Manager app.
2. Put this folder's `docker-compose.yml` and `.env.example` in a folder on the computer.
3. Copy `.env.example` to `.env` and set `MUSIC_FOLDER` to your music folder.
4. In that folder, run:

   ```sh
   docker compose up -d
   ```

   On a NAS you can instead create a "project" / "stack" from `docker-compose.yml` in its
   container app.

Erhu Server starts with the computer from now on, and picks up music you add to the folder.

### Without Docker

Install Navidrome with its official installer or package for your system (Windows installer,
Linux packages, and others) from the
[Navidrome installation guide](https://www.navidrome.org/docs/installation/).
Then apply the settings in this folder's [`navidrome.toml`](navidrome.toml) (where the file goes
depends on the installation; the guide explains it) and restart Navidrome.

## 2. Create your account

Open `http://<computer address>:4533` in a browser (on the computer itself:
`http://localhost:4533`). The first account you create is the administrator. Make a strong
password.

To find the computer's address on your network:

- **Windows:** Settings → Network & internet → your connection → *IPv4 address*.
- **macOS:** System Settings → Wi-Fi → Details → *IP address*.
- **Linux:** `hostname -I`.
- **NAS:** shown in its control panel.

The address looks like `192.168.1.20`. Giving the computer a fixed (reserved) address in your
router keeps it from changing.

## 3. Connect Erhu

In Erhu: **Settings → Music Server → Add server** (or the side menu → *Music Server*). Enter
`http://<computer address>:4533`, your username and password, and tap **Connect**. The first
time, iOS asks to let Erhu use the local network: allow it.

Then browse your server's albums, artists and playlists, or search it:

- **Tap a song, or Play / Shuffle:** streams from the server. Each song is fetched just before it
  plays and the next songs are fetched ahead, so the equalizer, waveform, transitions and gapless
  playback work as usual. Streamed songs don't join your library.
- **Download to this device:** saves the original files in the Erhu folder under *From Server*;
  they join your library and play without the server.
- **Streaming quality:** *Original file* plays the server's file unchanged. The MP3 settings use
  less data; the server converts each song first, so it can take a little longer to start.

The password is kept in the iPhone's Keychain. Requests use the Subsonic token method, so the
password itself is never sent over the network.

## Outside your home

Don't expose port 4533 to the internet over plain `http://`. The simplest safe option is
[Tailscale](https://tailscale.com): install it on the computer and the iPhone and sign in to both,
turn on HTTPS for your tailnet in its admin console, then run `tailscale serve --bg 4533` on the
computer. Add the `https://<computer>.<tailnet>.ts.net` address it prints as a second server in
Erhu, and use it when you're away from home.

Erhu accepts plain `http://` only for addresses on your local network. Anything else must use
`https://`, through Tailscale or a reverse proxy with a certificate (Caddy, Traefik,
Nginx Proxy Manager).

## Updating and backups

- **Update (Docker):** `docker compose pull && docker compose up -d`.
- **Back up:** the `erhu_server_data` volume (Docker) or Navidrome's data folder holds accounts,
  play counts and playlists. Your music folder is only read, never changed.

## Licence

Navidrome is © its contributors and licensed under the
[GNU GPL v3.0](https://github.com/navidrome/navidrome/blob/master/LICENSE). Erhu Server uses the
official, unmodified Navidrome image or packages; this folder only adds configuration. Erhu
connects to it over the network through the public Subsonic API and contains no Navidrome code.
See [ThirdParty/NAVIDROME-NOTICE.md](../ThirdParty/NAVIDROME-NOTICE.md).
