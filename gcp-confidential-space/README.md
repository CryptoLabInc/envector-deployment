# gcp-confidential-space — deploy kms-tee as a Confidential Space workload

The attested runtime for the KMS Confidential Space attestation model. `kms-tee` (the only process
that holds `sk`) runs inside a Confidential Space CVM; its Google-signed attestation
token federates — via the Workload Identity Pool from
`terraform/gcp/kms-wif` — to the attested base SA, which impersonates the
5 per-role SAs. Everything else (the `envector-kms` control plane, storage) stays on
regular GKE/compose. Design: `docs/security/envector-kms-gcp-native-design.md` §7-8.

## Topology

This module is about **kms-tee and the GCP services + service accounts that back
it**. The caller (today, only the `envector-kms` control plane; the design allows
others) is just that — a caller over gRPC; it holds no `sk` and is not special
here. What matters is the identity chain kms-tee climbs, entirely by attestation,
with no static credential anywhere.

```
        clients over gRPC (firewall-only; attestation-bound mTLS is a follow-up)
        today only the envector-kms control plane (design allows others), no sk
                 |
                 v
  +===========================================================+
  |  kms-tee   — the attested KMS                              |
  |  - Confidential Space CVM (SEV), hardware-isolated memory  |
  |  - the ONLY holder of sk                                   |
  |  - attached identity: runner SA                            |
  |      (AR reader + workloadUser + logWriter; NO key access) |
  +===========================================================+
                 |  Google-signed attestation token
                 v
  +-----------------------------------------------------------+
  |  Workload Identity Pool provider   (kms-wif)              |
  |  admits ONLY: allowlisted image digest + this project +   |
  |               STABLE + non-debug + runner SA              |
  +-----------------------------------------------------------+
                 |  federates to (no static key)
                 v
        base SA   (attested; NO direct SM/KMS roles — a pure impersonation hop)
                 |  serviceAccountTokenCreator
                 v
  +------------------- 5 per-role SAs ------------------------+
  | keygen / rotate / key-info / score-decryptor / metadata- |
  | cipher — each least-privileged; audit-attributed per SA  |
  +----------------------------------------------------------+
                 |
                 v
        Secret Manager        Cloud KMS  (CMEK: seal / unseal sk)
```

Each hop is earned, not held: the runner SA can do nothing with keys; the base SA
is reachable only by a workload that satisfies the WIF provider condition; and the
base SA can only *mint* the per-role SAs, never read keys itself. sk never leaves
kms-tee — clients only receive the results of key operations over gRPC.

> **Internal channel security.** The kms-tee gRPC listener (`:50062`) carries secret-key-adjacent traffic. Its mutual-TLS design — step-ca as the CA root and attestation-bound certificate issuance — is specified in [intra-kms-mtls-attestation-design-v1](../../docs/design/auth/intra-kms-mtls-attestation-design-v1.md). The mTLS transport (`services/internal/kms/teetls`, `RequireAndVerifyClientCert`) is realized in the Go services layer; local / docker-compose deployments issue the `:50062` server and client certificates from the step-ca overlay.
>
> On the **Confidential Space path the `:50062` link is not yet mutually authenticated**: attestation-bound issuance to the CVM — a certificate issued only to the attested, allowlisted image — is a separate follow-up. Until it lands, the control-plane -> kms-tee link MUST be isolated by firewall so ONLY `envector-kms` can reach `:50062` — do NOT expose it VPC-wide or publicly. `launch-kms-tee.sh` REQUIRES an explicit `NETWORK`/`SUBNET` (never the default VPC, whose `default-allow-internal` opens `:50062` to every VM). Add an ingress rule scoped by service account (the CVM runs as the runner SA, so target and source by SA — mixing `--target-tags` with `--source-service-accounts` is rejected by GCP):
> ```
> gcloud compute firewall-rules create kms-tee-ingress \
>   --network=$NETWORK --direction=INGRESS --action=ALLOW --rules=tcp:50062 \
>   --target-service-accounts=$RUNNER_SA_EMAIL \
>   --source-service-accounts=<envector-kms SA>
> ```
> If envector-kms runs on GKE, `--source-service-accounts` matches the NODE SA, not the Pod — a Workload Identity K8s SA will NOT match Pod egress. Use the node SA plus the Pod CIDR instead, e.g. `--source-ranges=<pod-cidr>` (scoped to the envector-kms node pool), or another selector matching the real source. Set `NO_EXTERNAL_IP=true` (with Cloud NAT / Private Google Access for egress) to drop the CVM's public IP.

