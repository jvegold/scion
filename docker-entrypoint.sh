#!/usr/bin/env bash
# Entrypoint for the containerized Scion combo server.
#
# Applies optional runtime config from environment variables before launching
# the server, then execs the Dockerfile CMD (the `scion server start ...` line).
set -euo pipefail

# image_registry has no native env override in scion, so apply it here when
# SCION_IMAGE_REGISTRY is set. This points the runtime-broker at the registry
# holding the agent images (e.g. ghcr.io/jvegold), so it pulls
# ghcr.io/jvegold/scion-claude instead of a local bare tag. The write lands in
# $HOME/.scion (HOME=/var/lib/scion) as uid 1000, so it persists on the bind
# mount and is picked up on every start (idempotent).
if [ -n "${SCION_IMAGE_REGISTRY:-}" ]; then
  echo "entrypoint: setting image_registry=${SCION_IMAGE_REGISTRY}"
  scion config set --global image_registry "${SCION_IMAGE_REGISTRY}"
fi

exec "$@"
