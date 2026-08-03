#!/usr/bin/env bash
# Launch kms-tee as a Confidential Space workload (a hardened SEV/TDX Confidential
# VM). This is the attested runtime whose Google-signed attestation token federates
# — via the Workload Identity Pool provisioned by terraform/gcp/kms-wif —
# to the attested base SA, which impersonates the 5 per-role SAs. Only the released
# image digest, in this project, on a supported non-debug CS image, can federate.
#
# Prereqs (see README.md):
#  - terraform/gcp/kms-wif applied (pool/provider/base SA + the
#    external_account credential-config, whose digest allowlist includes the image
#    pushed below).
#  - kms-tee image pushed to Artifact Registry (CS reads tee-image-reference from AR).
#  - The CVM's attached service account = the MINIMAL runner SA (kms-wif output
#    runner_sa_email), NOT the base SA — see RUNNER_SA_EMAIL below. It needs
#    artifactregistry.reader + confidentialcomputing.workloadUser + logging.logWriter,
#    and the operator running this script needs roles/iam.serviceAccountUser on it
#    to attach it.
#  - Confidential Space delivers the attestation token at
#    /run/container_launcher/attestation_verifier_claims_token; the kms-tee image
#    writes the external_account cred-config referencing that path and points
#    GOOGLE_APPLICATION_CREDENTIALS at it (or it is baked in — see README).
set -euo pipefail

: "${PROJECT_ID:?set PROJECT_ID}"
: "${ZONE:?set ZONE e.g. asia-northeast3-a}"
: "${TEE_IMAGE:?set TEE_IMAGE e.g. asia-northeast3-docker.pkg.dev/my-gcp-project/es2-images/envector-kms-tee@sha256:...}"
# The CVM attaches a MINIMAL runner SA (AR reader + workloadUser + logWriter, no
# tokenCreator) — NOT the base SA. Attaching the base SA would let a tampered image
# read it from the metadata server and bypass attestation; see "Security invariants"
# in terraform/gcp/kms-wif/README.md for the full rationale.
: "${RUNNER_SA_EMAIL:?set RUNNER_SA_EMAIL (minimal CVM runner SA: AR reader + workloadUser + logWriter; NOT the base SA)}"
# The expected attested base SA (kms-wif output base_sa_email). Passed to the
# workload (and pinned in the attestation) so kms-tee rejects a cred-config that
# impersonates any OTHER base SA (e.g. a stale one from a different same-project pool).
: "${BASE_SA_EMAIL:?set BASE_SA_EMAIL (kms-wif output base_sa_email)}"
INSTANCE="${INSTANCE:-envector-kms-tee-cs}"
# Machine family, confidential-compute type and maintenance policy MUST agree, so
# derive the latter two from the machine family (a single knob = MACHINE_TYPE):
# n2d -> SEV + MIGRATE (SEV can live-migrate); c3 -> TDX + TERMINATE (TDX cannot).
# Just set MACHINE_TYPE=c3-standard-* for TDX; the rest follows. Explicit overrides
# are allowed but validated against the family so an inconsistent trio is rejected
# up front (instead of by gcloud after the fact).
MACHINE_TYPE="${MACHINE_TYPE:-n2d-standard-2}"
# Intentionally a conservative allowlist: only the two Confidential VM families we
# have validated (n2d=SEV, c3=TDX). A new family must be added here explicitly with
# its correct compute-type + maintenance policy, rather than silently accepted.
case "$MACHINE_TYPE" in
  n2d-*) _CCT=SEV; _MP=MIGRATE ;;
  c3-*)  _CCT=TDX; _MP=TERMINATE ;;
  *) echo "unsupported MACHINE_TYPE '$MACHINE_TYPE' (expected an n2d-* [SEV] or c3-* [TDX] family)" >&2; exit 1 ;;
esac
CONFIDENTIAL_COMPUTE_TYPE="${CONFIDENTIAL_COMPUTE_TYPE:-$_CCT}"
MAINTENANCE_POLICY="${MAINTENANCE_POLICY:-$_MP}"
if [ "$CONFIDENTIAL_COMPUTE_TYPE" != "$_CCT" ]; then
  echo "MACHINE_TYPE '$MACHINE_TYPE' implies CONFIDENTIAL_COMPUTE_TYPE=$_CCT, not '$CONFIDENTIAL_COMPUTE_TYPE'" >&2
  exit 1
