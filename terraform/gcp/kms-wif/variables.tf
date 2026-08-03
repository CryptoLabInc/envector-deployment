variable "project_id" {
  type        = string
  description = "GCP project that owns the Workload Identity Pool, the attested base SA, and the per-role SAs."
}

variable "pool_id" {
  type        = string
  default     = "envector-kms-tee-base"
  description = "Workload Identity Pool id. Dedicated to the attested base SA — do not repurpose this pool for any other workload's identity provider (see the single-strong-provider lifecycle precondition in main.tf)."
  # Interpolated into local.wif_audience, pinned inside a single-quoted CEL literal in
  # attribute_condition; restrict to the id charset so a quote cannot break/weaken it.
  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.pool_id))
    error_message = "pool_id must be lowercase letters, digits, and hyphens."
  }
}

variable "provider_id" {
  type        = string
  default     = "confidential-space"
  description = "Workload Identity Pool provider id (the Confidential Space OIDC trust)."
  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.provider_id))
    error_message = "provider_id must be lowercase letters, digits, and hyphens."
  }
}

variable "base_sa_account_id" {
  type        = string
  default     = "envector-kms-tee-attested"
  description = "Account id (local part) of the attested base service account the pool federates to."
}

variable "runner_sa_account_id" {
  type        = string
  default     = "envector-kms-tee-runner"
  description = "Account id (local part) of the minimal CVM runner SA attached to the Confidential Space VM (AR reader + workloadUser + logWriter; NOT the base SA — attaching the base SA would bypass the attestation gate via the metadata server)."
}

variable "manifest_path" {
  type        = string
  default     = null
  description = <<-EOT
    Path to the released-digest manifest (kms-tee-released-digests.json). Defaults
    (when null) to the in-repo manifest packaged next to this module:
    "$${path.module}/../../../kms-digests/kms-tee-released-digests.json". A
    self-hosted root that consumes kms-wif as a git-sourced module must set this
    to its own synced/vendored manifest -- otherwise the module reads the manifest
    shipped next to the MODULE SOURCE and the deployer's promotions/revocations
    are ignored. The default is null (not a path.module expression, which a
    variable default cannot reference); main.tf coalesces null to the in-repo
    default so the in-repo layout keeps working with no override.
  EOT
}

variable "include_deprecated" {
  type        = bool
  default     = false
  description = <<-EOT
    Whether to admit `deprecated` digests to this provider's derived allowlist, in
    addition to `active`. `revoked` is NEVER admitted regardless of this flag.

    In the shared published manifest, `revoked` is the ONLY global hard-removal:
    it is dropped from every derived allowlist. `deprecated` is a managed-side
    lifecycle marker. A managed derivation leaves this false (active-only), so a
    managed deprecation removes the digest on the next apply. A self-hosted
    deployer whose fleet still runs a deprecated release sets this true so a
    managed deprecation does NOT force-remove a release they still run — only a
    `revoked` status forces its removal. This preserves the guarantee that a
    deployer holding an older release stays admitted until the digest is revoked.
  EOT
}

variable "per_role_sa_emails" {
  type = object({
    keygen          = string
    rotate          = string
    key_info        = string
    score_decryptor = string
    metadata_cipher = string
  })
  description = <<-EOT
    Emails of the 5 per-role service accounts the attested base SA impersonates.
    The base SA is granted roles/iam.serviceAccountTokenCreator on each; each
    per-role SA carries only its own least-privilege Secret Manager / Cloud KMS
    IAM (provisioned separately, not by this module).
  EOT
}

# The two toggles below relax attestation checks ONLY to attest a
# confidential-space-debug image during launcher troubleshooting. Setting either
# false in production is a mistake; the check "attestation_hardening_enabled" block
# in main.tf warns on every plan/apply while relaxed. (The runner-SA pin has no
# legitimate relaxed use and is therefore always enforced, not a variable.)
# Expected storage config the attested workload must use. Pinned in the attestation
# condition (against submods.container.env) so a launch with the allowlisted image +
# runner SA but a different CMEK / namespace is rejected — otherwise, where the
# per-role SAs have project- or keyring-level IAM, a typo'd launch could read/write a
# different key namespace or CMEK while still minting the base SA.
variable "kms_keyring" {
  type        = string
  description = "Expected Cloud KMS keyring (global location) the kms-tee workload must use."
  # Interpolated into a single-quoted CEL literal in attribute_condition; restrict to the
  # KMS resource-id charset so a quote cannot break/weaken the gate.
  validation {
    condition     = can(regex("^[A-Za-z0-9_-]+$", var.kms_keyring))
    error_message = "kms_keyring must be letters, digits, underscores, and hyphens."
  }
}

variable "kms_key" {
  type        = string
  description = "Expected Cloud KMS key (CMEK) that wraps the sk DEK, which the kms-tee workload must use."
  validation {
    condition     = can(regex("^[A-Za-z0-9_-]+$", var.kms_key))
    error_message = "kms_key must be letters, digits, underscores, and hyphens."
  }
}

variable "kms_key_metadata" {
  type        = string
  default     = null
  description = "Optional dedicated metadata CMEK key (per-type CMEK split; same keyring as kms_key). When set, the attestation condition pins ENVECTOR_KMS_GCP_KMS_KEY_METADATA to this exact value, so a launch cannot swap it to the sk key. When null/empty the split is off and the attestation requires that env to be ABSENT or EMPTY — a non-empty value is rejected (an operator cannot inject a metadata CMEK into a single-CMEK deployment), while pre-existing launches that never emit it still federate. MUST match the gcp/kms-iam kms_key_metadata and the runtime ENVECTOR_KMS_GCP_KMS_KEY_METADATA."
  validation {
    condition     = var.kms_key_metadata == null || var.kms_key_metadata == "" || can(regex("^[A-Za-z0-9_-]+$", var.kms_key_metadata))
    error_message = "kms_key_metadata must be letters, digits, underscores, and hyphens (or null/empty to disable pinning)."
  }
}

variable "secret_prefix" {
  type        = string
  default     = "envector-kms"
  description = "Expected Secret Manager key-prefix (namespace). The launcher must set ENVECTOR_KMS_GCP_SECRET_PREFIX to this value; it is pinned in the attestation condition."
  validation {
    condition     = can(regex("^[A-Za-z0-9_-]+$", var.secret_prefix))
    error_message = "secret_prefix must be letters, digits, underscores, and hyphens."
  }
}

variable "require_debug_disabled" {
  type        = bool
  default     = true
  description = "Require the Confidential Space workload to be non-debug (dbgstat == disabled-since-boot). Set false ONLY to attest a debug image for troubleshooting; a warning fires while false. Keep true in production."
}

variable "require_stable_support" {
  type        = bool
  default     = true
  description = "Require the Confidential Space image to carry the STABLE support attribute (a supported production TCB), rejecting EXPERIMENTAL/preview images. Set false ONLY to attest a debug/preview image for troubleshooting; a warning fires while false. Keep true in production."
}

variable "allow_relaxed_attestation" {
  type        = bool
  default     = false
  description = "Escape hatch required to relax require_stable_support/require_debug_disabled. apply is BLOCKED (precondition) if either is false while this is false, so a stray troubleshooting tfvars cannot silently weaken attestation on a production apply; set this true (deliberately) only for debug-image troubleshooting."
}
