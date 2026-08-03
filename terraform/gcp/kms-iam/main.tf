# Per-role least-privilege IAM for the kms-tee Confidential Space backend.
#
# The kms-tee backend impersonates 5 per-role service accounts (keygen / rotate /
# key-info / score-decryptor / metadata-cipher) from an attested base identity, so
# every Secret Manager / Cloud KMS call is attributed to — and bounded by — one
# role's SA. gcp/kms-wif provisions the base SA, the runner SA, and the
# base -> per-role serviceAccountTokenCreator seam, but explicitly leaves the
# per-role SAs' own least-privilege SM/KMS IAM to be managed separately. THIS is
# that module: it creates the 5 SAs, grants each exactly the Cloud KMS + Secret
# Manager permissions its code path uses (no more), grants the runner SA
# artifactregistry.reader on the image repo, and exports per_role_sa_emails for
# gcp/kms-wif to consume.
#
# The op -> permission mapping below is the code-verified least-privilege matrix
# (the per-role backend interfaces are compile-time ceilings — e.g. the keygen
# backend has no Unseal method, so keygen physically cannot decrypt). Canonical
# statement: docs/security/envector-kms-gcp-native-design.md §7 (Attestation
# Model -> Per-role privilege separation).

terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
}

# Project number is needed for the Secret Manager IAM-Condition resource.name
# (Secret Manager expresses resource names as projects/<number>/secrets/<id>).
data "google_project" "this" {
  project_id = var.project_id
}

# Reference (do NOT create) the customer-managed CMEK. The data sources fail the
# plan if the keyring/key is absent, so a misconfigured keyring/key name is caught
# at plan time rather than at the first seal inside the CVM.
data "google_kms_key_ring" "cmek" {
  name     = var.kms_keyring
  location = var.kms_location
  project  = var.project_id
}

data "google_kms_crypto_key" "cmek" {
  name     = var.kms_key
  key_ring = data.google_kms_key_ring.cmek.id
}

# The dedicated metadata CMEK (per-type split), in the SAME keyring as the sk CMEK.
# Referenced (not created) + existence-validated, only when configured. When unset,
# the metadata DEK falls back to the sk CMEK (single-CMEK behavior).
data "google_kms_crypto_key" "cmek_metadata" {
  count    = local.metadata_cmek_enabled ? 1 : 0
  name     = var.kms_key_metadata
  key_ring = data.google_kms_key_ring.cmek.id

  # A metadata CMEK equal to the sk CMEK would enable the split yet resolve both
  # key types to the same key — metadata-cipher would then hold Decrypt on the sk
  # key, silently collapsing the boundary this module exists to enforce. Only
  # evaluated when the split is on (count = 1).
  lifecycle {
    precondition {
      condition     = var.kms_key_metadata != var.kms_key
      error_message = "kms_key_metadata must differ from kms_key (a distinct metadata CMEK); reusing the sk key collapses the per-type sk/metadata boundary."
    }
  }
}

locals {
  ar_project = coalesce(var.ar_project_id, var.project_id)

  # Per-type CMEK split: when a dedicated metadata CMEK is configured, the metadata
  # DEK is wrapped under it, so metadata-cipher decrypts ONLY this key (never the sk
  # CMEK) and keygen/rotate additionally seal/rotate it. When unset, the metadata
  # DEK falls back to the sk CMEK and metadata-cipher stays bound to it.
  metadata_cmek_enabled = var.kms_key_metadata != null && var.kms_key_metadata != ""
  metadata_cmek_id      = local.metadata_cmek_enabled ? data.google_kms_crypto_key.cmek_metadata[0].id : data.google_kms_crypto_key.cmek.id

  # Every secret this instance creates is named "<prefix>--<...>" (the backend
  # maps "/"->"--"), so the namespace is fenced by this resource.name prefix.
  secret_name_prefix = "${var.secret_prefix}--"

  # IAM Condition that fences a grant to the envector-kms secret namespace. Valid
  # for permissions that authorize against a secret/version resource
  # (versions.access, versions.add, secrets.get/delete, versions.get/list/...);
  # NOT for secrets.create / secrets.list (project-parent authorization).
  secret_prefix_expr = "resource.name.startsWith(\"projects/${data.google_project.this.number}/secrets/${local.secret_name_prefix}\")"

  # Drives the optional dynamic "condition" block (one binding vs zero).
  prefix_condition = var.enable_secret_prefix_condition ? [1] : []
}

