# enVector - Encrypted Vector Search

[![License](https://img.shields.io/badge/license-Proprietary-red.svg)](LICENSE)
[![PyPI](https://img.shields.io/pypi/v/pyenvector)](https://pypi.org/project/pyenvector/)
[![Docker](https://img.shields.io/badge/docker-private-blue.svg)](https://www.docker.com/)
[![Kubernetes](https://img.shields.io/badge/kubernetes-ready-blue.svg)](https://kubernetes.io/)
[![Python](https://img.shields.io/badge/python-3.9%20%7C%203.10%20%7C%203.11%20%7C%203.12%20%7C%203.13-blue.svg)](https://www.python.org/)
[![OS](https://img.shields.io/badge/os-linux%20%7C%20macOS%2011.0+-green.svg)](https://www.apple.com/macos/)

> **enVector** provides secure vector search using **ES2 (Encrypted Similarity Search)** based on Fully Homomorphic Encryption (FHE). This repository contains self-hosted deployment assets and Python SDK notebooks.

## Features

- End-to-end encrypted vector search
- Docker Compose and Kubernetes (Helm) deployment support
- Multi-service architecture for scaling and HA
- Python SDK notebooks for quick start and API flow

## Architecture

enVector consists of five main services:

- **envector-endpoint**: API gateway and client entrypoint
- **envector-backend**: metadata/service management
- **envector-orchestrator**: request coordination and scheduling
- **envector-compute**: encrypted vector compute workers
- **envector-shaper**: shard split/merge and storage shaping tasks

Infrastructure dependencies:

- PostgreSQL (metadata)
- Object storage (S3-compatible or GCS via Helm values)

## Project Structure

```text
envector-deployment/
├── docker-compose/
│   ├── docker-compose.envector.yml
│   ├── docker-compose.infra.yml
│   ├── docker-compose.gpu.yml
│   ├── start_envector.sh
│   └── README.md
├── kubernetes-manifests/
│   ├── helm/
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   └── templates/
│   └── README.md
└── notebooks/
    ├── 00-quick-start.ipynb
    ├── 01-api-flow.ipynb
    ├── 02-simple-rag.ipynb
    ├── 03-rag-with-langchain.ipynb
    ├── 04-ann-api-flow.ipynb
    └── 05-insert-load-capacity.ipynb
```

## Quick Start

**Important**: Docker images are in private repositories. Contact [heaan](mailto:hello@heaan.com) for access.

### Option 1: Docker Compose

See full guide: [docker-compose/README.md](docker-compose/README.md)

```bash
git clone https://github.com/CryptoLabInc/envector-deployment.git
cd envector-deployment/docker-compose

# optional (script auto-creates from .env.example if missing)
cp .env.example .env

# preflight + up (docker, image access, license token)
./start_envector.sh
```

Useful variants:

```bash
# print merged compose config only
./start_envector.sh --config

# GPU override
./start_envector.sh --gpu

# scale compute/orchestrator
./start_envector.sh --num-compute 4 --num-orchestrator 2

# stop stack
./start_envector.sh --down
```

### Option 2: Kubernetes (Helm)

See full guide: [kubernetes-manifests/README.md](kubernetes-manifests/README.md)

```bash
git clone https://github.com/CryptoLabInc/envector-deployment.git
cd envector-deployment/kubernetes-manifests

# install chart
helm install envector ./helm
```

For production, configure before install/upgrade:

- `externalServices.metadatadb` / `externalServices.storage`
- `compute.license` (token secret creation or `existingSecret`)
- `externalSecrets.*` if using External Secrets Operator

## Configuration

### Key Docker Compose Environment Variables

| Variable | Description | Default |
|---|---|---|
| `ENVECTOR_ENDPOINT_HOST_PORT` | Host port for gRPC endpoint | `50050` |
| `ENVECTOR_HTTP_HEALTH_HOST_PORT` | Host port for HTTP health/admin | `18080` |
| `ENVECTOR_ADMIN_API_ENABLED` | Enable admin API on endpoint | `true` |
| `ENVECTOR_LOG_LEVEL` | Service log level | `INFO` |
| `ENVECTOR_COMPUTE_TAG` | Compute image tag | `latest` |
| `ENVECTOR_LICENSE_TOKEN` | In-container license token path | `/envector/license/token.jwt` |
| `ENVECTOR_DB_*` | PostgreSQL connection parts | varies |
| `ENVECTOR_STORAGE_*` | Storage connection settings | varies |

### Key Helm Values

`kubernetes-manifests/helm/values.yaml` 주요 항목:

- `endpoint.*`, `backend.*`, `orchestrator.*`, `compute.*`, `shaper.*`
- `externalServices.metadatadb.*`, `externalServices.storage.*`
- `compute.license.*` (createSecret/existingSecret/mountAsFile/injectAsEnv)
- `externalSecrets.*` (ESO 기반 시크릿 주입)
- `ingress.*` (TLS/HTTPS)

## Python SDK / Notebooks

```bash
pip install pyenvector
```

Basic init example:

```python
import pyenvector as ev

ev.init(
    address="localhost:50050",
    key_path="./keys",
    key_id="my_key",
)
```

Notebook examples are in `notebooks/`.

## License

This project is proprietary software. For licensing information, contact [heaan](mailto:hello@heaan.com).

## Support

- Product Information: [heaan](https://heaan.com)
- Technical Support: [es2.support@heaan.com](mailto:es2.support@heaan.com)