fi
# Networking. REQUIRE an explicit VPC + subnet so the CVM is never placed in the
# default VPC by accident: the kms-tee gRPC listener (:50062) is PLAINTEXT, and the
# default VPC's default-allow-internal rule opens tcp:0-65535 to every VM in the
# network — exposing the TEE port VPC-wide. The operator MUST add a firewall rule so
# only envector-kms may reach :50062; the README's recipe targets THIS CVM by its runner
# SA (--target-service-accounts) paired with --source-service-accounts, because GCP
# rejects mixing --target-tags with --source-service-accounts. NETWORK_TAG is still
# applied below for an alternative tag-based rule. NO_EXTERNAL_IP=true drops the public
# IP (egress then needs Cloud NAT / Private Google Access).
: "${NETWORK:?set NETWORK (VPC — do not rely on the default VPC for a plaintext TEE port)}"
: "${SUBNET:?set SUBNET (a subnet in the region of $ZONE)}"
NETWORK_TAG="${NETWORK_TAG:-envector-kms-tee}"
NET_ARGS=(--network="$NETWORK" --subnet="$SUBNET" --tags="$NETWORK_TAG")
[ "${NO_EXTERNAL_IP:-}" = "true" ] && NET_ARGS+=(--no-address)
# Label the CVM as a kms-tee workload so the deprecation-safety fleet filter
# (`labels.workload=kms-tee AND status=RUNNING`, see the digest-rollout runbook)
# actually selects it. WITHOUT this label that filter matches ZERO instances, and
# check-digest-in-use.sh --assert-absent would treat the empty result as an empty
# live set — falsely reporting an in-use digest as "safe to deprecate". Keep the
# label value in sync with the runbook's documented FILTER (and with NETWORK_TAG).
INSTANCE_LABELS="${INSTANCE_LABELS:-workload=kms-tee}"
CS_IMAGE_FAMILY="${CS_IMAGE_FAMILY:-confidential-space}"  # or confidential-space-debug
GCP_PROJECT="${ENVECTOR_KMS_GCP_PROJECT:-$PROJECT_ID}"
# The keyring MUST be in the global location — the kms-tee backend pins the Cloud
# KMS location to "global" with no override, so a regional keyring fails the first
# seal with NOT_FOUND (see kms-wif Security invariants).
KMS_KEYRING="${ENVECTOR_KMS_GCP_KMS_KEYRING:?set ENVECTOR_KMS_GCP_KMS_KEYRING (must be a global-location keyring)}"
KMS_KEY="${ENVECTOR_KMS_GCP_KMS_KEY:?set ENVECTOR_KMS_GCP_KMS_KEY}"
# Optional dedicated metadata CMEK (per-type CMEK split; same keyring as KMS_KEY).
# When set, kms-wif pins it in the attestation condition, so it must be emitted as
# an attested tee-env below. When unset the metadata DEK falls back to KMS_KEY.
KMS_KEY_METADATA="${ENVECTOR_KMS_GCP_KMS_KEY_METADATA:-}"
# Secret Manager namespace. Always emitted (defaults to envector-kms) because the
# kms-wif attestation condition PINS ENVECTOR_KMS_GCP_SECRET_PREFIX — it must be
# present in the attested env and match the module's secret_prefix var.
SECRET_PREFIX="${ENVECTOR_KMS_GCP_SECRET_PREFIX:-envector-kms}"

# Per-role SA emails the attested base impersonates (must match the kms-wif module).
: "${SA_KEYGEN:?}" "${SA_ROTATE:?}" "${SA_KEY_INFO:?}" "${SA_SCORE_DECRYPTOR:?}" "${SA_METADATA_CIPHER:?}"

# The WIF external_account credential config (kms-wif output
# external_account_credential_config) as a FILE. Delivered via metadata-from-file
# rather than inline metadata because the JSON contains quotes/slashes that would
# break the inline ^~^ metadata quoting. The entrypoint reads
# ENVECTOR_KMS_GCP_WIF_CREDCONFIG, writes it to a file, and points
# GOOGLE_APPLICATION_CREDENTIALS at it — so the CVM federates with NO static key.
: "${WIF_CREDCONFIG_FILE:?set WIF_CREDCONFIG_FILE (path to the kms-wif external_account cred-config json)}"
[ -f "$WIF_CREDCONFIG_FILE" ] || { echo "WIF_CREDCONFIG_FILE not found: $WIF_CREDCONFIG_FILE" >&2; exit 1; }