# ============================================================================
# The 5 per-role service accounts
# ============================================================================
resource "google_service_account" "keygen" {
  project      = var.project_id
  account_id   = var.keygen_sa_account_id
  display_name = "enVector KMS keygen (per-role)"
  description  = "kms-tee keygen role. Cloud KMS encrypt (seal) + get; Secret Manager create/write within the ${var.secret_prefix} namespace. Impersonated by the attested base SA only."
}

resource "google_service_account" "rotate" {
  project      = var.project_id
  account_id   = var.rotate_sa_account_id
  display_name = "enVector KMS rotate (per-role)"
  description  = "kms-tee rotate role. Cloud KMS encrypt+decrypt (reseal) + CMEK version create/promote; Secret Manager read/write/deactivate/destroy within the ${var.secret_prefix} namespace. High-privilege (decrypt-capable). Impersonated by the attested base SA only."
}

resource "google_service_account" "key_info" {
  project      = var.project_id
  account_id   = var.key_info_sa_account_id
  display_name = "enVector KMS key-info (per-role)"
  description  = "kms-tee key-inventory role. Secret Manager read + list only, NO Cloud KMS. Impersonated by the attested base SA only."
}

resource "google_service_account" "score_decryptor" {
  project      = var.project_id
  account_id   = var.score_decryptor_sa_account_id
  display_name = "enVector KMS score-decryptor (per-role)"
  description  = "kms-tee score-decryptor role. Cloud KMS decrypt (unseal) only; Secret Manager payload read only. Impersonated by the attested base SA only."
}

resource "google_service_account" "metadata_cipher" {
  project      = var.project_id
  account_id   = var.metadata_cipher_sa_account_id
  display_name = "enVector KMS metadata-cipher (per-role)"
  description  = "kms-tee metadata-cipher role. Cloud KMS decrypt only (unwraps the metadata DEK; metadata is then ciphered locally, so no Cloud KMS encrypt); Secret Manager payload read only. Impersonated by the attested base SA only."
}

# ============================================================================
# Custom roles (least-privilege; predefined roles over-grant here)
# ============================================================================

# Cloud KMS: rotate creates a new CMEK version and promotes it to primary.
# roles/cloudkms.admin would cover create+update but NOT the encrypt/decrypt
# use-permissions rotate also needs (granted via cryptoKeyEncrypterDecrypter),
# and would over-grant destroy/setIamPolicy — so a tight custom role instead.
resource "google_project_iam_custom_role" "kek_rotate" {
  project     = var.project_id
  role_id     = "envectorKmsKekRotate${var.custom_role_id_suffix}"
  title       = "enVector KMS KEK Rotate"
  description = "Create a new CMEK version and promote it to primary (kms-tee rotate role). Paired with roles/cloudkms.cryptoKeyEncrypterDecrypter + the cryptoKeys.get custom role on the same key."
  permissions = [
    "cloudkms.cryptoKeyVersions.create",
    "cloudkms.cryptoKeys.update",
  ]
}

# Cloud KMS: keygen (EnsureKEK) and rotate (version hint) call GetCryptoKey. Only
# cloudkms.cryptoKeys.get is needed; roles/cloudkms.viewer would additionally
# bundle cryptoKeyVersions.get/list, so a get-only custom role instead.
resource "google_project_iam_custom_role" "key_get" {
  project     = var.project_id
  role_id     = "envectorKmsKeyGet${var.custom_role_id_suffix}"
  title       = "enVector KMS Key Get"
  description = "Read CMEK crypto-key metadata (GetCryptoKey) for kms-tee keygen (EnsureKEK, fatal without it) and rotate (primary-version hint). cryptoKeys.get only."
  permissions = [
    "cloudkms.cryptoKeys.get",
  ]
}

# Secret Manager: secrets.create authorizes against the PROJECT parent (the secret
# name does not exist yet), so it cannot be fenced by a resource.name condition.
# It is isolated into its own unconditioned project-level role, shared by the two
# writer roles (keygen, rotate); everything else they need is in the conditioned
# role below.
resource "google_project_iam_custom_role" "secret_create" {
  project     = var.project_id
  role_id     = "envectorKmsSecretCreate${var.custom_role_id_suffix}"
  title       = "enVector KMS Secret Create"
  description = "Create Secret Manager secrets (kms-tee keygen/rotate). Unconditioned because secrets.create authorizes against the project parent; the namespace is pinned by the kms-wif attestation condition."
  permissions = [
    "secretmanager.secrets.create",
  ]
}

