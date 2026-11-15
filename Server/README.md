# Erhu Server

Erhu Server lets Erhu on your iPhone **stream** or **download** music from your own computer
or NAS. Your music never leaves your own devices: Erhu talks straight to your server, and no Erhu
account or online service is involved.

Erhu Server is [Navidrome](https://www.navidrome.org), an open-source music server (GPL-3.0),
used unmodified with settings chosen for Erhu. Erhu also works with any other server that speaks
the Subsonic API (an existing Navidrome, Gonic, Airsonic, Ampache, Jellyfin with its Subsonic
plugin…). This branch (`test-server-option`) is a test build.

## Which setup is for you?

| You have | Use |
| --- | --- |
| A Windows PC or a Mac you listen from at home | **The Erhu Server app** (below): no terminal, no Docker |
| A NAS, home server or Linux box that is always on | **Docker** or a Navidrome package ([further down](#on-a-nas-or-home-server-docker)) |
| A Navidrome or other Subsonic-compatible server already | Nothing: just [add it in Erhu](#connect-erhu) |

## The Erhu Server app (Windows and macOS)

A small app that runs the music server for you. It lives in the tray (Windows) or menu bar (Mac).

1. **Download** the test build: open the latest successful
   [Erhu Server build](https://github.com/MeezaUni/Erhu-iOS/actions/workflows/erhu-server.yml?query=branch%3Atest-server-option)
   (you need to be signed in to GitHub), scroll to *Artifacts* and download
   `ErhuServer-Windows`, `ErhuServer-macOS-Intel` or `ErhuServer-macOS-AppleSilicon`. Unzip it.
   On a Mac, unzip the zip inside it as well.
2. **Open it.**
   - **Windows:** double-click `ErhuServer.exe`. If "Windows protected your PC" appears, click
     *More info* → *Run anyway*.
   - **Mac (macOS 12 or later):** right-click *Erhu Server* → *Open*. If macOS still refuses,
     open System Settings → Privacy & Security and click *Open Anyway*. If it then says the app
     is damaged, run this once in Terminal and open it again:
     `xattr -dr com.apple.quarantine "/path/to/Erhu Server.app"`

   These warnings appear because test builds aren't code-signed yet.
3. A page opens in your browser. **Choose your music folder**, then **create a username and
   password**. If Windows asks whether to allow `navidrome` on the network, choose *Allow* for
   private networks.
4. On the iPhone, on the same Wi-Fi, **point the Camera at the QR code** on the page and tap
   *Open in Erhu*. Type your password and tap *Connect*.

Keep the computer on and awake while you listen. Click the tray or menu bar icon to open the page
again or to quit. *Start Erhu Server when I sign in* on the page makes it start with the computer.
Keep the files in the folder together: the app needs the `navidrome` file beside it.

The MP3 streaming qualities need `ffmpeg` on the computer; without it, use *Original file* in
Erhu (the default).

## On a NAS or home server (Docker)

1. Install Docker (on a NAS: its Docker / Container Manager app).
2. Put this folder's `docker-compose.yml` and `.env.example` on the server.
3. Copy `.env.example` to `.env` and set `MUSIC_FOLDER` to your music folder.
4. Run `docker compose up -d` in that folder, or create a "project" / "stack" from
   `docker-compose.yml` in the NAS's container app.

Without Docker, install Navidrome with its official package for your system from the
[Navidrome installation guide](https://www.navidrome.org/docs/installation/), apply the settings
in this folder's [`navidrome.toml`](navidrome.toml) and restart it.

## Create your account (Docker and package installs)

The Erhu Server app does this for you. Otherwise, open `http://<computer address>:4533` in a browser (on the computer itself:
`http://localhost:4533`). The first account you create is the administrator. Make a strong
password.

To find the computer's address on your network:

- **Windows:** Settings → Network & internet → your connection → *IPv4 address*.
- **macOS:** System Settings → Wi-Fi → Details → *IP address*.
- **Linux:** `hostname -I`.
- **NAS:** shown in its control panel.

The address looks like `192.168.1.20`. Giving the computer a fixed (reserved) address in your
router keeps it from changing.

## Connect Erhu

With the Erhu Server app, scan its QR code as described above. Otherwise, in Erhu:
**Settings → Music Server → Add server** (or the side menu → *Music Server*). Enter
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

## Licence and credits

All of the music serving is done by [Navidrome](https://www.navidrome.org), © the Navidrome
authors and contributors, licensed under the
[GNU GPL v3.0](https://github.com/navidrome/navidrome/blob/master/LICENSE). Erhu Server uses the
official, unmodified Navidrome release (the version and checksums are pinned in
[`launcher/navidrome.lock`](launcher/navidrome.lock)). Thank you to everyone who builds it.

The Erhu Server app in [`launcher/`](launcher) is a separate program that starts Navidrome and
sets it up. Because it is distributed together with Navidrome, it is also released under the
GPL v3.0 ([`launcher/LICENSE`](launcher/LICENSE)), with its source in this repository. The Erhu
iPhone app only talks to the server over the network through the public Subsonic API and contains
no Navidrome code. See [ThirdParty/NAVIDROME-NOTICE.md](../ThirdParty/NAVIDROME-NOTICE.md).
