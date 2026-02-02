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
- **📱 Python SDK**: Easy-to-use client library for integration


## 🔒 Security Features

- **Fully Homomorphic Encryption**: Secure computation on encrypted data
- **Client-side Key Management**: Secret key never leave the client
- **Encrypted Vector Storage**: All vector data is encrypted at rest (at-rest)
- **Secure Search**: Search operations performed on encrypted data  (in-use)

## 📊 Performance

- **Vector Dimensions**: Support for 32-4096 dimensional vectors
- **Search Speed**: Optimized encrtyped similarity search algorithms
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

enVector consists of four main microservices:

- **Endpoint**: Main API gateway and client interface
- **Backend**: Service orchestration and metadata management
- **Orchestrator**: Manages and schedules compute requests
- **Compute**: Executes vector search and similarity computations

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
│   ├── .env.example                 # environment variables for envector
│   ├── start_envector.sh            # easy-to-use helper script
│   └── README.md                    # Docker setup guide
├── kubernetes-manifests/            # Kubernetes deployment
│   ├── helm/                        # Helm chart for K8s
│   │   ├── Chart.yaml               # Chart metadata
│   │   ├── values.yaml              # Configurable values
│   │   └── templates/               # K8s manifest templates
│   └── README.md                    # K8s deployment guide
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
cipher = Cipher(dim=512, enc_key_path="./keys/my_key/EncKey.json")
```


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
