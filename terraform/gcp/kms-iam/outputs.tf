# The shape here matches gcp/kms-wif's per_role_sa_emails input object exactly, so
# a root config can wire this module's output straight into kms-wif:
#   per_role_sa_emails = module.kms_iam.per_role_sa_emails
# The dependency is acyclic: kms-iam creates the 5 SAs -> kms-wif's runner SA ->
# kms-iam's runner AR-reader binding (runner_sa_email flows back in as an input).
output "per_role_sa_emails" {
  description = "Emails of the 5 per-role SAs. Feed directly into the gcp/kms-wif module's per_role_sa_emails input (and into the launcher SA_* env). gcp/kms-wif keys its base->per-role tokenCreator for_each by role NAME, so these email values may be provider-computed — they carry the implicit dependency that makes kms-wif bind tokenCreator only after these SAs exist (no root-level depends_on needed)."
  value = {
    keygen          = google_service_account.keygen.email
    rotate          = google_service_account.rotate.email
    key_info        = google_service_account.key_info.email
    score_decryptor = google_service_account.score_decryptor.email
    metadata_cipher = google_service_account.metadata_cipher.email
  }
}

output "cmek_crypto_key_id" {
  description = "Full resource id of the sk CMEK crypto key (wraps the sk DEK; existence-validated at plan time)."
  value       = data.google_kms_crypto_key.cmek.id
}

output "metadata_cmek_crypto_key_id" {
  description = "Full resource id of the CMEK the metadata DEK is wrapped under: the dedicated metadata key when the per-type split is enabled, else the sk CMEK."
  value       = local.metadata_cmek_id
}

output "custom_role_ids" {
  description = "The custom role ids created for least-privilege KMS/SM access (for audit / cross-reference)."
  value = {
    kek_rotate       = google_project_iam_custom_role.kek_rotate.id
    key_get          = google_project_iam_custom_role.key_get.id
    secret_create    = google_project_iam_custom_role.secret_create.id
    secret_keygen_rw = google_project_iam_custom_role.secret_keygen_rw.id
    secret_rotate_rw = google_project_iam_custom_role.secret_rotate_rw.id
    secret_list      = google_project_iam_custom_role.secret_list.id
  }
}
