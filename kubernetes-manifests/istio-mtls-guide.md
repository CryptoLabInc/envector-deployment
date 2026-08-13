# enVector on Kubernetes — Istio mTLS Enablement Guide

How to encrypt service-to-service traffic with mTLS via Istio sidecars **without
modifying the helm chart at all**. No app-code or chart changes — you layer the
mesh policy (sidecar injection + `PeerAuthentication`) on from the outside.

> The commands, YAML, and verification steps in this doc were actually deployed
> and validated on minikube (k8s 1.31) + Istio 1.22. Under STRICT mTLS, e2e
> (10000-vector insert/search) and the orchestrator↔compute headless links were
> confirmed working.

---

## Why no chart change is needed

- All service-to-service traffic is gRPC, and the apps dial service DNS names in
  plaintext (`insecure`).
- The Istio sidecar (Envoy) intercepts traffic via iptables and **transparently
  upgrades the hop to mTLS** against the peer pod's sidecar. The app still
  believes it is sending plaintext.
- So no certificate-loading or TLS code is needed in the app/chart. Certificate
  issuance and rotation are handled entirely by the Istio CA.

Notes confirmed by hands-on testing:
- **No DestinationRule needed**: Istio 1.22 applies auto-mTLS even to the headless
  (orchestrator/compute) services (it auto-attaches a TLS transport socket to the
  ORIGINAL_DST cluster). On older Istio, or in mixed mesh/non-mesh setups, you may
  still need an explicit `DestinationRule` with `tls.mode: ISTIO_MUTUAL`.
- **No port name (appProtocol) needed (for mTLS only)**: even unnamed ports get
  L7 gRPC detected via protocol sniffing and mTLS works fine. To make L7
  observability/routing deterministic, giving the port `appProtocol: grpc` is
  recommended (separate, not required).

---

## Prerequisites

- A running Kubernetes cluster, `kubectl`/`helm`
- `istioctl` (e.g. 1.22.x)
- The namespace where the enVector chart is (or will be) deployed — examples
  below use `envector`

---

## 1. Install Istio

```bash
istioctl install --set profile=demo -y      # for production, prefer the default/minimal profile
kubectl -n istio-system get pods             # confirm istiod etc. are Running
```

## 2. Enable automatic sidecar injection on the namespace

```bash
kubectl label namespace envector istio-injection=enabled --overwrite
```

## 3. Inject sidecars into existing workloads (restart)

The label only applies to "pods created afterwards", so already-running pods need
a restart.

```bash
kubectl -n envector rollout restart deploy,statefulset
# wait until every pod is 2/2 (app + istio-proxy)
kubectl -n envector get pods -w
```

## 4. Start with PERMISSIVE mTLS (safe rollout)

Enabling STRICT immediately breaks traffic while any pod still lacks a sidecar.
First run in plaintext+mTLS coexistence (PERMISSIVE) and confirm every pod has a
sidecar.

```yaml
# istio-peerauth.yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: envector
spec:
  mtls:
    mode: PERMISSIVE
```

```bash
kubectl apply -f istio-peerauth.yaml
# confirm all pods are 2/2
kubectl -n envector get pods
# confirm mTLS negotiation actually happens (e.g. from the endpoint pod)
istioctl authn tls-check "$(kubectl -n envector get pod -l component=endpoint -o jsonpath='{.items[0].metadata.name}').envector"
```

## 5. Switch to STRICT (reject plaintext)

Change `mode: PERMISSIVE` → `STRICT`. Either edit `istio-peerauth.yaml` by hand
and re-apply, or patch it in place (portable across Linux/macOS — avoids the
GNU/BSD `sed -i` incompatibility):

```bash
kubectl -n envector patch peerauthentication default \
  --type merge -p '{"spec":{"mtls":{"mode":"STRICT"}}}'
```

---

## Verification

