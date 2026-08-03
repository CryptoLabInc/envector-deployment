# gcp/kms-iam — per-role least-privilege IAM for the kms-tee backend

Provisions the 5 kms-tee **per-role service accounts** and grants each ONLY the
Cloud KMS + Secret Manager permissions its code path uses. This is the sibling
module `gcp/kms-wif` scopes out: kms-wif provisions the attested base SA, the CVM
runner SA, and the `base -> per-role serviceAccountTokenCreator` seam, and leaves
"the per-role SAs and their least-privilege SM/KMS IAM (managed separately)" to
here.

Canonical role -> IAM statement: `docs/security/envector-kms-gcp-native-design.md`
§7 (Attestation Model -> Per-role privilege separation). The permission sets below are the
code-verified minimum — each per-role backend is a narrowed interface, a
compile-time ceiling on what that SA's credential can ever call (e.g. the keygen
backend exposes no `Unseal`, so keygen physically cannot decrypt).

## What it provisions
- 5 per-role SAs: `keygen`, `rotate`, `key-info`, `score-decryptor`, `metadata-cipher`.
- Per-role Cloud KMS IAM, bound at the **crypto-key level** (not project/keyring):
  the sk CMEK (`kms_key`) and, when the per-type split is enabled, a dedicated
  metadata CMEK (`kms_key_metadata`) — see "Per-type CMEK split".
- Per-role Secret Manager IAM (project-level; fenced to the secret namespace by an
  IAM Condition where the permission allows — see "Prefix scoping").
- Custom roles wherever a predefined role would over-grant: KEK rotate, CMEK
  get, SM create/write, SM list.
- `roles/artifactregistry.reader` for the runner SA on the kms-tee image repo.

## What it does NOT provision
- The CMEK keyring/key(s) — customer-managed; **referenced** by
  `kms_keyring`/`kms_key` (and `kms_key_metadata` for the per-type split), never
  created (data sources fail the plan if absent = existence validation).
- The base SA / runner SA / attestation pool — that is `gcp/kms-wif`.
- The `base -> per-role tokenCreator` grant — also `gcp/kms-wif`.
- Secret Manager secrets themselves — created at runtime by kms-tee (keygen).

## The per-role IAM matrix (code-verified)

```
role             | Cloud KMS (on the CMEK key)                    | Secret Manager
-----------------+-----------------------------------------------+-------------------------------------
keygen           | cryptoKeyEncrypter + custom{keys.get}         | create + {delete, versions.add,
                 |   on BOTH CMEKs (seals sk + metadata)         |   versions.access}
rotate           | cryptoKeyEncrypterDecrypter + custom{keys.get}| create + {delete, versions.add/access/
                 |   + custom{versions.create, keys.update}      |   get/list/disable/destroy}
                 |   on BOTH CMEKs (reseal/rotate both)          |
key-info         | (none)                                        | secretAccessor + custom{secrets.list}
score-decryptor  | cryptoKeyDecrypter on the sk CMEK only        | secretAccessor
metadata-cipher  | cryptoKeyDecrypter on the METADATA CMEK only  | secretAccessor
                 |   (NO sk-CMEK access -> cannot unwrap sk)     |
```

The KMS column names WHICH CMEK each role touches under the per-type split (below).
When the split is off (`kms_key_metadata` unset), "BOTH CMEKs" collapses to the one
sk CMEK and both decrypt roles bind to it — identical to a single-CMEK deployment.

All grants use custom roles instead of the predefined `cloudkms.viewer` /
`secretmanager.viewer` where the latter would bundle unused, unfenceable
permissions: `cloudkms.viewer` drags in `cryptoKeyVersions.get/list`, and
`secretmanager.viewer` drags in `secrets.get` / `versions.get` / `versions.list`
project-wide — the module needs only `cloudkms.cryptoKeys.get` and
`secretmanager.secrets.list` respectively.

Notes:
- keygen is **encrypt-only** on Cloud KMS (its backend has no `Unseal`); it is NOT
  granted `cryptoKeys.create` because the CMEK is referenced (guaranteed to exist),
  so it never hits the auto-create path.
- rotate is high-privilege and **decrypt-capable** (its `Reseal` unwraps the DEK) —
  treat it as comparable to the decrypt roles, not as fully isolated from them.