## Prereqs
1. `terraform/gcp/kms-wif` applied. Its measurement allowlist is NOT a
   tfvar — it is **derived** from the `active` entries of the released-digest
   manifest (`kms-digests/kms-tee-released-digests.json`). The digest of
   the image you push in step 2 MUST be admitted by promoting it into that manifest
   (the `kms-digest-promote` GitOps PR or an operator manifest edit) and re-applying
   `kms-wif`. See `terraform/gcp/kms-wif/README.md` ("Digest rollout").
2. kms-tee image pushed to Artifact Registry (CS reads `tee-image-reference` from AR,
   not local docker), e.g. `asia-northeast3-docker.pkg.dev/my-gcp-project/es2-images/envector-kms-tee@sha256:...`.
3. The CVM's attached SA = the minimal **runner** SA (kms-wif output
   `runner_sa_email`), **NOT the base SA** (see Security invariants in
   `terraform/gcp/kms-wif/README.md`). The module grants it
   `roles/confidentialcomputing.workloadUser` + `roles/logging.logWriter`; grant it
   `roles/artifactregistry.reader` on the image repo separately. The operator
   running `launch-kms-tee.sh` also needs `roles/iam.serviceAccountUser` on the
   runner SA to attach it.
4. The Cloud KMS keyring (CMEK) MUST be in the **`global`** location — the kms-tee
   backend pins the KMS location to `global` with no override, so a regional
   keyring fails the first seal with `NOT_FOUND` (see Security invariants).

## Cred-config delivery
The base credential is a WIF `external_account` cred-config JSON (kms-wif output
`external_account_credential_config`) whose `credential_source.file` is the CS token
at `/run/container_launcher/attestation_verifier_claims_token`. It is NOT secret (only
resource names), but the container needs it as a file that `GOOGLE_APPLICATION_CREDENTIALS`
points at. Confidential Space cannot bind-mount host files, so it is delivered via
**entrypoint-writes-from-env** (implemented): `launch-kms-tee.sh` passes the
cred-config JSON as `tee-env-ENVECTOR_KMS_GCP_WIF_CREDCONFIG` (via
`--metadata-from-file`, since the JSON's quotes/slashes break inline metadata
quoting); the kms-tee entrypoint (`materializeWIFCredConfig`) writes it to a file
and exports `GOOGLE_APPLICATION_CREDENTIALS`. Two image labels make this work and
are baked into the kms-tee image:
- `tee.launch_policy.allow_env_override` must list `ENVECTOR_KMS_GCP_WIF_CREDCONFIG`
  (and every other `ENVECTOR_KMS_*` name the launcher injects) — the launcher does
  not apply an operator `tee-env-*` override for any name outside this list, so the
  container would start without those values.
- `tee.launch_policy.log_redirect=always` — so a non-debug (STABLE) production image
  still redirects container stdout to Cloud Logging (the per-role init lines +
  audit). kms-tee never logs key material.

