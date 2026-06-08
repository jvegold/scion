#!/usr/bin/env bash
# Entrypoint for the containerized Scion combo server.
#
# Performs machine-level initialization before launching the server, then
# execs the Dockerfile CMD (the `scion server start ...` line).
set -euo pipefail

# `scion init --machine` seeds the global ~/.scion (HOME=/var/lib/scion):
# settings (with detected container runtime), templates, harness-configs and a
# stable broker id. This is REQUIRED before the hub/broker can run. It is
# idempotent (existing files are skipped) so it is safe on every restart.
#
# --image-registry sets the registry the broker pulls agent images from
# (e.g. ghcr.io/jvegold), recorded as the `image_registry` setting.
# --non-interactive avoids any prompt (there is no TTY in the container).
init_args=(init --machine --non-interactive)
if [ -n "${SCION_IMAGE_REGISTRY:-}" ]; then
  init_args+=(--image-registry "${SCION_IMAGE_REGISTRY}")
fi
echo "entrypoint: scion ${init_args[*]}"
scion "${init_args[@]}"

exec "$@"
