# enVector - Encrypted Vector Search

[![License](https://img.shields.io/badge/license-Proprietary-red.svg)](LICENSE)
[![PyPI](https://img.shields.io/pypi/v/pyenvector)](https://pypi.org/project/pyenvector/)
[![Docker](https://img.shields.io/badge/docker-private-blue.svg)](https://www.docker.com/)
[![Kubernetes](https://img.shields.io/badge/kubernetes-ready-blue.svg)](https://kubernetes.io/)
[![Python](https://img.shields.io/badge/python-3.9%20%7C%203.10%20%7C%203.11%20%7C%203.12%20%7C%203.13-blue.svg)](https://www.python.org/)
[![OS](https://img.shields.io/badge/os-linux%20%7C%20macOS%2011.0+-green.svg)](https://www.apple.com/macos/)

> **enVector** is a product that provides secure vector search functionality using **ES2 (Encrypted Similarity Search)**, which is based on Fully Homomorphic Encryption (FHE). This repository contains self-hosted deployment scripts and client SDK examples.

## 🚀 Features

- **🔐 End-to-End Encryption**: Secure vector search with FHE (Fully Homomorphic Encryption)
- **⚡ High Performance**: Optimized vector similarity search algorithms
- **🏗️ Microservices Architecture**: Scalable and maintainable service design
- **🐳 Multi-Platform Deployment**: Docker Compose and Kubernetes (Helm) support
- **🔑 Managed Key Management (KMS)**: Optional server-side key custody backed by HashiCorp Vault
- **👤 Authentication & Authorization**: Optional OIDC integration (Keycloak) with per-principal access control
- **📝 Audit Logging**: Optional tamper-evident audit pipeline (Redpanda) for API and key operations
- **📱 Python SDK**: Easy-to-use client library for integration


## 🔒 Security Features

- **Fully Homomorphic Encryption**: Secure computation on encrypted data
- **Client-side Key Management**: Secret key never leaves the client
- **Managed Key Management (optional)**: Server-side key custody via the enVector KMS, backed by HashiCorp Vault (TLS by default)
- **Encrypted Vector Storage**: All vector data is encrypted at rest (at-rest)
- **Secure Search**: Search operations performed on encrypted data (in-use)
- **OIDC Authentication (optional)**: Token-based auth and per-principal authorization via Keycloak
- **Audit Logging (optional)**: Tamper-evident audit trail for API and key-management operations
- **Transport Security (optional)**: Local CA (step-ca) issued certificates for service-to-service TLS

## 📊 Performance

- **Vector Dimensions**: Support for 32-4096 dimensional vectors
- **Search Speed**: Optimized encrypted similarity search algorithms
- **Scalability**: Horizontal scaling with Kubernetes
- **GPU Support**: Optional GPU acceleration for encrypted vector search

## 🛠️ Development

### Prerequisites

- Python 3.9-3.13
- Docker and Docker Compose
- Kubernetes cluster (for K8s deployment)
- Helm 3.0+
- Linux or macOS 11.0+

## 🏗️ Architecture

enVector consists of five main microservices:

- **Endpoint**: Main API gateway and client interface
- **Backend**: Service orchestration and metadata management
- **Orchestrator**: Manages and schedules compute requests
- **Compute**: Executes vector search and similarity computations
- **Shaper**: Splits and merges encrypted vector data for indexing and storage operations

### Optional Components

- **KMS**: Server-side key management service (TLS by default), backed by HashiCorp Vault
- **Keycloak**: OIDC identity provider for authentication and authorization
- **Audit**: Audit-log collector and exporter (Redpanda-based pipeline)
- **CA (step-ca)**: Local certificate authority for issuing service TLS certificates

### Infrastructure Dependencies

- **PostgreSQL**: Metadata storage and management
- **MinIO**: Vector data storage (S3-compatible)

## 📁 Project Structure

```
envector-deployment/
├── docker-compose/                  # Docker Compose deployment
│   ├── docker-compose.envector.yml  # Core application services
│   ├── docker-compose.infra.yml     # Postgres + MinIO (adds readiness deps to core)
│   ├── docker-compose.gpu.yml       # GPU override for compute
│   ├── docker-compose.kms.yml       # KMS overlay (TLS, implies CA)
│   ├── docker-compose.kms-notls.yml # KMS overlay without TLS (dev only)
│   ├── docker-compose.kms-audit.yml # KMS audit pipeline overlay
│   ├── docker-compose.keycloak.yml  # Keycloak (OIDC) overlay
│   ├── docker-compose.audit.yml     # Audit pipeline overlay
│   ├── docker-compose.ca.yml        # Local CA (step-ca) overlay
│   ├── docker-compose.network.yml   # External network overlay
│   ├── ca/                          # step-ca entrypoint/config
│   ├── kms/                         # KMS + Vault config and cert init
│   ├── keycloak/                    # Keycloak realm import
│   ├── audit/                       # Audit collector config
│   ├── .env.example                 # environment variables for envector
│   ├── start_envector.sh            # easy-to-use helper script
│   └── README.md                    # Docker setup guide
├── kubernetes-manifests/            # Kubernetes deployment
│   ├── helm/                        # Helm chart for K8s
│   │   ├── Chart.yaml               # Chart metadata
│   │   ├── values.yaml              # Configurable values
│   │   ├── templates/               # K8s manifest templates (incl. HA PodDisruptionBudgets)
│   │   └── tests/                   # Helm chart tests (HA)
│   └── README.md                    # K8s deployment guide
├── scripts/                         # Operational scripts
│   ├── auth/                        # Keycloak token + user seeding helpers
│   └── migrations/                  # DB migration SQL + upgrade runbooks
└── notebooks/                       # Python SDK examples
```

## 🚀 Quick Start

**⚠️ Important**: Docker images are stored in private repositories. Please contact [heaan](hello@heaan.com) for access credentials before proceeding with deployment.

### Option 1: Docker Compose

Recommended for Development. See more details in [docker-compose README](docker-compose/README.md).

#### Method A: Clone Repository
```bash
# Clone the repository
git clone https://github.com/CryptoLabInc/envector-deployment.git
cd envector-deployment/docker-compose

# Copy environment file (optional)
# If .env is missing, ./start_envector.sh will be created from .env.example automatically
cp .env.example .env

# Start services (performs preflight: Docker, PAT login if needed, license token)
./start_envector.sh
# OR docker compose -f docker-compose.envector.yml -f docker-compose.infra.yml -p envector up -d

# Enable optional overlays via flags (see ./start_envector.sh --help):
#   --gpu        GPU acceleration for compute
#   --kms        Managed key management with TLS (implies --ca)
#   --keycloak   OIDC authentication (Keycloak)
#   --audit      Audit logging pipeline (implies --keycloak)
#   --num-compute N / --num-orchestrator N   Scale workers
# Example:
# ./start_envector.sh --kms --audit
```

#### Method B: Direct HTTP Usage
```bash
# Download and run directly from GitHub
curl -O https://raw.githubusercontent.com/cryptolabinc/envector-deployment/main/docker-compose/docker-compose.envector.yml
curl -O https://raw.githubusercontent.com/cryptolabinc/envector-deployment/main/docker-compose/docker-compose.infra.yml
curl -O https://raw.githubusercontent.com/cryptolabinc/envector-deployment/main/docker-compose/.env.example

# Copy environment file
cp .env.example .env

# Start services
docker compose -f docker-compose.envector.yml -f docker-compose.infra.yml -p envector up -d
```


### Option 2: Kubernetes

Recommended for production.

#### Clone Repository
```bash
# Clone the repository
git clone https://github.com/CryptoLabInc/envector-deployment.git
cd envector-deployment

# Install Helm chart
helm install envector ./kubernetes-manifests/helm

# Check deployment status
kubectl get pods

# Access services
kubectl get svc
```

## 🔐 Security & Key Management (Optional Overlays)

enVector ships optional overlays that layer managed key custody, authentication, transport security, and audit logging on top of the core stack. They are opt-in and composed via `start_envector.sh` flags (Docker Compose) or Helm values (Kubernetes). For step-by-step setup, see the [docker-compose README](docker-compose/README.md).

- **KMS** (`--kms`): Server-side FHE key custody backed by HashiCorp Vault. Uses service TLS by default (implies the local CA overlay). A no-TLS variant (`--kms-notls`) is available for development only.
- **Authentication** (`--keycloak`): OIDC-based authentication and per-principal authorization via Keycloak. Token helpers live in [`scripts/auth/`](scripts/auth/).
- **Audit Logging** (`--audit`, `--kms-audit`): Tamper-evident audit trail for API and key-management operations, exported to S3-compatible storage.
- **Local CA** (`--ca`): step-ca based certificate authority that issues TLS certificates for service-to-service communication.

> **Note**: The no-TLS KMS overlay (`--kms-notls`) is intended for local development only and must not be used in production.

## ⬆️ Upgrading & Migrations

Database schema migrations and upgrade runbooks for moving between releases are provided in [`scripts/migrations/`](scripts/migrations/):

- `1.4.0-1.4.4_to_latest.sql` + `1.4.0-1.4.4_to_latest_runbook.md` — upgrade from 1.4.0–1.4.4
- `1.4.5-1.4.6_to_latest.sql` + `1.4.5-1.4.6_to_latest_runbook.md` — upgrade from 1.4.5–1.4.6

Always read the matching runbook before applying a migration; it documents prerequisites, backup steps, and verification.

## 🔧 Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `ENVECTOR_ENDPOINT_TAG` | endpoint service image tag | `latest` |
| `ENVECTOR_BACKEND_TAG` | backend service image tag | `latest` |
| `ENVECTOR_ORCHESTRATOR_TAG` | orchestrator service image tag | `latest` |
| `ENVECTOR_COMPUTE_TAG` | compute service image tag | `latest` |
| `ENVECTOR_LOG_LEVEL` | Logging level | `INFO` |
| `ENVECTOR_ENDPOINT_HOST_PORT` | endpoint external port | `50050` |

Optional overlays add further variables (full list and defaults in [`docker-compose/.env.example`](docker-compose/.env.example)):

| Variable | Description | Overlay |
|----------|-------------|---------|
| `ENVECTOR_KMS_SECRET_MANAGER_ADDR` | Vault address used by the KMS | KMS |
| `ENVECTOR_KMS_REQUIRE_SM_TLS` | Require TLS to the secret manager (Vault/OpenBao); legacy `ENVECTOR_KMS_REQUIRE_VAULT_TLS` still honored | KMS |
| `ENVECTOR_AUTH_JWKS_URL` | JWKS endpoint for token validation | Keycloak |
| `ENVECTOR_AUTH_PRINCIPAL_CLAIM` | Token claim used as the principal | Keycloak |
| `KEYCLOAK_REALM` | Keycloak realm name | Keycloak |
| `AUDIT_LOG_SINK` | Audit log sink target | Audit |
| `STEP_CA_URL` | Local CA (step-ca) URL | CA |

### Helm Values

Edit `kubernetes-manifests/helm/values.yaml` to customize:
- Service ports and types
- Resource limits and replicas
- External database connections
- Image repositories and tags


## 📚 Python SDK Usage
* Python Version: 3.9-3.13
* OS: Linux/macOS 11.0+

```bash
pip install pyenvector
```

### Basic Setup

```python
import pyenvector as ev

# Initialize connection
ev.init(
    host="localhost",
    port=50050,
    key_path="./keys",
    key_id="my_key"
)

# Create index
index = ev.create_index("my_index", dim=512)

# Insert vectors
vectors = [
    [0.001 * i for i in range(512)],
    [0.001 * i + 0.001 for i in range(512)],
]
index.insert(vectors, metadata=["doc1", "doc2"])

# Search
results = index.search(vectors[0], top_k=5)
```

### Key Management

```python
from pyenvector.crypto import KeyGenerator, Cipher

# Generate FHE keys
keygen = KeyGenerator("./keys/my_key")
keygen.generate_keys()

# Create cipher for encryption/decryption
cipher = Cipher(dim=512, enc_key_path="./keys/my_key/EncKey.bin")
```

### Example Notebooks

End-to-end examples are available in [`notebooks/`](notebooks/):

- `00-quick-start.ipynb` — minimal getting-started flow
- `01-api-flow.ipynb` — full API workflow
- `02-simple-rag.ipynb` / `03-rag-with-langchain.ipynb` — RAG examples
- `04-ann-api-flow.ipynb` — approximate nearest neighbor (ANN) flow
- `05-insert-load-capacity.ipynb` — insert/load capacity sizing
- `06-gcp-vertex-ai-rag.ipynb` — RAG using GCP Vertex AI embeddings
- `07-kms-key-lifecycle.ipynb` — managed key lifecycle with the enVector KMS
- `08-api-flow-with-kms.ipynb` — end-to-end API flow using the KMS


## 📄 License

This project is proprietary software. For licensing information, please contact [heaan](mailto:hello@heaan.com).

## 🤝 Contributing

This is a proprietary software project. For contribution inquiries, please contact [heaan](mailto:hello@heaan.com).

## 📞 Support

- **Product Information**: [enVector at heaan](https://heaan.com)
- **Technical Support**: Please contact [heaan](mailto:es2.support@heaan.com)

## 🔗 Related Links

- [enVector Product Page](https://heaan.com)
- [heaan](https://heaan.com)
- [FHE Resources](https://fhe.org)

---