# The exact WIF provider audience (kms-wif output provider_audience). Required in the
# attested path: the pool grants workloadIdentityUser pool-wide, so pinning the provider
# audience is what stops the base ADC federating through another (weaker-condition)
# provider in the same pool.
: "${WIF_AUDIENCE:?set WIF_AUDIENCE (kms-wif output provider_audience)}"

# tee-env-* injects container env (each name must be in the image's allow_env_override
# launch policy). Multiple metadata values are delimited with ^~^. tee-restart-policy
# defaults to Never in Confidential Space; a long-running service wants Always so the
# workload container is restarted if it exits/OOMs without recreating the CVM.
METADATA="^~^tee-image-reference=${TEE_IMAGE}"
METADATA+="~tee-restart-policy=Always"
METADATA+="~tee-container-log-redirect=true"
METADATA+="~tee-env-ENVECTOR_KMS_SECRET_BACKEND=gcp"
METADATA+="~tee-env-ENVECTOR_KMS_GCP_PROJECT=${GCP_PROJECT}"
METADATA+="~tee-env-ENVECTOR_KMS_GCP_BASE_SA=${BASE_SA_EMAIL}"
METADATA+="~tee-env-ENVECTOR_KMS_GCP_KMS_KEYRING=${KMS_KEYRING}"
METADATA+="~tee-env-ENVECTOR_KMS_GCP_KMS_KEY=${KMS_KEY}"
# Always emit (empty when unset) so the attestation token carries this env and
# kms-wif can pin its EXACT value. If it were emitted only when set, a single-CMEK
# deployment could still launch the allowlisted image with an injected metadata
# CMEK (the env is allowlisted for override) and attest, silently enabling the
# split under an unpinned key.
METADATA+="~tee-env-ENVECTOR_KMS_GCP_KMS_KEY_METADATA=${KMS_KEY_METADATA}"
METADATA+="~tee-env-ENVECTOR_KMS_GCP_REQUIRE_ATTESTED_BASE=true"
METADATA+="~tee-env-ENVECTOR_KMS_GCP_WIF_AUDIENCE=${WIF_AUDIENCE}"
METADATA+="~tee-env-ENVECTOR_KMS_GCP_SA_KEYGEN=${SA_KEYGEN}"
METADATA+="~tee-env-ENVECTOR_KMS_GCP_SA_ROTATE=${SA_ROTATE}"
METADATA+="~tee-env-ENVECTOR_KMS_GCP_SA_KEY_INFO=${SA_KEY_INFO}"
METADATA+="~tee-env-ENVECTOR_KMS_GCP_SA_SCORE_DECRYPTOR=${SA_SCORE_DECRYPTOR}"
METADATA+="~tee-env-ENVECTOR_KMS_GCP_SA_METADATA_CIPHER=${SA_METADATA_CIPHER}"
METADATA+="~tee-env-ENVECTOR_KMS_GCP_SECRET_PREFIX=${SECRET_PREFIX}"

gcloud compute instances create "$INSTANCE" \
  --project="$PROJECT_ID" --zone="$ZONE" \
  --machine-type="$MACHINE_TYPE" \
  --confidential-compute-type="$CONFIDENTIAL_COMPUTE_TYPE" \
  --maintenance-policy="$MAINTENANCE_POLICY" \
  --shielded-secure-boot \
  --image-project=confidential-space-images \
  --image-family="$CS_IMAGE_FAMILY" \
  --service-account="$RUNNER_SA_EMAIL" \
  --scopes=cloud-platform \
  --labels="$INSTANCE_LABELS" \
  "${NET_ARGS[@]}" \
  --metadata-from-file="tee-env-ENVECTOR_KMS_GCP_WIF_CREDCONFIG=${WIF_CREDCONFIG_FILE}" \
  --metadata="$METADATA"

echo "launched $INSTANCE. Attestation gating: the base SA is obtained ONLY if the"
echo "running image digest is in the kms-wif provider allowlist (this project,"
echo "Confidential Space, STABLE, non-debug). Check serial console / cloud logging"
echo "for the 5 'impersonate_sa' init lines to confirm per-role federation."
