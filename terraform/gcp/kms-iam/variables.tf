variable "project_id" {
  type        = string
  description = "GCP project that owns the 5 per-role service accounts, the custom roles, and (by reference) the CMEK + Secret Manager namespace."
}

# --- Per-role service account local parts -----------------------------------
# The 5 roles the attested base SA impersonates (see gcp/kms-wif). Each gets ONLY
# its own least-privilege Cloud KMS / Secret Manager IAM here. Defaults match the
# gcp/kms-wif README example so per_role_sa_emails wires straight through.
variable "keygen_sa_account_id" {
  type        = string
  default     = "ek-keygen"
  description = "Account id (local part) of the keygen per-role SA."
}

variable "rotate_sa_account_id" {
  type        = string
  default     = "ek-rotate"
  description = "Account id (local part) of the rotate per-role SA."
}

variable "key_info_sa_account_id" {
  type        = string
  default     = "ek-key-info"
  description = "Account id (local part) of the key-info (key-inventory) per-role SA."
}

variable "score_decryptor_sa_account_id" {
  type        = string
  default     = "ek-score-decryptor"
  description = "Account id (local part) of the score-decryptor per-role SA."
}

variable "metadata_cipher_sa_account_id" {
  type        = string
  default     = "ek-meta-cipher"
  description = "Account id (local part) of the metadata-cipher per-role SA."
}

# --- CMEK (customer-managed; REFERENCED, never created) ---------------------
# The keyring/key are provisioned by the customer (or a separate slice). This
# module only reads them (via data sources, which fail if absent -> existence
# validation) and grants per-role IAM on the crypto key.
variable "kms_location" {
  type        = string
  default     = "global"
  description = "Cloud KMS location of the CMEK keyring. MUST be 'global': the kms-tee backend pins the KMS location to 'global' with no override, so a regional keyring fails the first seal with NOT_FOUND."

  validation {
    condition     = var.kms_location == "global"
    error_message = "kms_location must be 'global' (the kms-tee backend hard-pins the Cloud KMS location to global)."
  }
}

variable "kms_keyring" {
  type        = string
  description = "Name of the existing (customer-managed) Cloud KMS keyring holding the CMEK. Referenced, not created."
}

variable "kms_key" {
  type        = string
  description = "Name of the existing (customer-managed) CMEK crypto key that wraps the sk DEK. Referenced, not created; per-role KMS IAM is granted on this key resource."
}

variable "kms_key_metadata" {
  type        = string
  default     = null
  description = <<-EOT
    Optional dedicated metadata CMEK crypto key, in the SAME keyring as kms_key.
    When set, the per-type CMEK split is enabled: the metadata DEK is wrapped under
    this key, so metadata-cipher gets Decrypt on THIS key only (never kms_key) and
    keygen/rotate additionally get their seal/rotate grants on it. This is what
    stops a compromised metadata-cipher SA from unwrapping sk after reading
    SecKey.json. When null/empty, the metadata DEK falls back to kms_key
    (single-CMEK). MUST equal the runtime ENVECTOR_KMS_GCP_KMS_KEY_METADATA and the
    value pinned by gcp/kms-wif.
  EOT

  validation {
    condition     = var.kms_key_metadata == null || var.kms_key_metadata == "" || can(regex("^[A-Za-z0-9_-]+$", var.kms_key_metadata))
    error_message = "kms_key_metadata must be letters, digits, underscores, and hyphens (or null/empty to disable the split)."
  }
}

# --- Secret Manager namespace ------------------------------------------------
variable "secret_prefix" {
  type        = string
  default     = "envector-kms"
  description = "Secret Manager key-prefix (namespace). MUST equal the gcp/kms-wif secret_prefix and the launcher ENVECTOR_KMS_GCP_SECRET_PREFIX (kms-wif pins it in the attestation condition). Secret ids this instance creates all begin '<secret_prefix>--'."

  # Stricter than kms-wif's charset: this module interpolates secret_prefix into
  # both an IAM Condition CEL string and the '<prefix>--' resource.name match, so
  # it must equal the runtime-normalized prefix. The backend does
  # strings.Trim(prefix, "/-") and, crucially, secret ids ESCAPE '/' -> '--' and
  # '.' -> '__' (toSecretID) and reverse them on read (fromSecretID). So the
  # literal tokens '--' and '__' inside a prefix are ambiguous: they round-trip to
  # '/' and '.', so inventory/listing would decode secrets under a different prefix
  # and drop them. Disallow those tokens (and leading/trailing separators, '.',
  # '/', quotes, spaces): alphanumerics separated by SINGLE '-' or '_'.
  validation {
    condition     = can(regex("^[A-Za-z0-9]+([-_][A-Za-z0-9]+)*$", var.secret_prefix))
    error_message = "secret_prefix must be alphanumerics separated by single '-' or '_' (no leading/trailing separator, no '--'/'__' escape tokens, no '.', '/', quotes, or spaces) so both the IAM Condition prefix and the round-tripped secret ids match the runtime."
  }
}

variable "enable_secret_prefix_condition" {
  type        = bool
  default     = true
  description = <<-EOT
    Fence the fenceable Secret Manager grants to the '<secret_prefix>--' namespace
    with an IAM Condition (resource.name.startsWith). Applies to the payload-read
    (secretAccessor) grants and the version-level write grants, so a compromised
    per-role SA cannot read/write OTHER secrets in the project (e.g. unrelated
    tokens). It CANNOT cover secretmanager.secrets.create / secrets.list: both
    authorize against the project parent (the secret name does not exist yet / a
    list is a collection op), so those two permissions are isolated into their own
    project-level roles. The namespace is additionally pinned by the kms-wif
    attestation condition (ENVECTOR_KMS_GCP_SECRET_PREFIX), which backstops the two
    unconditionable permissions.
  EOT
}

# --- Runner SA (AR reader) ---------------------------------------------------
variable "runner_sa_email" {
  type        = string
  description = "The minimal Confidential Space CVM runner SA (gcp/kms-wif output runner_sa_email). This module grants it artifactregistry.reader on the kms-tee image repo (repo-scoped). It holds NO key access."
}

variable "ar_project_id" {
  type        = string
  default     = null
  description = "Project of the Artifact Registry repo the runner SA pulls the kms-tee image from. Defaults to project_id."
}

variable "ar_location" {
  type        = string
  default     = "asia-northeast3"
  description = "Location of the Artifact Registry repo holding the kms-tee image."
}

variable "ar_repository" {
  type        = string
  default     = "es2-images"
  description = "Artifact Registry repository id holding the kms-tee image; the runner SA gets artifactregistry.reader on it."
}

# --- Custom-role id suffix (soft-delete avoidance during apply-validate) ------
variable "custom_role_id_suffix" {
  type        = string
  default     = ""
  description = "Optional suffix appended to every custom role id. Deleted custom roles are soft-deleted for 7 days and cannot be recreated with the same id in that window; set a unique suffix (e.g. a date tag) for throwaway apply-validate runs so they never collide with the production role ids. Must match [A-Za-z0-9_.]."

  validation {
    condition     = can(regex("^[A-Za-z0-9_.]*$", var.custom_role_id_suffix))
    error_message = "custom_role_id_suffix may contain only letters, digits, underscore and dot (custom role id charset)."
  }
}
