# ✅ enVector Self-Hosted Setup Guide

## 🔢 Docker Image Versions

The default tags come from `.env.example`:

```text
es2e:     cryptolabinc/es2e:${VERSION_TAG}
es2b:     cryptolabinc/es2b:${VERSION_TAG}
es2o:     cryptolabinc/es2o:${VERSION_TAG}
es2c:     cryptolabinc/es2c:${VERSION_TAG}
postgres: postgres:14.9
minio:    minio/minio:RELEASE.2023-03-20T20-16-18Z
```

## 🧩 Compose File Layout

```text
docker-compose.envector.yml    # Core application services
docker-compose.gpu.yml         # GPU override for es2c
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
cd envector-deployment/docker-compose
# If .env is missing, ./start_envector.sh will auto-create it from .env.example
cp .env.example .env  # optional
```

Edit `.env` as needed. `COMPOSE_PROJECT_NAME` customises the network/container prefix.

---

## 🔐 License Token

- Docker-mounted path: the container reads the token at `/es2/license/token.jwt` (source file on host: `docker-compose/token.jwt`).
- If `token.jwt` is missing, `./start_envector.sh` will prompt for a path and copy the file to `docker-compose/token.jwt` automatically.
- The `es2c` service reads the token from the Docker-mounted path `/es2/license/token.jwt`; the compose file mounts it for you:

```yaml
environment:
  ES2_LICENSE_TOKEN: "${ES2_LICENSE_TOKEN:-/es2/license/token.jwt}"
# License file mount. Place your license token.jwt file in the same directory as this docker-compose file.
volumes:
  - ./token.jwt:/es2/license/token.jwt
```

- You normally don’t need to set `ES2_LICENSE_TOKEN` in `.env`; it matches the Docker-mounted path above.
- If you change the token filename or path, update both `ES2_LICENSE_TOKEN` and the `volumes` mapping in `docker-compose/docker-compose.envector.yml` accordingly.

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
./start_envector.sh --num-es2c 4          # CPU-only: scale es2c=4
./start_envector.sh --gpu --num-es2c 2    # GPU: gpu0 + gpu1

# Project/env/log options
./start_envector.sh -p my-es2 --env-file ./.env --log-file ./docker-logs.log

# Inline env overrides (higher precedence than .env)
./start_envector.sh ES2E_HOST_PORT=50055 VERSION_TAG=dev

# Stop the stack (use -p if you set a project)
./start_envector.sh --down    # also tears down GPU services automatically
# e.g., ./start_envector.sh -p my-es2 --down
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

To inspect the final configuration before starting:

```bash
docker compose -f docker-compose.envector.yml -f docker-compose.infra.yml --env-file .env config
```

Notes on scaling
- CPU-only: `--scale es2c=N` (manual) or `./start_envector.sh --num-es2c N` (script).
- GPU: `./start_envector.sh --gpu --num-es2c N` enables N GPU workers (base gpu0 plus additional).
  Extend beyond 4 GPUs by editing `docker-compose.gpu.yml`.

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
pip install es2
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
