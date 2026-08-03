// Applies gcp/kms-iam and gcp/kms-wif in a single pass.
//
// Wiring the two as real references is what lets Terraform order the resources itself:
// kms-iam's five per-role SAs come before kms-wif's tokenCreator bindings on them, and
// kms-wif's runner SA comes before kms-iam's Artifact Registry reader binding. The
// dependencies run in opposite directions but land on different resources, so the graph is
// a DAG. A module-wide depends_on would collapse that into a cycle — do not add one.
//
// Applying the modules separately still works; it just costs an extra pass, because
// kms-iam's AR binding has to sit out the first apply (see gcp/kms-iam/README.md).

terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
}

variable "project_id" {
  type        = string
  description = "GCP project holding the CMEK, the SAs, and the WIF pool."
}

// --- shared by both modules; the values MUST match what the CVM launcher pins ---------
variable "kms_keyring" {
  type        = string
  description = "Existing CMEK keyring NAME, location=global."
}

variable "kms_key" {
  type        = string
  description = "Existing CMEK key NAME that wraps the per-key DEK."
}

variable "kms_key_metadata" {
  type        = string
  default     = null
  description = "Optional dedicated metadata CMEK in the same keyring (per-type split)."
}

variable "secret_prefix" {
  type        = string
  default     = "envector-kms"
  description = "Secret Manager name prefix for the KeyStore envelopes."
}

// --- kms-iam ---------------------------------------------------------------------------
variable "keygen_sa_account_id" {
  type    = string
  default = "ek-keygen"
}

variable "rotate_sa_account_id" {
  type    = string
  default = "ek-rotate"
}

variable "key_info_sa_account_id" {
  type    = string
  default = "ek-key-info"
}

variable "score_decryptor_sa_account_id" {
  type    = string
  default = "ek-score-decryptor"
}

variable "metadata_cipher_sa_account_id" {
  type    = string
  default = "ek-meta-cipher"
}

variable "ar_project_id" {
  type        = string
  default     = null
  description = "Project holding the image repo, when it is not project_id."
}

variable "ar_location" {
  type    = string
  default = "asia-northeast3"
}

variable "ar_repository" {
  type    = string
  default = "es2-images"
}

variable "custom_role_id_suffix" {
  type        = string
  default     = ""
  description = "Suffix for the custom role ids, so a re-run does not collide with the 7-day soft-deleted ones."
}

// --- kms-wif ---------------------------------------------------------------------------
variable "pool_id" {
  type    = string
  default = "envector-kms-tee-base"
}

variable "provider_id" {
  type    = string
  default = "confidential-space"
}

variable "base_sa_account_id" {
  type    = string
  default = "envector-kms-tee-attested"
}

variable "runner_sa_account_id" {
  type    = string
  default = "envector-kms-tee-runner"
}

variable "manifest_path" {
  type        = string
  default     = null
  description = "Released-digest manifest the allowlist is derived from. null reads the in-repo manifest."
}

variable "include_deprecated" {
  type        = bool
  default     = false
  description = "Keep deprecated digests in the allowlist, for a fleet still running them."
}

module "kms_iam" {
  source = "../kms-iam"

  project_id       = var.project_id
  kms_keyring      = var.kms_keyring
  kms_key          = var.kms_key
  kms_key_metadata = var.kms_key_metadata
  secret_prefix    = var.secret_prefix

  keygen_sa_account_id          = var.keygen_sa_account_id
  rotate_sa_account_id          = var.rotate_sa_account_id
  key_info_sa_account_id        = var.key_info_sa_account_id
  score_decryptor_sa_account_id = var.score_decryptor_sa_account_id
  metadata_cipher_sa_account_id = var.metadata_cipher_sa_account_id

  ar_project_id         = var.ar_project_id
  ar_location           = var.ar_location
  ar_repository         = var.ar_repository
  custom_role_id_suffix = var.custom_role_id_suffix

  runner_sa_email = module.kms_wif.runner_sa_email
}

module "kms_wif" {
  source = "../kms-wif"

  project_id       = var.project_id
  kms_keyring      = var.kms_keyring
  kms_key          = var.kms_key
  kms_key_metadata = var.kms_key_metadata
  secret_prefix    = var.secret_prefix

  pool_id              = var.pool_id
  provider_id          = var.provider_id
  base_sa_account_id   = var.base_sa_account_id
  runner_sa_account_id = var.runner_sa_account_id
  manifest_path        = var.manifest_path
  include_deprecated   = var.include_deprecated

  per_role_sa_emails = module.kms_iam.per_role_sa_emails
}

output "per_role_sa_emails" {
  description = "The 5 per-role SA emails; the CVM launcher pins these as SA_* env."
  value       = module.kms_iam.per_role_sa_emails
}

output "base_sa_email" {
  description = "Attested base SA. Launcher BASE_SA_EMAIL — never attach it to the CVM."
  value       = module.kms_wif.base_sa_email
}

output "runner_sa_email" {
  description = "Minimal SA to attach to the CVM. Launcher RUNNER_SA_EMAIL."
  value       = module.kms_wif.runner_sa_email
}

output "provider_audience" {
  description = "Launcher WIF_AUDIENCE; the attestation condition binds this same string."
  value       = module.kms_wif.provider_audience
}

output "attribute_condition" {
  description = "The rendered attestation condition, for review and drift detection."
  value       = module.kms_wif.attribute_condition
}

output "external_account_credential_config" {
  description = "external_account ADC JSON. Read with -raw and use it unmodified."
  value       = module.kms_wif.external_account_credential_config
}
