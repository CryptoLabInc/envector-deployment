# ✅ enVector Self-Hosted Setup Guide

## 🔢 Docker Image Versions

```text
es2e:     cryptolabinc/es2e:latest 
es2b:     cryptolabinc/es2b:latest  
es2s:     cryptolabinc/es2s:latest  
es2c:     cryptolabinc/es2c:latest  
postgres: postgres:14  
minio:    minio/minio:RELEASE.2023-03-20T20-16-18Z  
```

## ⚙️ Pull Policy

```text
pull_policy: always
```

---

## ✅ Step 1. Login to Docker Hub

```bash
# Copy your PAT to a file (@inkme)
cp ~/.dockerhub_pat patfile  # or ~/.dockerhub_pat_es2_read patfile

# Login using Docker PAT
cat patfile | docker login -u cltrial --password-stdin
```

---

## ✅ Step 2. Clone & Update `envector-deployment` Repository

```bash
cd envector-deployment
git checkout main
git pull
```

---

## ✅ Step 3. Copy `.env.example` File to `.env`

```bash
cd docker-compose
cp .env.example .env
```

## ✅ Step 4. Run Docker Compose

```bash
mkdir -p docker-logs

# Optional: verify config
docker compose -f docker-compose.yml -p es2 config

# Run docker-compose in background with log
docker compose -f docker-compose.yml -p es2 up > ./docker-logs/docker-compose.log 2>&1 &
```

## ✅ Step 5. Install Python SDK
```bash
virtulanev -p python3.12 .venv
source .venv/bin/activate

# Install es2 from pypi
pip install es2
```
## ✅ Step 6. Stop Docker Compose

```bash
docker compose down
```

