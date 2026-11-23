#!/bin/sh
# Sets the server up in the volumes on the first start (config, folders, certificate, database),
# then runs it. Later starts keep everything.
set -eu
if [ ! -f /config/config.toml ]; then
  if [ -n "${HALDEN_NAME:-}" ]; then
    halden setup --data-dir /data --library-dir /library --name "$HALDEN_NAME"
  else
    halden setup --data-dir /data --library-dir /library
  fi
  echo "Create the first account with: docker exec -it halden halden user add <name> --owner"
fi
exec halden serve