# keygen's fenceable write set: rollback delete + add versions + read payloads.
resource "google_project_iam_custom_role" "secret_keygen_rw" {
  project     = var.project_id
  role_id     = "envectorKmsSecretKeygenRW${var.custom_role_id_suffix}"
  title       = "enVector KMS Secret Keygen RW"
  description = "kms-tee keygen: add secret versions, read payloads, delete secrets on rollback. Prefix-fenceable (paired with the unconditioned secrets.create role)."
  permissions = [
    "secretmanager.secrets.delete",
    "secretmanager.versions.add",
    "secretmanager.versions.access",
  ]
}

# rotate's fenceable write set: keygen's + deactivate (get/disable) + destroy
# (list/destroy) for DeactivateSecKey / DestroySecKey.
resource "google_project_iam_custom_role" "secret_rotate_rw" {
  project     = var.project_id
  role_id     = "envectorKmsSecretRotateRW${var.custom_role_id_suffix}"
  title       = "enVector KMS Secret Rotate RW"
  description = "kms-tee rotate: keygen's write set plus version get/list/disable/destroy for key deactivate/destroy. Prefix-fenceable (paired with the unconditioned secrets.create role)."
  permissions = [
    "secretmanager.secrets.delete",
    "secretmanager.versions.add",
    "secretmanager.versions.access",
    "secretmanager.versions.get",
    "secretmanager.versions.list",
    "secretmanager.versions.disable",
    "secretmanager.versions.destroy",
  ]
}

# Secret Manager: the key-info (key-inventory) role lists key ids via ListSecrets.
# Only secretmanager.secrets.list is needed; roles/secretmanager.viewer would
# additionally bundle secrets.get / versions.get / versions.list (unused, and
# unfenceable) — a compromised key-info SA could then read every secret's
# metadata project-wide. secrets.list is a collection op on the project parent so
# it cannot be prefix-conditioned; kept minimal via a list-only custom role. (The
# key-info role reads payloads via a separate prefix-conditioned secretAccessor.)
resource "google_project_iam_custom_role" "secret_list" {
  project     = var.project_id
  role_id     = "envectorKmsSecretList${var.custom_role_id_suffix}"
  title       = "enVector KMS Secret List"
  description = "List Secret Manager secret ids (kms-tee key-info/key-inventory role, ListKeyIDs). secrets.list only; unconditioned (collection op on the project parent)."
  permissions = [
    "secretmanager.secrets.list",
  ]
}

# ============================================================================
# Cloud KMS IAM — scoped to the single CMEK crypto key (not project/keyring)
# ============================================================================

# keygen: encrypt (seal) + get (EnsureKEK GetCryptoKey is fatal without get).
# Encrypt-only is safe: the keygen backend exposes no Unseal (compile-time), so it
# never decrypts. cryptoKeys.create is intentionally NOT granted — the CMEK is
# referenced (guaranteed to exist), so keygen never hits the auto-create path.
resource "google_kms_crypto_key_iam_member" "keygen_encrypt" {
  crypto_key_id = data.google_kms_crypto_key.cmek.id
  role          = "roles/cloudkms.cryptoKeyEncrypter"
  member        = "serviceAccount:${google_service_account.keygen.email}"
}

resource "google_kms_crypto_key_iam_member" "keygen_get" {
  crypto_key_id = data.google_kms_crypto_key.cmek.id
  role          = google_project_iam_custom_role.key_get.id
  member        = "serviceAccount:${google_service_account.keygen.email}"
}

# rotate: encrypt+decrypt (reseal), get (version hint), and version create + key
# update (rotate_kek). High-privilege, decrypt-capable by design.
resource "google_kms_crypto_key_iam_member" "rotate_encrypt_decrypt" {
  crypto_key_id = data.google_kms_crypto_key.cmek.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_service_account.rotate.email}"
}

resource "google_kms_crypto_key_iam_member" "rotate_get" {
  crypto_key_id = data.google_kms_crypto_key.cmek.id
  role          = google_project_iam_custom_role.key_get.id
  member        = "serviceAccount:${google_service_account.rotate.email}"
}

resource "google_kms_crypto_key_iam_member" "rotate_kek" {
  crypto_key_id = data.google_kms_crypto_key.cmek.id
  role          = google_project_iam_custom_role.kek_rotate.id
  member        = "serviceAccount:${google_service_account.rotate.email}"
}

