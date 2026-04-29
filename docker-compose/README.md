# ✅ enVector Self-Hosted Setup Guide

## 🔢 Docker Image Versions

The default tags come from `.env.example`:

```text
envector-endpoint:      cryptolabinc/envector-endpoint:${VERSION_TAG}
envector-backend:       cryptolabinc/envector-backend:${VERSION_TAG}
envector-orchestrator:  cryptolabinc/envector-orchestrator:${VERSION_TAG}
envector-compute:       cryptolabinc/envector-compute:${VERSION_TAG}
postgres:               postgres:14.9
minio:                  minio/minio:RELEASE.2023-03-20T20-16-18Z
```

## 🧩 Compose File Layout

```text
docker-compose.envector.yml    # Core application services
docker-compose.gpu.yml         # GPU override for compute
docker-compose.infra.yml       # Postgres + MinIO (adds readiness deps to core)
```

Include only the files you need. Settings such as `COMPOSE_PROJECT_NAME` and image tags are read from `.env` (or `.env.example` if you pass `--env-file`).

---

## ✅ Step 1. Docker Hub Login (auto)

`./start_envector.sh` performs preflight checks. If access to `cryptolabinc/*` images is required, it will prompt for a Docker Hub PAT and run:

```bash
cat patfile | docker login -u cltrial --password-stdin
```

Optional: you can login manually ahead of time if you prefer.

---

## ✅ Step 2. Prepare Environment

```bash
cd deployment/docker-compose
# If .env is missing, ./start_envector.sh will auto-create it from .env.example
cp .env.example .env  # optional
```

Edit `.env` as needed. `COMPOSE_PROJECT_NAME` customises the network/container prefix.

---

## 🔐 License Token

- Docker-mounted path: the container reads the token at `/envector/license/token.jwt` (source file on host: `docker-compose/token.jwt`).
- If `token.jwt` is missing, `./start_envector.sh` will prompt for a path and copy the file to `docker-compose/token.jwt` automatically.
- The `envector-compute` service reads the token from the Docker-mounted path `/envector/license/token.jwt`; the compose file mounts it for you:

```yaml
environment:
  ENVECTOR_LICENSE_TOKEN: "${ENVECTOR_LICENSE_TOKEN:-/envector/license/token.jwt}"
# License file mount. Place your license token.jwt file in the same directory as this docker-compose file.
volumes:
  - ./token.jwt:/envector/license/token.jwt
```

- You normally don’t need to set `ENVECTOR_LICENSE_TOKEN` in `.env`; it matches the Docker-mounted path above.
- If you change the token filename or path, update both `ENVECTOR_LICENSE_TOKEN` and the `volumes` mapping in `docker-compose/docker-compose.envector.yml` accordingly.

---

## ✅ Step 3. Launch the Stack

Recommended (helper script in this directory):

```bash
# Baseline: application + infrastructure
./start_envector.sh

# Print merged compose config (no containers started)
./start_envector.sh --config

# GPU override (requires NVIDIA Container Toolkit)
./start_envector.sh --gpu

# Scale workers
./start_envector.sh --num-compute 4          # CPU-only: scale compute=4
./start_envector.sh --gpu --num-compute 2    # GPU: gpu0 + gpu1

# Project/env/log options
./start_envector.sh -p my-envector --env-file ./.env --log-file ./docker-logs.log

# Inline env overrides (higher precedence than .env)
./start_envector.sh ENVECTOR_ENDPOINT_HOST_PORT=50055 VERSION_TAG=dev
./start_envector.sh ENVECTOR_HTTP_HEALTH_HOST_PORT=18081
./start_envector.sh ENVECTOR_ADMIN_API_ENABLED=true

# Stop the stack (use -p if you set a project)
./start_envector.sh --down    # also tears down GPU services automatically
# e.g., ./start_envector.sh -p my-envector --down
# Remove volumes as well when stopping
./start_envector.sh --down --down-volumes
```

Advanced (manual docker compose -f):

```bash
# Baseline: application + infrastructure
docker compose \
  -f docker-compose.envector.yml \
  -f docker-compose.infra.yml \
  --env-file .env \
  up -d

# Add GPU override (requires NVIDIA Container Toolkit)
docker compose \
  -f docker-compose.envector.yml \
  -f docker-compose.gpu.yml \
  -f docker-compose.infra.yml \
  --env-file .env \
  up -d

# Combine layers: GPU + infra
docker compose \
  -f docker-compose.envector.yml \
  -f docker-compose.gpu.yml \
  -f docker-compose.infra.yml \
  --env-file .env \
  up -d
```

HTTP health endpoints:

```bash
curl http://localhost:${ENVECTOR_HTTP_HEALTH_HOST_PORT:-18080}/health
curl http://localhost:${ENVECTOR_HTTP_HEALTH_HOST_PORT:-18080}/health/ready
```

Admin API:

```bash
curl http://localhost:${ENVECTOR_HTTP_HEALTH_HOST_PORT:-18080}/admin/services
curl http://localhost:${ENVECTOR_HTTP_HEALTH_HOST_PORT:-18080}/admin/indexes
curl http://localhost:${ENVECTOR_HTTP_HEALTH_HOST_PORT:-18080}/admin/keys
curl "http://localhost:${ENVECTOR_HTTP_HEALTH_HOST_PORT:-18080}/admin/indexes/sample-index/operations/request-123?operation_type=INSERT"
curl http://localhost:${ENVECTOR_HTTP_HEALTH_HOST_PORT:-18080}/admin/keys/key-1
```

Enable it with:

```bash
ENVECTOR_ADMIN_API_ENABLED=true
```

Swagger:

```bash
open http://localhost:${ENVECTOR_HTTP_HEALTH_HOST_PORT:-18080}/swagger/
```

To inspect the final configuration before starting:

```bash
docker compose -f docker-compose.envector.yml -f docker-compose.infra.yml --env-file .env config
```

---

## ✅ Step 4. Collect Logs

```bash
docker compose logs -f
```

Using the helper script in this directory, logs are tailed automatically after `up -d`.
Change the log destination with `--log-file`:

```bash
./start_envector.sh --log-file ./docker-logs/my-run.log
```

Redirect logs if you prefer:

```bash
mkdir -p docker-logs
docker compose ... up > ./docker-logs/docker-compose.log 2>&1 &
```

---

## ✅ Step 5. Install Python SDK

```bash
python3.12 -m venv .venv
source .venv/bin/activate
pip install pyenvector
```

---

## ✅ Step 6. Stop and Clean Up

```bash
docker compose down
# Remove optional volumes if required
# docker compose down -v

# Using the helper script
# Keep volumes (default)
./start_envector.sh --down
# Remove volumes
./start_envector.sh --down --down-volumes
```

Remove any extra compose files from the command when taking down layers you did not start. For example, if you launched GPU override:

```bash
docker compose \
  -f docker-compose.envector.yml \
  -f docker-compose.infra.yml \
  -f docker-compose.gpu.yml \
  --env-file .env \
  down
```
