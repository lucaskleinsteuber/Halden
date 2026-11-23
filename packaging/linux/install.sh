#!/bin/bash
# Installs the Halden server from this package, or updates an installed one. Run it as root:
#
#   sudo ./install.sh
#
# It creates the system user `halden`, puts the program in /usr/local/bin, installs the systemd
# units, installs ffmpeg and libheif when apt is there, runs `halden setup` (which asks where the
# photos go and for the first account on a new installation), opens the firewall if ufw is on,
# and starts the server. Run again, it updates the program and keeps everything else.
#
# Everything runs inside main, called on the last line.
main() {
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
fail() { echo "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "Run it as root: sudo ./install.sh"
command -v systemctl >/dev/null 2>&1 || fail "This needs Linux with systemd (or Docker, see docs/DOCKER.md)."
[ -x "$here/halden" ] || fail "The halden program is missing next to install.sh."
export DEBIAN_FRONTEND=noninteractive

# Questions come from the terminal even when this runs from `curl … | sudo bash`.
tty=/dev/null
if [ -t 1 ] && { : </dev/tty; } 2>/dev/null; then
  tty=/dev/tty
fi

if ! id halden >/dev/null 2>&1; then
  echo "Creating the system user halden..."
  useradd --system --home-dir /var/lib/halden --no-create-home --shell /usr/sbin/nologin halden
fi

echo "Installing the program..."
install -m 755 "$here/halden" /usr/local/bin/.halden.new
mv -f /usr/local/bin/.halden.new /usr/local/bin/halden

for unit in "$here"/systemd/halden*; do
  install -m 644 "$unit" /etc/systemd/system/
done
systemctl daemon-reload

if command -v apt-get >/dev/null 2>&1; then
  tools=()
  for package in ffmpeg libheif-examples libheif-plugin-libde265 libheif-plugin-x265; do
    dpkg -s "$package" >/dev/null 2>&1 || tools+=("$package")
  done
  if [ "${#tools[@]}" -gt 0 ]; then
    echo "Installing ${tools[*]} (thumbnails of videos and HEIC photos, conversions)..."
    apt-get install -y --no-install-recommends "${tools[@]}" >/dev/null 2>&1 \
      || { apt-get update -qq >/dev/null 2>&1 && apt-get install -y --no-install-recommends "${tools[@]}" >/dev/null 2>&1; } \
      || echo "Could not install them. Halden works without; \`halden doctor\` says what is missing."
  fi
fi

if [ -f /etc/halden/config.toml ]; then
  # Adds what is missing and keeps everything else.
  halden setup </dev/null >/dev/null
else
  library=${HALDEN_LIBRARY:-}
  if [ -z "$library" ] && [ "$tty" = /dev/tty ]; then
    echo
    read -r -p "Folder for your photos and videos, best on the big disk [/srv/halden/library]: " library </dev/tty || true
  fi
  library=${library:-/srv/halden/library}
  halden setup --library-dir "$library" <"$tty"
  case $library in
    /srv/halden|/srv/halden/*|/mnt/*|/media/*) ;;
    *)
      # The server may only write to its own folders; allow this one.
      mkdir -p /etc/systemd/system/halden.service.d
      printf '[Service]\nReadWritePaths=%s\n' "$library" > /etc/systemd/system/halden.service.d/library.conf
      systemctl daemon-reload
      ;;
  esac
fi

port=$(halden config get server.port 2>/dev/null || echo 47130)
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  echo "Opening port $port and Bonjour in the firewall..."
  ufw allow "$port/tcp" >/dev/null
  ufw allow 5353/udp >/dev/null
fi

systemctl enable --now halden-update-request.path >/dev/null 2>&1
systemctl enable halden >/dev/null 2>&1
systemctl restart halden

for _ in $(seq 1 30); do
  halden status 2>/dev/null | grep -q "running on port" && break
  sleep 1
done
echo
halden status || true
echo
echo "Add a device: sudo halden pair"
echo "Check everything: sudo halden doctor"
}

main "$@"