# score-decryptor: decrypt (unseal) only — no encrypt, no get.
resource "google_kms_crypto_key_iam_member" "score_decryptor_decrypt" {
  crypto_key_id = data.google_kms_crypto_key.cmek.id
  role          = "roles/cloudkms.cryptoKeyDecrypter"
  member        = "serviceAccount:${google_service_account.score_decryptor.email}"
}

# metadata-cipher: decrypt only, and ONLY the metadata CMEK (per-type split). It
# unseals the metadata DEK and never sk, so it must hold NO Decrypt on the sk CMEK
# — that is what stops a compromised metadata-cipher SA from unwrapping sk after
# reading SecKey.json. Falls back to the sk CMEK when no metadata CMEK is set.
resource "google_kms_crypto_key_iam_member" "metadata_cipher_decrypt" {
  crypto_key_id = local.metadata_cmek_id
  role          = "roles/cloudkms.cryptoKeyDecrypter"
  member        = "serviceAccount:${google_service_account.metadata_cipher.email}"
}

# keygen + rotate also operate on the metadata CMEK when the per-type split is on:
# keygen seals the metadata key, rotate reseals + rotates it. Same roles as their
# sk-CMEK grants, bound to the metadata key. count=0 when the split is off (in
# single-CMEK mode the metadata DEK is under the sk CMEK, already covered above).
resource "google_kms_crypto_key_iam_member" "keygen_encrypt_metadata" {
  count         = local.metadata_cmek_enabled ? 1 : 0
  crypto_key_id = data.google_kms_crypto_key.cmek_metadata[0].id
  role          = "roles/cloudkms.cryptoKeyEncrypter"
  member        = "serviceAccount:${google_service_account.keygen.email}"
}

resource "google_kms_crypto_key_iam_member" "keygen_get_metadata" {
  count         = local.metadata_cmek_enabled ? 1 : 0
  crypto_key_id = data.google_kms_crypto_key.cmek_metadata[0].id
  role          = google_project_iam_custom_role.key_get.id
  member        = "serviceAccount:${google_service_account.keygen.email}"
}

resource "google_kms_crypto_key_iam_member" "rotate_encrypt_decrypt_metadata" {
  count         = local.metadata_cmek_enabled ? 1 : 0
  crypto_key_id = data.google_kms_crypto_key.cmek_metadata[0].id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_service_account.rotate.email}"
}

resource "google_kms_crypto_key_iam_member" "rotate_get_metadata" {
  count         = local.metadata_cmek_enabled ? 1 : 0
  crypto_key_id = data.google_kms_crypto_key.cmek_metadata[0].id
  role          = google_project_iam_custom_role.key_get.id
  member        = "serviceAccount:${google_service_account.rotate.email}"
}

resource "google_kms_crypto_key_iam_member" "rotate_kek_metadata" {
  count         = local.metadata_cmek_enabled ? 1 : 0
  crypto_key_id = data.google_kms_crypto_key.cmek_metadata[0].id
  role          = google_project_iam_custom_role.kek_rotate.id
  member        = "serviceAccount:${google_service_account.rotate.email}"
}

# score-decryptor stays bound to the sk CMEK only (it unseals sk, never metadata).
# key-info role: NO Cloud KMS binding (key-inventory only).

# ============================================================================
# Secret Manager IAM — project-level; fenceable grants carry the prefix condition
# ============================================================================

# --- keygen (create unconditioned; the rest fenced) ---
resource "google_project_iam_member" "keygen_sm_create" {
  project = var.project_id
  role    = google_project_iam_custom_role.secret_create.id
  member  = "serviceAccount:${google_service_account.keygen.email}"
}

resource "google_project_iam_member" "keygen_sm_rw" {
  project = var.project_id
  role    = google_project_iam_custom_role.secret_keygen_rw.id
  member  = "serviceAccount:${google_service_account.keygen.email}"

  dynamic "condition" {
    for_each = local.prefix_condition
    content {
      title       = "envector-kms-namespace"
      description = "Fence to the ${local.secret_name_prefix} secret namespace."
      expression  = local.secret_prefix_expr
    }
  }
}

# --- rotate (create unconditioned; the rest fenced) ---
resource "google_project_iam_member" "rotate_sm_create" {
  project = var.project_id
  role    = google_project_iam_custom_role.secret_create.id
  member  = "serviceAccount:${google_service_account.rotate.email}"
}

