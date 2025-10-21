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

## ✅ Step 1. Login to Docker Hub

```bash
# Copy your PAT to a file (@inkme)
cp ~/.dockerhub_pat patfile  # or ~/.dockerhub_pat_es2_read patfile

# Login using Docker PAT
cat patfile | docker login -u cltrial --password-stdin
```

---

## ✅ Step 2. Prepare Environment

```bash
cd envector-deployment/docker-compose
cp .env.example .env
```

Edit `.env` as needed. `COMPOSE_PROJECT_NAME` customises the network/container prefix.

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
./start_envector.sh --down
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

Using the helper script from the repo root, logs are tailed automatically after `up -d`:

```bash
scripts/start_envector.sh            # logs -> external/es2-deploy/docker-compose/docker-logs.log
scripts/start_envector.sh --log-file ./docker-logs/my-run.log
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
