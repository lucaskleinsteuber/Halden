# Halden in Docker

The image `ghcr.io/lucaskleinsteuber/halden` holds the server with ffmpeg and libheif. It runs as
user 10001, never as root, and works with a read-only file system.

## Start

Give the folders to the container's user first, then start it with
[`packaging/docker/compose.yaml`](../packaging/docker/compose.yaml):

```sh
sudo mkdir -p /srv/halden/config /var/lib/halden /mnt/photos/halden
sudo chown -R 10001:10001 /srv/halden/config /var/lib/halden /mnt/photos/halden
docker compose up -d
docker exec -it halden halden user add <name> --owner
docker exec -it halden halden pair
```

On the first start the container sets itself up in the volumes: the config in `/config`, the
database, keys and thumbnails in `/data` (best on the fast system disk), and the photos and
videos in `/library` (usually the big disk).

| Volume | What is in it |
|---|---|
| `/config` | `config.toml` |
| `/data` | database, certificate, thumbnails |
| `/library` | your photos and videos in readable folders, and the database backups |
| `/mirror` (optional) | a second copy on another disk: mount it, then `docker exec halden halden mirror set /mirror` |

## Network

Use host networking (`network_mode: host`, as in the compose file). Then Bonjour works, so the
app finds the server by itself, and the server sees your devices' real addresses: it only lets in
the home network and Tailscale. With a port mapping (`-p 47130:47130`) instead, Bonjour doesn't
reach the home network; pair with the QR code from `halden pair`.

## Commands

Every `halden` command works inside the container: `docker exec -it halden halden status`,
`halden doctor`, `halden config set …` (the server picks up changes by itself), `halden backup now`.

## Updates

The app and `halden status` say when there is a new version. In Docker, update by pulling the new
image; the volumes keep everything:

```sh
docker compose pull && docker compose up -d
```

Images are built only from signed releases: the build checks the release's signature with the
same key as the installer.

## Build it yourself

From the repository's root:

```sh
docker build -f packaging/docker/Dockerfile -t halden .
```