resource "google_project_iam_member" "rotate_sm_rw" {
  project = var.project_id
  role    = google_project_iam_custom_role.secret_rotate_rw.id
  member  = "serviceAccount:${google_service_account.rotate.email}"

  dynamic "condition" {
    for_each = local.prefix_condition
    content {
      title       = "envector-kms-namespace"
      description = "Fence to the ${local.secret_name_prefix} secret namespace."
      expression  = local.secret_prefix_expr
    }
  }
}

# --- key-info (key-inventory): payload read (fenced) + list (unconditioned) ---
# secretAccessor (versions.access) is fenceable and prefix-conditioned below; the
# list-only custom role (secrets.list) authorizes against the project parent so it
# cannot carry the prefix condition (see secret_list above).
resource "google_project_iam_member" "key_info_sm_access" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.key_info.email}"

  dynamic "condition" {
    for_each = local.prefix_condition
    content {
      title       = "envector-kms-namespace"
      description = "Fence to the ${local.secret_name_prefix} secret namespace."
      expression  = local.secret_prefix_expr
    }
  }
}

resource "google_project_iam_member" "key_info_sm_list" {
  project = var.project_id
  role    = google_project_iam_custom_role.secret_list.id
  member  = "serviceAccount:${google_service_account.key_info.email}"
}

# --- score-decryptor: payload read only (fenced) ---
resource "google_project_iam_member" "score_decryptor_sm_access" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.score_decryptor.email}"

  dynamic "condition" {
    for_each = local.prefix_condition
    content {
      title       = "envector-kms-namespace"
      description = "Fence to the ${local.secret_name_prefix} secret namespace."
      expression  = local.secret_prefix_expr
    }
  }
}

# --- metadata-cipher: payload read only (fenced) ---
resource "google_project_iam_member" "metadata_cipher_sm_access" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.metadata_cipher.email}"

  dynamic "condition" {
    for_each = local.prefix_condition
    content {
      title       = "envector-kms-namespace"
      description = "Fence to the ${local.secret_name_prefix} secret namespace."
      expression  = local.secret_prefix_expr
    }
  }
}

# ============================================================================
# Artifact Registry — runner SA pulls the kms-tee image (repo-scoped reader)
# ============================================================================
resource "google_artifact_registry_repository_iam_member" "runner_reader" {
  project    = local.ar_project
  location   = var.ar_location
  repository = var.ar_repository
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${var.runner_sa_email}"
}

# ============================================================================
# State migration — per-role rename wave (metadata -> key_info, score_decrypt ->
# score_decryptor). These moved blocks remap Terraform state from the pre-rename
# ADDRESSES; without them a bare rename would drop the old-addressed SAs and their
# IAM bindings and re-add them at the new address, causing a destroy+recreate.
#
# The address remap alone is NOT sufficient for an in-place migration: the rename
# also changed the SA account_id defaults (ek-metadata -> ek-key-info,
# ek-score-decrypt -> ek-score-decryptor), and account_id is ForceNew on
# google_service_account. An existing deployment that took the old defaults must
# ALSO pin the old account_ids in tfvars (key_info_sa_account_id = "ek-metadata",
# score_decryptor_sa_account_id = "ek-score-decrypt"), or the plan still replaces
# the SAs — and every IAM grant that references their emails — despite the move.
# See the "Upgrade note" in README.md.
#
# No-op for a fresh deployment and for the current fleet (no live state at the old
# addresses; all applies to date were test-scoped and torn down). Mirrors the
# moved block in gcp/kms-wif for the provider for_each refactor.
# ============================================================================
moved {
  from = google_service_account.metadata
  to   = google_service_account.key_info
}

moved {
  from = google_service_account.score_decrypt
  to   = google_service_account.score_decryptor
}

moved {
  from = google_kms_crypto_key_iam_member.score_decrypt_decrypt
  to   = google_kms_crypto_key_iam_member.score_decryptor_decrypt
}

moved {
  from = google_project_iam_member.metadata_sm_access
  to   = google_project_iam_member.key_info_sm_access
}

moved {
  from = google_project_iam_member.metadata_sm_list
  to   = google_project_iam_member.key_info_sm_list
}

moved {
  from = google_project_iam_member.score_decrypt_sm_access
  to   = google_project_iam_member.score_decryptor_sm_access
}
