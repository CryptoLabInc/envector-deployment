# gcp/kms-wif — Workload Identity Federation + Confidential Space attestation for kms-tee

Makes the kms-tee **base identity attestation-gated**. Only a Confidential Space
workload running an allowlisted kms-tee image digest can federate (via a Workload
Identity Pool) to the attested base service account, which holds
`serviceAccountTokenCreator` on the 5 per-role SAs. A tampered image, a general
VM, or any non-attested workload fails the pool's attribute condition and never
obtains the base SA — so it can never impersonate the per-role SAs or unwrap `sk`.

This is the attestation layer **above** the per-role impersonation backend; it
replaces the ambient-ADC base of the non-attested (normal-VM) deployment. See
`docs/security/envector-kms-gcp-native-design.md` §7.

## What it provisions
- Workload Identity Pool + a Confidential Space OIDC provider (issuer
  `confidentialcomputing.googleapis.com`, `allowed_audiences = https://sts.googleapis.com`)
  with an attribute condition pinning: `swname == CONFIDENTIAL_SPACE`, the
  deployment `gce.project_number`, the released image digest(s), a `STABLE`
  support attribute, and (default) non-debug.
- The attested base SA (`envector-kms-tee-attested`) — **no direct SM/KMS roles**,
  only federated-into (`workloadIdentityUser`) + `serviceAccountTokenCreator` on
  the 5 per-role SAs.

## What it does NOT do
- The per-role SAs and their least-privilege SM/KMS IAM (managed separately).
- The CMEK / Secret Manager resources.
- The Confidential Space deployment of kms-tee (the next slice) — that consumes
  the `external_account_credential_config` output as `GOOGLE_APPLICATION_CREDENTIALS`.

## Usage
```hcl
module "kms_wif" {
  source     = "./terraform/gcp/kms-wif"
  project_id = "my-gcp-project" # project_number is derived from this
  # The image-digest allowlist is NOT a variable: it is derived from the
  # active entries of kms-digests/kms-tee-released-digests.json.
  kms_keyring = "envector-kms-p0" # expected CMEK keyring (global) — pinned in attestation
  kms_key     = "kek"             # expected CMEK key — pinned in attestation
  # secret_prefix defaults to "envector-kms"; override + set the same on the launcher.
  per_role_sa_emails = {
    keygen          = "ek-keygen@my-gcp-project.iam.gserviceaccount.com"
    rotate          = "ek-rotate@my-gcp-project.iam.gserviceaccount.com"
    key_info        = "ek-key-info@my-gcp-project.iam.gserviceaccount.com"
    score_decryptor = "ek-score-decryptor@my-gcp-project.iam.gserviceaccount.com"
    metadata_cipher = "ek-meta-cipher@my-gcp-project.iam.gserviceaccount.com"
  }
}
```
`terraform init && terraform plan` requires GCP credentials + these APIs enabled:
Cloud IAM, IAM Credentials, STS, and **Cloud Resource Manager**
(`cloudresourcemanager.googleapis.com`). The plan reads `data.google_project` to
derive the project number, so the caller also needs `resourcemanager.projects.get`
on the project. Apply is an operator step (needs the real project + the released
image digest).

## Digest rollout
The measurement allowlist (`local.kms_tee_image_digests`) is derived from the
`active` entries of `kms-digests/kms-tee-released-digests.json`. To
promote a new kms-tee image: add the new digest as `active` in the manifest,
apply, roll the deployment, then flip the old digest to `deprecated` (or
`revoked`) in the manifest and apply again. An empty active set derives a
deny-all `false` clause (the provider admits nothing), so revoking the last
active digest is a valid emergency lockdown rather than an un-appliable state;
the empty seed manifest is committed but the provider is normally stood up once
the first digest is promoted. Promotion is a reviewed GitOps flow: the release
build captures the image digest, the `kms-digest-promote` workflow opens a
CODEOWNERS-gated pull request that appends it as `active`, and after that PR
merges an operator runs `terraform apply` to re-derive this allowlist from the
merged manifest. The manifest edit is the reviewed control (CODEOWNERS); a
required-reviewer environment gate on the apply itself is future work. See
`docs/design/auth/kms-tee-release-digest-pipeline-design-v1.md`.