```bash
# (1) confirm backend inbound requires mTLS (expect requireClientCertificate: true)
BE=$(kubectl -n envector get pod -l component=backend -o jsonpath='{.items[0].metadata.name}')
istioctl proxy-config listener "$BE.envector" --port 15006 -o json | grep -E 'requireClientCertificate|transportProtocol'

# (2) plaintext request from a non-mesh pod -> must be rejected (reset)
BIP=$(kubectl -n envector get pod -l component=backend -o jsonpath='{.items[0].status.podIP}')
kubectl -n envector run plain --rm -i --restart=Never \
  --image=curlimages/curl:8.10.1 --annotations sidecar.istio.io/inject=false -- \
  curl -sS -m5 http://$BIP:8080/health || echo "REJECTED = mTLS enforced"

# (3) same request from a mesh (sidecar-injected) pod -> 200 (sidecar upgrades to mTLS)
kubectl -n envector run mesh --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  sh -c "sleep 8; curl -sS -m8 -o /dev/null -w '%{http_code}\n' http://ev-envector-chart-backend:8080/health"
```

Expected: (1) `requireClientCertificate: true`, `transportProtocol: tls` /
(2) connection reset / (3) `200`.

---

## Rollout caveats

1. **Headless services (orchestrator, compute, shaper)**: all three are headless
   StatefulSets, so clients always send mTLS directly to the destination pod.
   Before switching to STRICT, make absolutely sure **every pod in each
   StatefulSet has a sidecar** (they can break before ClusterIP services do).
   Verify this during the PERMISSIVE stage.
2. **kms-tee (TEE)**: if you run kms-tee on k8s, terminating TLS in Envoy
   **outside** the enclave breaks the confidentiality guarantee. **Exclude** the
   kms↔kms-tee channel from the sidecar and use attested TLS (app-layer)
   terminated inside the enclave.
   ```yaml
   # kms-tee pod template annotations
   sidecar.istio.io/inject: "false"
   ```
3. **Datastores (PostgreSQL/S3/MinIO/Kafka)**: two cases.
   - **External managed DB/S3**: traffic leaves the mesh, so it's out of Istio's
     scope. Handle it separately with app settings such as `sslmode` in
     `ENVECTOR_DB_URL` and `ENVECTOR_STORAGE_SECURE`.
   - **Chart-embedded (`embeddedPostgres`/`embeddedMinio`/`audit-logmq`)**: these
     are same-namespace StatefulSets, so the namespace label in step 2 **injects a
     sidecar and pulls them into the mesh**. That means namespace-wide STRICT
     applies to them too. Pick one of two options:
     - **Exclude** them like kms-tee via `sidecar.istio.io/inject: "false"`
       (keep app-level TLS/plaintext), or
     - Keep them in the mesh, but since Postgres/Kafka are non-HTTP protocols, be
       sure to verify mTLS negotiation and startup ordering during the PERMISSIVE
       stage.
4. **Health checks**: Istio automatically rewrites kubelet HTTP probes through
   pilot-agent (15020) (enabled by default). Confirm probes still pass under
   STRICT.
5. **Startup dial race**: apps that connect to other services immediately on boot
   may come up before the sidecar and fail. If needed, add to the pod:
   `proxy.istio.io/config: '{"holdApplicationUntilProxyStarts": true}'`.

---

## Rollback

```bash
# STRICT -> back to allowing plaintext
kubectl -n envector delete peerauthentication default
# stop sidecar injection (sidecars are removed from pods restarted afterwards)
kubectl label namespace envector istio-injection-
kubectl -n envector rollout restart deploy,statefulset
```

---

## Recommended improvement (optional, not required for mTLS)

For reliable L7 gRPC observability/routing, it helps to declare the protocol on
gRPC service ports (this is a chart change, so it's out of scope for this guide —
apply it separately when desired). Use **either** of these; they are alternatives,
not both required:

```yaml
# Option 1 (preferred): declare the protocol explicitly
ports:
  - port: 25123
    appProtocol: grpc
```

```yaml
# Option 2: or name the port with a "grpc-" prefix (Istio infers gRPC from it)
ports:
  - port: 25123
    name: grpc-compute
```