- `key-info` (key-inventory) touches NO Cloud KMS. Distinct from `metadata-cipher`
  (which unwraps the vector-metadata key via Cloud KMS Decrypt).

## Per-type CMEK split

kms-tee wraps two DEK types — the FHE secret key (`sk`) and a per-key metadata
key. Set `kms_key_metadata` (a second crypto key in the SAME keyring as `kms_key`)
to wrap the metadata DEK under a **dedicated CMEK**. The module then binds:

- `metadata-cipher` → Decrypt on the **metadata CMEK only** (never the sk CMEK), so
  a compromised metadata-cipher SA that reads `SecKey.json` still cannot unwrap the
  sk DEK (it is wrapped under the sk CMEK it has no Decrypt on).
- `score-decryptor` → Decrypt on the **sk CMEK only** (symmetric).
- `keygen` / `rotate` → their seal / reseal-rotate grants on **both** CMEKs (they
  operate on both key types).

This is the KEK-level boundary; it cannot be expressed as a Secret Manager IAM
Condition (a decrypt role's `versions.access` cannot be fenced by secret *type* —
the version resource name ends in `/versions/N` and IAM CEL has no `contains`).
Design: `docs/security/per-type-cmek-design.md`. The runtime routes on the KEK
reference (`kek-meta-*` → metadata CMEK); `gcp/kms-wif` pins `kms_key_metadata` in
the attestation condition. Leave `kms_key_metadata` unset for a single-CMEK
deployment (both DEK types wrap under `kms_key`, both decrypt roles bind to it).

**Precondition — greenfield only (enabling the split on an existing deployment is
not supported by the steady-state path).** If a deployment already has metadata
envelopes wrapped under `kms_key` (i.e. it ran single-CMEK), setting
`kms_key_metadata` moves metadata-cipher's Decrypt to the metadata CMEK only, so
those pre-existing envelopes become **undecryptable** (fail-closed, not a leak:
metadata reads error rather than exposing anything). The rotate/reseal path does
**not** migrate them: `Reseal` unwraps and rewraps under the *same* CMEK the
`kekRef` routes to, so it cannot do the cross-CMEK move (decrypt-under-`kms_key` →
re-encrypt-under-metadata-CMEK) that migration requires. Enable the split only on a
**greenfield** namespace (no metadata envelopes yet), or first run a dedicated
one-time cross-CMEK migration tool (not part of this module or the steady-state
reseal path). See `docs/security/per-type-cmek-design.md` §6 / §10.

## Prefix scoping

Secret ids kms-tee creates all begin `<secret_prefix>--` (default
`envector-kms--`). Secrets are named dynamically per tenant/key, so a per-secret
Terraform binding is impossible; instead the fenceable grants carry an IAM
Condition `resource.name.startsWith("projects/<num>/secrets/envector-kms--")`
(toggle `enable_secret_prefix_condition`, default on). This bounds a compromised
per-role SA to the enVector namespace — it cannot read/write other secrets in the
project.

Two permissions **cannot** be prefix-fenced and are therefore isolated into their
own unconditioned project-level roles:
- `secretmanager.secrets.create` — authorizes against the project parent (the
  secret name does not exist yet).