## Security invariants
This is the canonical statement of the invariants; other docs point here.
- **The base SA holds ONLY** `workloadIdentityUser` (inbound) + `serviceAccountTokenCreator`
  on the 5 per-role SAs (outbound). Granting it direct SM/KMS roles would make
  attestation bypassable via the base SA.
- **The base SA is NEVER attached to the CVM.** The CVM attaches a minimal *runner*
  SA (AR reader + workloadUser + logWriter, no tokenCreator) — the metadata server
  hands the attached SA to any container on the VM without attestation, so attaching
  the base SA would let a tampered image impersonate the per-role SAs and skip the
  gate. The base SA is reachable only via the WIF exchange.
- **This pool (`envector-kms-tee-base`) is DEDICATED to the base SA and has exactly
  ONE provider (the Confidential Space provider).** The `pool -> base SA`
  `workloadIdentityUser` member is pool-wide (`.../<pool>/*`) so the digest
  allowlist (not the member) is the rollout control. The consequence: adding a
  second provider to this pool (e.g. a CI OIDC provider) would let any identity
  that passes THAT provider reach the base SA, bypassing the Confidential Space
  `attribute_condition`. The provider is defined via the single-element
  `local.base_pool_providers` map; a `precondition` inside the `lifecycle` block of
  `google_iam_workload_identity_pool_provider.base` in `main.tf` fails `plan`/`apply`
  with a real `Error:` if that map is ever extended to a second entry (empirically
  verified: a 2nd entry fails plan/apply with a non-zero exit code referencing the
  precondition's error message). This is deliberately a `lifecycle precondition`,
  not a `check`/`assert` block — a `check` block only ever emits a `Warning:` and
  never fails `plan`/`apply` regardless of the assertion result (see the
  `attestation_hardening_enabled` check block below for that weaker, intentionally
  non-blocking pattern). This precondition does NOT block a fully separate provider
  resource added elsewhere in the module — that remains a code-review catch. Do
  not add another workload's identity provider to this pool; give it its own pool.
  This is the GCP realization of the cloud-neutral "attested base = dedicated
  single-strong-attestation-condition trust boundary" contract tracked in
  ES2-2217 (AWS/OCI will realize the same invariant via their own native
  primitives, not WIF).
- **Upgrade note — `pool_id` default changed.** The `pool_id` default is now
  `envector-kms-tee-base` (previously `envector-kms-tee`) to reflect this
  dedicated base-SA pool. A WIF pool id is immutable (`ForceNew`): an existing
  deployment that relied on the old default must set `pool_id =
  "envector-kms-tee"` in its tfvars before applying, otherwise Terraform proposes
  destroying the old pool and creating a new one — and GCP soft-deletes a deleted
  WIF pool for ~30 days, breaking federation for that window. New deployments need
  no action; they provision the dedicated base pool directly.
- **The Cloud KMS keyring (CMEK) MUST be in the `global` location.** The kms-tee Go
  backend pins the KMS location to `global` with no override; a regional keyring
  causes `NOT_FOUND` on the first seal, and a Confidential Space CVM cannot be
  fixed in place — the keyring would have to be recreated in `global`.
- The provider condition pins exact released digests; debug / non-Confidential-Space
  tokens are rejected.
- **The digest/project/`CONFIDENTIAL_SPACE` checks and the runner-SA pin are always
  enforced.** Only two hardening checks are relaxable — `require_stable_support` and
  `require_debug_disabled` — and ONLY to attest a `confidential-space-debug` image
  for launcher troubleshooting. Relaxing either is guarded twice: the
  `attestation_hardening_enabled` check block WARNS on every plan/apply while relaxed,
  and a provider `precondition` BLOCKS apply unless `allow_relaxed_attestation=true`
  is set deliberately — so a stray production tfvars cannot silently weaken the gate.
- The Confidential Space workload carries no static key — the base credential is
  minted from the attestation token via the `external_account` config.
