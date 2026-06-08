# Scion combo server in Docker (single-server, all-in-containers)

Run the Scion **hub + web + runtime-broker** as one container on a single
Ubuntu host. The broker launches agents as **sibling containers** on the host
Docker daemon (docker-out-of-docker) — a single-node analog of the Kubernetes
topology: everything runs in containers, with agent workspaces on a shared
host directory instead of an NFS/RWX volume.

Files:
- `Dockerfile.scion-server` — wraps the host-built `scion` binary (`make all`,
  web embedded) on `ubuntu:24.04`, plus the docker CLI and git ≥ 2.47.
- `docker-entrypoint.sh` — applies `SCION_IMAGE_REGISTRY` on start.
- `docker-compose.yml` — socket passthrough, identical-path state mount, docker group.
- `.env.example` — `DOCKER_GID` and `SCION_IMAGE_REGISTRY`.

## How it works

| Kubernetes idea | Here (single Docker host) |
|---|---|
| Broker runs in a container | `scion-server` container (hub + web + broker) |
| Agents are isolated Pods | agents are sibling docker containers via `/var/run/docker.sock` |
| Workspaces on RWX/NFS volume | shared host dir `/var/lib/scion` (identical-path bind mount) |
| Orchestrator drives the K8s API | broker drives the host Docker API |

**Path-identity (design §6):** the broker creates git worktrees and agent home
dirs, then passes those paths to `docker run -v`, where the *host* daemon
resolves them. So the state dir must be bind-mounted at the **same path** on
host and in the container (`/var/lib/scion:/var/lib/scion`) — a named volume
will not work.

## One-time setup

```bash
# State dir, owned by the container's scion user (uid 1000)
sudo mkdir -p /var/lib/scion && sudo chown -R 1000:1000 /var/lib/scion

# Config: docker group GID + agent image registry
cp .env.example .env
sed -i "s/^DOCKER_GID=.*/DOCKER_GID=$(getent group docker | cut -d: -f3)/" .env
# edit SCION_IMAGE_REGISTRY in .env if not ghcr.io/jvegold
```

## Build & run

```bash
# 1. Build & push the agent images to your registry
image-build/scripts/build-images.sh --registry ghcr.io/jvegold --push --target all
# If the ghcr packages are private, log the HOST daemon in so it can pull:
docker login ghcr.io

# 2. Build the server image (rebuilds web + binary first) and start it
make docker-build
make docker-up
make docker-logs        # dev-auth token is printed here
```

Web UI: <http://localhost:8080>

Stop (state persists in `/var/lib/scion`):

```bash
make docker-down
```

## Notes

- **Agent images must be reachable by the host daemon.** The broker pulls
  `${SCION_IMAGE_REGISTRY}/scion-claude` etc.; the entrypoint sets the
  `image_registry` setting from `SCION_IMAGE_REGISTRY` on every start.
- **git ≥ 2.47** is installed from the git-core PPA (Ubuntu 24.04 ships 2.43);
  without it the broker falls back to clone-per-agent with a warning.
- **Security:** the server has full access to the host Docker socket
  (root-equivalent on the host). Fine for a local dev box; do not expose it.
- This is the single-node, all-Docker middle ground. The two formally
  validated topologies are *broker-on-host + Docker* and *K8s + NFS*.
