# enVector Self-Hosted Helm Chart Deployment Guide

## Prerequisites
- External PostgreSQL database and storage must be running and accessible.
- If using a private registry, create the imagePullSecret (regcred):
  ```sh
  kubectl create secret docker-registry regcred \
    --docker-server=https://index.docker.io/v1/ \
    --docker-username=<YOUR_USERNAME> \
    --docker-password=<YOUR_PASSWORD> \
    --docker-email=<YOUR_EMAIL>
  ```

## Installation
```sh
helm install envector ./helm
```

- Edit `values.yaml` to match your environment (DB/Storage address, image, port, etc).
- Each service uses readinessProbe and initContainer to automatically wait for dependencies to be ready.

### Using External Secrets Operator (recommended for sensitive values)
- Prerequisite: install External Secrets Operator and configure a SecretStore/ClusterSecretStore.
- Enable `externalSecrets` in `values.yaml` and point to your store. Map sensitive keys you want to source from your secret backend.

Example `values.yaml` snippet:

```yaml
externalSecrets:
  enabled: true
  secretStoreRef:
    kind: ClusterSecretStore
    name: my-secret-store
  appSecret:
    # Secret created by ESO that pods will read from (default: <fullname>-eso)
    name: ""
    refreshInterval: 1m
    data:
      - secretKey: ES2_DB_SERVICE_URL
        remoteRef: { key: "prod/app/db", property: "db_url" }
      - secretKey: ES2_STORAGE_SERVICE_USER
        remoteRef: { key: "prod/minio", property: "accessKey" }
      - secretKey: ES2_STORAGE_SERVICE_PASSWORD
        remoteRef: { key: "prod/minio", property: "secretKey" }
  license:
    enabled: true
    # Secret created by ESO for license (default: <fullname>-es2c-license)
    name: ""
    refreshInterval: 1m
    secretKey: token.jwt
    remoteRef:
      key: "prod/es2/license"
      property: "token.jwt"
```

Notes:
- When `externalSecrets.enabled=true`, the chart stops rendering sensitive values into ConfigMaps and instead injects them from the Secret created by ESO.
- License: with `externalSecrets.enabled=true`, the chart will not create the license Secret itself. Provide `externalSecrets.license.remoteRef` (recommended) or set `es2c.license.existingSecret`.

### License secret management
- Default behavior: license is enabled and the chart creates a Secret on first install.
- Place your license token file at `./token.jwt` (path is relative to the directory you run the `helm` command from). Adjust the path in the examples if you store it elsewhere.
- First install with token file (auto-create Secret):
  ```sh
  helm install envector ./helm \
    --set es2c.license.enabled=true \
    --set es2c.license.createSecret=true \
    --set-file es2c.license.token=./token.jwt
  ```
- Upgrade reusing existing Secret (no flag needed):
  ```sh
  helm upgrade envector ./helm
  ```
- Upgrade replacing token (Secret updated):
  ```sh
  helm upgrade envector ./helm --set-file es2c.license.token=./new-token.jwt
  ```
- Use an external Secret (skip creation):
  ```sh
  helm upgrade envector ./helm \
    --set es2c.license.existingSecret=my-license \
    --set es2c.license.createSecret=false
  ```
- If using an external Secret and you want to force a rollout after updating it, bump:
  ```sh
  --set es2c.license.secret.checksum=$(sha256sum token.jwt | cut -d ' ' -f1)
  ```

## Uninstallation
```sh
helm uninstall envector
```

## Check Status & View Logs
```sh
kubectl get pods
kubectl logs <pod-name>
```

## TLS/HTTPS (Ingress)

Prerequisites
- Install an Ingress Controller (e.g., NGINX) and know the `ingressClassName`.
- Point your domain (DNS) to the Ingress LoadBalancer `EXTERNAL-IP`.
- Optional: Install cert-manager and create a `ClusterIssuer` (recommended for auto-issuance).

Quick setup: cert-manager + ClusterIssuer (if not installed)
```sh
# Install cert-manager with CRDs
helm repo add jetstack https://charts.jetstack.io && helm repo update
helm install cert-manager jetstack/cert-manager -n cert-manager --create-namespace --set installCRDs=true

# Create a staging ClusterIssuer (validate here first)
cat > letsencrypt-staging.yaml << 'EOF'
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    email: you@example.com
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-staging
    solvers:
    - http01:
        ingress:
          class: nginx
EOF
kubectl apply -f letsencrypt-staging.yaml

# Verify
kubectl get clusterissuer

# After validation, create a production issuer similarly
# (change name and server URL)
# server: https://acme-v02.api.letsencrypt.org/directory
```

Option A) cert-manager automated issuance (recommended)
1) Enable Ingress in `values.yaml` and set the ClusterIssuer.
```yaml
ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
  hosts:
    - host: app.example.com
      paths:
        - path: /
          pathType: Prefix
          service:
            name: es2e
            port: 50050
  tls:
    - secretName: app-tls
      hosts:
        - app.example.com
```
2) Deploy/upgrade
```sh
helm upgrade --install envector ./helm -n <namespace> --create-namespace
# Note: when using --set, escape dots in annotation keys
helm upgrade --install envector ./helm -n <namespace> \
  --set ingress.enabled=true \
  --set ingress.className=nginx \
  --set ingress.annotations."cert-manager\.io/cluster-issuer"=letsencrypt-prod \
  --set ingress.tls[0].secretName=app-tls \
  --set ingress.tls[0].hosts[0]=app.example.com \
  --set ingress.hosts[0].host=app.example.com
```

Option B) Manual TLS Secret (private CA / internal networks, etc.)
1) Create a Secret from your PEM files
```sh
kubectl create secret tls app-tls \
  --cert=fullchain.pem --key=privkey.pem -n <namespace>
```
2) In `values.yaml`, reference the Secret in the Ingress TLS block (annotations optional)
```yaml
ingress:
  enabled: true
  className: nginx
  hosts:
    - host: app.example.com
      paths:
        - path: /
          pathType: Prefix
          service:
            name: es2e
            port: 50050
  tls:
    - secretName: app-tls
      hosts:
        - app.example.com
```

Testing
- DNS: `nslookup app.example.com`
- Pre-propagation check: `curl --resolve app.example.com:443:<LB_IP> https://app.example.com -vk`
- Ingress status: `kubectl get ingress -n <namespace>`
- HTTPS response: `curl -I https://app.example.com`
- Certificate details: `openssl s_client -connect app.example.com:443 -servername app.example.com -showcerts`
- With cert-manager: `kubectl get certificate,challenge,order -n <namespace>` and `kubectl logs -n cert-manager deploy/cert-manager`

Troubleshooting checklist
- Port 80 blocked or pre-redirected: HTTP-01 fails → allow 80 or use DNS-01
- Ingress class mismatch: ensure `ingress.className` matches your controller
- Hostname mismatch: Ingress `spec.rules.host` must match TLS `hosts`
- DNS propagation delay: wait for new records to propagate
- Secret format: `kubernetes.io/tls` with `tls.crt`/`tls.key` (auto-set by `kubectl create secret tls`)
- Private cluster: public ACME unreachable → issue via DNS-01
- Node clock skew: causes ACME errors → sync with NTP

## Notes
- es2b waits for external storage and es2c to be reachable before starting.
- es2e waits for es2b and es2o to be reachable before starting.
- es2c mounts a license token from a Secret at `/es2/license` (license is enabled by default). The chart creates the Secret on first install when a token is provided, reuses it on upgrade, and replaces it if a new token is supplied.
