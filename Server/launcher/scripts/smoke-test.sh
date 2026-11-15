#!/usr/bin/env bash
# End-to-end check against the REAL Navidrome: starts Erhu Server without a tray, sets the music
# folder and creates the account through its page's API, then talks to the server the way the
# Erhu app does (Subsonic token sign-in, album list, cover, original download).
#   scripts/smoke-test.sh PATH_TO_ERHU_SERVER MUSIC_FOLDER
set -euo pipefail
launcher=${1:?path to the Erhu Server program}
music=${2:?music folder with at least one tagged audio file}
home=$(mktemp -d)
export ERHU_SERVER_HOME="$home"
"$launcher" --no-tray --background > "$home/launcher.log" 2>&1 &
pid=$!
cleanup() { kill "$pid" 2>/dev/null || true; sleep 1; echo "--- navidrome log (tail)"; tail -n 15 "$home/navidrome.log" 2>/dev/null || true; }
trap cleanup EXIT

page=http://127.0.0.1:4534
for _ in $(seq 1 50); do curl -fs "$page/logo.png" -o /dev/null && break; sleep 0.2; done
token=$(curl -fs "$page/" | sed -n 's/.*const TOKEN = "\([0-9a-f]*\)".*/\1/p')
[ -n "$token" ] || { echo "no page token"; exit 1; }
api() { curl -fsS -H "X-Erhu-Token: $token" -H "Content-Type: application/json" "$@"; }
state() { api "$page/api/state" | sed -n 's/.*"state":"\([a-z]*\)".*/\1/p'; }

test "$(curl -s -o /dev/null -w '%{http_code}' "$page/api/state")" = 403   # no token, no access
[ "$(state)" = setup ]
api -d "{\"path\":\"$music\"}" "$page/api/folder" > /dev/null
for _ in $(seq 1 150); do [ "$(state)" = running ] && break; sleep 0.4; done
[ "$(state)" = running ] || { echo "server did not start: $(api "$page/api/state")"; exit 1; }
api -d '{"username":"tester","password":"smoke test pw"}' "$page/api/account" | grep -q '"accountCreated":true'
api "$page/api/state" | grep -q '"invite":"erhu://server?'
curl -fs "$page/qr.png?t=$token" -o "$home/qr.png" && [ -s "$home/qr.png" ]

# Now as the Erhu app: Subsonic token authentication (md5(password + salt)), never the password.
md5() { if command -v md5sum >/dev/null; then printf '%s' "$1" | md5sum | cut -c1-32; else printf '%s' "$1" | md5 -q; fi; }
salt=c19b2dab12cd
auth="u=tester&t=$(md5 "smoke test pw$salt")&s=$salt&v=1.16.1&c=Erhu"
rest=http://127.0.0.1:4533/rest
curl -fsS "$rest/ping?$auth&f=json" | grep -q '"status":"ok"'
curl -fsS "$rest/ping?u=tester&t=wrong&s=$salt&v=1.16.1&c=Erhu&f=json" | grep -q '"code":40'
albums=""
for _ in $(seq 1 60); do   # the first library scan takes a moment
  albums=$(curl -fsS "$rest/getAlbumList2?$auth&f=json&type=alphabeticalByName&size=10")
  echo "$albums" | grep -q '"album":\[{' && break
  sleep 1
done
echo "$albums" | grep -q '"album":\[{' || { echo "no albums after the scan: $albums"; exit 1; }
album=$(echo "$albums" | sed -n 's/.*"album":\[{"id":"\([^"]*\)".*/\1/p')
detail=$(curl -fsS "$rest/getAlbum?$auth&f=json&id=$album")
song=$(echo "$detail" | sed -n 's/.*"song":\[{"id":"\([^"]*\)".*/\1/p')
[ -n "$song" ] || { echo "no song in album: $detail"; exit 1; }
curl -fsS "$rest/download?$auth&id=$song" -o "$home/song.bin"
[ "$(wc -c < "$home/song.bin")" -gt 1000 ]
curl -fsS "$rest/stream?$auth&id=$song&format=raw" -o "$home/stream.bin"
cmp -s "$home/song.bin" "$home/stream.bin"   # format=raw streams the original file
curl -fsS "$rest/star?$auth&f=json&id=$song" | grep -q '"status":"ok"'
curl -fsS "$rest/getStarred2?$auth&f=json" | grep -q "\"id\":\"$song\""
curl -fsS "$rest/scrobble?$auth&f=json&id=$song&submission=true" | grep -q '"status":"ok"'

# Quitting through the page stops Navidrome too.
api -d '{}' "$page/api/quit" > /dev/null
for _ in $(seq 1 40); do curl -s -o /dev/null "http://127.0.0.1:4533/ping" || break; sleep 0.3; done
if curl -s -o /dev/null "http://127.0.0.1:4533/ping"; then echo "Navidrome still running after quit"; exit 1; fi
trap - EXIT
echo "Erhu Server smoke test passed (real Navidrome)."
