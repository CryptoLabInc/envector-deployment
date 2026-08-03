output "pool_name" {
  value       = google_iam_workload_identity_pool.kms_tee.name
  description = "Full resource name of the Workload Identity Pool."
}

output "provider_name" {
  value       = google_iam_workload_identity_pool_provider.base["confidential_space"].name
  description = "Full resource name of the Confidential Space provider."
}

output "provider_audience" {
  value       = local.wif_audience
  description = "The exact WIF provider audience to pin via ENVECTOR_KMS_GCP_WIF_AUDIENCE. This is the SAME string the attestation condition binds that env to, so the launcher's value matches the attested value."
}

output "base_sa_email" {
  value       = google_service_account.kms_tee_attested.email
  description = "The attested base SA the kms-tee federates to (and which impersonates the 5 per-role SAs). Reached ONLY via the WIF exchange — do NOT attach this SA to the CVM."
}

output "runner_sa_email" {
  value       = google_service_account.kms_tee_runner.email
  description = "The minimal runner SA to attach to the CVM (launch-kms-tee.sh RUNNER_SA_EMAIL). Grant it artifactregistry.reader on the image repo separately."
}

output "attribute_condition" {
  value       = local.attribute_condition
  description = "The effective provider attribute condition (image-digest allowlist + Confidential Space checks)."
}

# The client-side external_account credential config the Confidential Space
# kms-tee uses as GOOGLE_APPLICATION_CREDENTIALS. google auth libraries read the CS
# attestation token and exchange it via this config for the base SA — so the
# container needs NO static key. This is the FINAL, ready-to-use config; the
# gcp-confidential-space deploy consumes it unmodified (do not edit the paths).
output "external_account_credential_config" {
  description = "The external_account ADC json (GOOGLE_APPLICATION_CREDENTIALS) for the CVM. Consume as-is."
  value = jsonencode({
    type                              = "external_account"
    audience                          = "//iam.googleapis.com/${google_iam_workload_identity_pool_provider.base["confidential_space"].name}"
    subject_token_type                = "urn:ietf:params:oauth:token-type:jwt"
    token_url                         = "https://sts.googleapis.com/v1/token"
    service_account_impersonation_url = "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${google_service_account.kms_tee_attested.email}:generateAccessToken"
    credential_source = {
      # Final path: the Confidential Space launcher writes the attestation token
      # to this file inside the CVM; the auth library reads it as the subject token.
      file = local.cs_attestation_token_path
    }
  })
}
