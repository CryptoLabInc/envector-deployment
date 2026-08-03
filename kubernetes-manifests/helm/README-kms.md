# Deploying the enVector KMS with this chart

`kms.enabled=true` adds the KMS control plane (`envector-kms`) to the chart. It is the
deployment path used by
[`docs/runbooks/kms/gcp-kms-backend-guide.md`](../../../docs/runbooks/kms/gcp-kms-backend-guide.md)
sections 4.3 and 5; that guide's Appendix A keeps the older single-host
`docker-compose` topology for quick verification only. Everything before section 4.3
(Terraform, digest allowlist, CVM launch) is the same either way.

## What runs where

| Component | Where |
|---|---|
| MSA services + `envector-kms` control plane | GKE pods (this chart) |
| `envector-kms-tee` — holds plaintext secret keys | **Confidential Space CVM, outside the cluster** |

The TEE is not a pod in production: its guarantee comes from Confidential Space measuring
the exact image and federating through Workload Identity. A normal pod cannot produce that
attestation. `kms.tee.mode=in-cluster` runs it as a pod anyway for development — useful to
exercise the GCP secret backend without a CVM, but it is **not** an attested deployment.

## External TEE (production)

```bash
helm upgrade --install envector ./helm \
  --set kms.enabled=true \
  --set kms.tee.mode=external \
  --set kms.tee.addr=10.128.0.7:50062 \
  --set kms.storage.bucket=kms-keys
```

Prerequisites beyond the runbook's sections 1–4.2:

- The CVM's `:50062` firewall rule must admit the **GKE pod CIDR** (the runbook's
  `--source-service-accounts` matches the *node* SA, which is not what pod traffic
  presents unless IP masquerading is on).
- `:50062` is plaintext today. Keep the CVM on the cluster's VPC and do not route it
  through anything public. Once attestation-bound mTLS lands, set
  `kms.tee.mtls.enabled=true` with `kms.tee.mtls.existingSecret`.

The control plane deliberately gets **no** `ENVECTOR_KMS_SECRET_BACKEND`, no GCP config,
and no credentials — only the TEE may read a sealed key or unwrap the DEK. `kms.gcp.*` is
ignored in external mode (the CVM launcher supplies those as attested `tee-env-*`
metadata).

## In-cluster TEE (development only)

```bash
helm upgrade --install envector ./helm \
  --set kms.enabled=true \
  --set kms.tee.mode=in-cluster \
  --set kms.gcp.project=my-gcp-project \
  --set kms.gcp.kmsKeyring=envector-kms \
  --set kms.gcp.kmsKey=envector-kek \
  --set kms.gcp.secretPrefix=envector-kms-e2e \
  --set kms.gcp.serviceAccounts.keygen=ek-keygen@my-gcp-project.iam.gserviceaccount.com \
  --set kms.gcp.serviceAccounts.rotate=ek-rotate@my-gcp-project.iam.gserviceaccount.com \
  --set kms.gcp.serviceAccounts.keyInfo=ek-key-info@my-gcp-project.iam.gserviceaccount.com \
  --set kms.gcp.serviceAccounts.scoreDecryptor=ek-score-decryptor@my-gcp-project.iam.gserviceaccount.com \
  --set kms.gcp.serviceAccounts.metadataCipher=ek-metacipher@my-gcp-project.iam.gserviceaccount.com \
  --set kms.tee.serviceAccount.annotations."iam\.gke\.io/gcp-service-account"=ek-tee-base@my-gcp-project.iam.gserviceaccount.com
```

The five SA emails come from `terraform output -json per_role_sa_emails` (runbook 2.1). The
GSA bound to the TEE's Kubernetes SA needs `roles/iam.serviceAccountTokenCreator` on each of
them and nothing else — same base-SA boundary the CVM uses.

## Object storage

The KMS stores **public** keys in an S3/MinIO bucket. By default it reuses whatever the MSA
services use (`embeddedMinio` or `externalServices.storage`) under a separate bucket
(`kms.storage.bucket`, default `kms-keys`). `externalServices.storage.provider=gcs` is not
usable — the KMS uses a MinIO client — so set `kms.storage.endpoint` and
`kms.storage.existingSecret` explicitly there.

## Client access

The SDK dials the control plane's gRPC port:

```python
client.init_kms_connect(kms_address="<kms-service>:50060", secure=True)
```

For access from outside the cluster, either set `kms.service.type=LoadBalancer` or add a
path to `ingress.hosts[].paths[].service` pointing at the KMS Service. Serve it over TLS:
put a `kubernetes.io/tls` Secret in `kms.tls.existingSecret` and set `kms.tls.require=true`
so the server refuses to fall back to cleartext.