The launcher sets `ENVECTOR_KMS_GCP_REQUIRE_ATTESTED_BASE=true`, and the client-side
guard now **enforces** it: at startup kms-tee resolves its ADC and **fails closed**
(backend construction returns an error; the server never reports SERVING) unless that
ADC is the CS-attested WIF `external_account` cred-config for this deployment —
impersonating the expected base SA (`ENVECTOR_KMS_GCP_BASE_SA`) and, when
`ENVECTOR_KMS_GCP_WIF_AUDIENCE` is set, federating through the exact pinned provider
audience. So if the cred-config is not delivered (e.g. a stale image whose
`allow_env_override` lacks `ENVECTOR_KMS_GCP_WIF_CREDCONFIG`, so the launcher drops it),
the container does **not** start healthy and fail on the first key RPC — it refuses to
start. (Setting `WIF_AUDIENCE=''` downgrades to an audience-shape check with a startup
warning, since the pool grants `workloadIdentityUser` pool-wide.) Independently, the
attestation gate itself does not depend on this flag — it is enforced server-side by the
WIF provider `attribute_condition` (which also pins `REQUIRE_ATTESTED_BASE=true` and
`ENVECTOR_KMS_SECRET_BACKEND=gcp`) + the runner-SA-only attachment.

## Deploy + functional e2e (the real validation)
1. Push the kms-tee image to AR; note its digest; admit it by promoting the digest
   to `active` in the released-digest manifest
   (`kms-digests/kms-tee-released-digests.json`) — via the
   `kms-digest-promote` GitOps PR or an operator manifest edit — from which
   `kms-wif` derives its allowlist (it is NOT a `kms_tee_image_digests` tfvar).
   `cd terraform/gcp/kms-wif && terraform apply` to re-derive the
   allowlist from the merged manifest. Save the cred-config with **`terraform
   output -raw`** (without
   `-raw`, Terraform wraps the string in quotes/escapes and the file is not valid
   ADC JSON): `terraform output -raw external_account_credential_config > wif-credconfig.json`
   (its `credential_source.file` already points at the CS attestation-token path).
   Also capture `terraform output -raw provider_audience` — the launcher pins it via
   `WIF_AUDIENCE` (the attestation condition binds that env to the same value, so the
   base ADC cannot federate through another provider in the pool).
2. Grant the `runner_sa_email` output `roles/artifactregistry.reader` on the image
   repo (the module grants workloadUser + logWriter; AR is repo-scoped).
3. `PROJECT_ID=... ZONE=... TEE_IMAGE=...@sha256:... RUNNER_SA_EMAIL=<runner_sa_email> \
   BASE_SA_EMAIL=<base_sa_email> NETWORK=<vpc> SUBNET=<subnet> \
   WIF_CREDCONFIG_FILE=<path to the saved cred-config json> \
   WIF_AUDIENCE=<provider_audience> \
   ENVECTOR_KMS_GCP_KMS_KEYRING=... ENVECTOR_KMS_GCP_KMS_KEY=... \
   SA_KEYGEN=... SA_ROTATE=... SA_KEY_INFO=... SA_SCORE_DECRYPTOR=... SA_METADATA_CIPHER=... \
   ./launch-kms-tee.sh`
   (add the `:50062` firewall rule from the topology note; optionally `NO_EXTERNAL_IP=true`.)
4. Confirm attested federation: the kms-tee logs show the 5 distinct
   `tee_role=...,impersonate_sa=...` init lines (per-role via the attested base) and a
   real KMS op (keygen -> Cloud KMS seal) succeeds — with NO static key in the CVM.
5. Point the SDK e2e (`kms_sdk_msa_e2e.py`) at the stack (control plane + this kms-tee)
   and run insert/search to prove the full path end-to-end.
6. Negative test: a non-allowlisted digest / different project / debug image must be
   DENIED the base SA (the core security claim).

## Teardown
`gcloud compute instances delete <INSTANCE> --zone=<ZONE>` + `terraform destroy` in kms-wif.

## Machine / image
SEV: `n2d-standard-2`, `--maintenance-policy=MIGRATE`. TDX: `c3-standard-*`, TERMINATE.
Image: `--image-project=confidential-space-images --image-family=confidential-space`
(prod) or `confidential-space-debug` (debug — will NOT satisfy the STABLE / non-debug
provider condition, so debug is for launcher troubleshooting only).