- `secretmanager.secrets.list` (the `key-info` role's `viewer`) — a collection op
  on the project parent.

Both are backstopped by the `gcp/kms-wif` attestation condition, which pins
`ENVECTOR_KMS_GCP_SECRET_PREFIX` so a launch under a different namespace is
rejected regardless of the coarse IAM.

## Usage — wiring with gcp/kms-wif

This module outputs `per_role_sa_emails` in the exact shape `gcp/kms-wif` consumes;
`gcp/kms-wif` outputs `runner_sa_email`, which flows back in here. A single root
config wires both, and the dependency graph is acyclic **at the resource level**,
so no `depends_on` is needed:

- `gcp/kms-wif` keys its `base -> per-role tokenCreator` `for_each` by role **name**
  (not by email), so it accepts these computed SA emails as *values* and its
  tokenCreator bindings implicitly wait for the per-role SAs to exist.
- this module's `runner_reader` takes `gcp/kms-wif`'s runner SA as a value
  (`runner_sa_email`). Under one root — see `../kms-root` — Terraform orders it after that
  SA. Applying the modules from **separate states** cannot express that ordering, so it
  needs three passes: this module first (its apply ends with `runner_reader` failing,
  because granting a role to a nonexistent member is a hard 400), then `gcp/kms-wif`, then
  this module again to settle the binding.

Those are different resources pulling in opposite directions, so the graph is a
DAG (no module-wide `depends_on`, which *would* create a cycle):

```hcl
module "kms_iam" {
  source          = "./terraform/gcp/kms-iam"
  project_id      = "my-gcp-project"
  kms_keyring     = "envector-kms-p0" # existing customer CMEK keyring (global)
  kms_key         = "kek"             # existing CMEK key
  secret_prefix   = "envector-kms"    # MUST match kms-wif + the launcher
  runner_sa_email = module.kms_wif.runner_sa_email
  # ar_location / ar_repository default to asia-northeast3 / es2-images
}

module "kms_wif" {
  source     = "./terraform/gcp/kms-wif"
  project_id = "my-gcp-project"
  # The image-digest allowlist is NOT a variable: kms-wif derives it from the
  # active entries of kms-digests/kms-tee-released-digests.json. A
  # digest is admitted by promoting it into that manifest (the kms-digest-promote
  # GitOps PR / an operator manifest edit) + terraform apply — not via a tfvar.
  kms_keyring        = "envector-kms-p0"
  kms_key            = "kek"
  secret_prefix      = "envector-kms"
  per_role_sa_emails = module.kms_iam.per_role_sa_emails
}
```

The launcher (`gcp-confidential-space/launch-kms-tee.sh`) then consumes
the same `per_role_sa_emails` as its `SA_*` env and `module.kms_wif`'s
`runner_sa_email`/`base_sa_email`/`external_account_credential_config` outputs.

`terraform init && terraform plan` needs GCP credentials plus these APIs enabled:
Cloud IAM, Cloud KMS, Secret Manager, Artifact Registry, and Cloud Resource
Manager (`data.google_project` reads the project number). The caller needs
`resourcemanager.projects.get`, read on the CMEK keyring/key, and IAM-admin on the
project (create SAs + custom roles + set IAM).

## Apply-validation scope

Applying this module against a real project validates that GCP **accepts** the
config: the 5 SAs, the custom roles, every KMS/SM/AR IAM binding (role strings +
IAM-Condition CEL), and that the referenced CMEK resolves. It does **not**
re-prove the per-role runtime behavior end-to-end (that each role can complete
its kms-tee operation and nothing more) — that is the separate kms-tee per-role
integration test. When apply-validating throwaway, set a unique
`custom_role_id_suffix` and test-scoped `*_sa_account_id`s so soft-deleted roles /
SAs never collide with production ids (see `examples/validate.auto.tfvars.example`).

## Upgrade note — resource renames (`metadata` -> `key_info`, `score_decrypt` -> `score_decryptor`)

The per-role rename wave renamed both the Terraform resource **addresses** and the
SA **`account_id` defaults** for two roles:

| role | old address / account_id default | new address / account_id default |
|------|----------------------------------|----------------------------------|
| key-inventory | `google_service_account.metadata` / `ek-metadata` | `google_service_account.key_info` / `ek-key-info` |
| score-decryptor | `google_service_account.score_decrypt` / `ek-score-decrypt` | `google_service_account.score_decryptor` / `ek-score-decryptor` |

`main.tf` carries `moved` blocks that remap the Terraform **address** for both SAs
(and their renamed KMS / Secret Manager IAM bindings), so state migrates in place
instead of being dropped at the old address and re-added at the new one.

**That is not enough on its own.** `account_id` is `ForceNew` on
`google_service_account`, so an existing deployment that used the old account_id
defaults must ALSO pin them, or the next plan destroys and recreates the SAs — and
every IAM grant that references their emails — which is the exact key-access outage
the `moved` blocks exist to prevent. To migrate such a deployment in place, set in
your tfvars:

```hcl
key_info_sa_account_id        = "ek-metadata"       # pre-rename default
score_decryptor_sa_account_id = "ek-score-decrypt"  # pre-rename default
```

New deployments need no action — they provision the new-default account_ids
directly. (This mirrors the `pool_id` upgrade note in `gcp/kms-wif`, which is
`ForceNew` for the same reason.)
