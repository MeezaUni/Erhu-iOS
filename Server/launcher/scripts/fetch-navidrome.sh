#!/usr/bin/env bash
# Downloads the official Navidrome release named in navidrome.lock for one platform, checks its
# SHA-256 against the lock file, and unpacks the program into OUT_DIR.
#   scripts/fetch-navidrome.sh windows_amd64.zip|darwin_amd64.tar.gz|darwin_arm64.tar.gz|linux_amd64.tar.gz OUT_DIR
set -euo pipefail
kind=${1:?platform, e.g. windows_amd64.zip}
out=${2:?output folder}
here=$(cd "$(dirname "$0")/.." && pwd)
version=$(grep '^version=' "$here/navidrome.lock" | cut -d= -f2)
want=$(grep "^$kind=" "$here/navidrome.lock" | cut -d= -f2)
[ -n "$version" ] && [ -n "$want" ] || { echo "no entry for $kind in navidrome.lock" >&2; exit 1; }
file="navidrome_${version}_${kind}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL --retry 3 -o "$tmp/$file" "https://github.com/navidrome/navidrome/releases/download/v${version}/${file}"
if command -v sha256sum >/dev/null; then got=$(sha256sum "$tmp/$file" | cut -d' ' -f1); else got=$(shasum -a 256 "$tmp/$file" | cut -d' ' -f1); fi
if [ "$got" != "$want" ]; then
  echo "checksum mismatch for $file: got $got, expected $want" >&2
  exit 1
fi
mkdir -p "$out"
case $kind in
  *.zip) unzip -q -o "$tmp/$file" -d "$tmp/unpacked" ;;
  *) mkdir -p "$tmp/unpacked" && tar -xzf "$tmp/$file" -C "$tmp/unpacked" ;;
esac
bin=$(find "$tmp/unpacked" -type f \( -name navidrome -o -name navidrome.exe \) | head -n 1)
[ -n "$bin" ] || { echo "no navidrome program inside $file" >&2; exit 1; }
cp "$bin" "$out/"
chmod +x "$out/$(basename "$bin")"
echo "Navidrome $version ($kind) verified and unpacked into $out"
