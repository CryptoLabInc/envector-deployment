#!/bin/sh
set -eu

CERTS_DIR="${CERTS_DIR:-./certs}"
CA_DIR="${CERTS_DIR}/ca"

# Backend-neutral secret-manager server cert. ONE cert serves whichever
# Vault-protocol backend runs in the kms-secret-manager service (HashiCorp Vault
# by default, OpenBao when the bao overlay swaps only the image). The slot path
# and filenames are neutral (/certs/secret-manager/tls.{crt,key}); SAN/CN come
# from SM_TLS_* so a profile can point the cert at its own hostname.
SM_DIR="${CERTS_DIR}/secret-manager"
SM_IP="${SM_TLS_IP:-127.0.0.1}"
SM_DNS="${SM_TLS_DNS:-kms-secret-manager,localhost}"
SM_CN="${SM_TLS_CN:-}"

KMS_TEE_DIR="${CERTS_DIR}/kms-tee"
KMS_TEE_IP="${KMS_TEE_TLS_IP:-}"
KMS_TEE_DNS="${KMS_TEE_TLS_DNS:-envector-kms-tee}"
KMS_TEE_CN="${KMS_TEE_TLS_CN:-}"

KMS_API_DIR="${CERTS_DIR}/kms-api"
KMS_API_DNS="${KMS_API_TLS_DNS:-envector-kms,localhost}"
KMS_API_IP="${KMS_API_TLS_IP:-127.0.0.1}"
KMS_API_CN="${KMS_API_TLS_CN:-}"

STEP_CA_URL="${STEP_CA_URL:-https://step-ca:9000}"
STEP_CA_PROVISIONER="${STEP_CA_PROVISIONER:-envector-workloads}"
STEP_CA_PASSWORD_FILE="${STEP_CA_PASSWORD_FILE:-/step-secrets/step_ca_password}"
CERT_NOT_AFTER="${CERT_NOT_AFTER:-8760h}"
STEPPATH="${STEPPATH:-/tmp/step}"
export STEPPATH

log() { echo "[cert-init] $*"; }

mkdir -p "${CA_DIR}" "${SM_DIR}" "${KMS_TEE_DIR}" "${KMS_API_DIR}"

if [ ! -s "${STEP_CA_PASSWORD_FILE}" ]; then
  log "missing step-ca provisioner password file: ${STEP_CA_PASSWORD_FILE}"
  exit 1
fi

for _ in $(seq 1 60); do
  [ -s "${CA_DIR}/root_ca.crt" ] && break
  log "waiting for root CA at ${CA_DIR}/root_ca.crt"
  sleep 1
done
[ -s "${CA_DIR}/root_ca.crt" ] || {
  log "root CA not found: ${CA_DIR}/root_ca.crt"
  exit 1
}

sanitize_csv() {
  printf '%s' "$1" | tr -d ' '
}

first_csv_value() {
  csv="$(sanitize_csv "$1")"
  old_ifs="${IFS}"
  IFS=','
  for value in ${csv}; do
    if [ -n "${value}" ]; then
      printf '%s' "${value}"
      IFS="${old_ifs}"
      return
    fi
  done
  IFS="${old_ifs}"
}

subject_from_san() {
  dns_subject="$(first_csv_value "$1")"
  if [ -n "${dns_subject}" ]; then
    printf '%s' "${dns_subject}"
    return
  fi
  ip_subject="$(first_csv_value "$2")"
  if [ -n "${ip_subject}" ]; then
    printf '%s' "${ip_subject}"
    return
  fi
  printf '%s' "$3"
}

SM_DNS="$(sanitize_csv "${SM_DNS}")"
SM_IP="$(sanitize_csv "${SM_IP}")"
KMS_TEE_DNS="$(sanitize_csv "${KMS_TEE_DNS}")"
KMS_TEE_IP="$(sanitize_csv "${KMS_TEE_IP}")"
KMS_API_DNS="$(sanitize_csv "${KMS_API_DNS}")"
KMS_API_IP="$(sanitize_csv "${KMS_API_IP}")"
SM_CN="${SM_CN:-$(subject_from_san "${SM_DNS}" "${SM_IP}" "kms-secret-manager")}"
KMS_TEE_CN="${KMS_TEE_CN:-$(subject_from_san "${KMS_TEE_DNS}" "${KMS_TEE_IP}" "envector-kms-tee")}"
KMS_API_CN="${KMS_API_CN:-$(subject_from_san "${KMS_API_DNS}" "${KMS_API_IP}" "envector-kms")}"

# cert_profile emits a snapshot of the requested inputs so a rerun can skip
# regeneration when nothing changed.
cert_profile() {
  cat <<EOF
step_ca_url=${STEP_CA_URL}
step_ca_provisioner=${STEP_CA_PROVISIONER}
cert_not_after=${CERT_NOT_AFTER}
sm_cn=${SM_CN}
sm_dns=${SM_DNS}
sm_ip=${SM_IP}
kms_tee_cn=${KMS_TEE_CN}
kms_tee_dns=${KMS_TEE_DNS}
kms_tee_ip=${KMS_TEE_IP}
kms_api_cn=${KMS_API_CN}
kms_api_dns=${KMS_API_DNS}
kms_api_ip=${KMS_API_IP}
EOF
}

cert_profile_matches() {
  cert_profile | cmp -s - "${SM_DIR}/cert.profile" \
    && cert_profile | cmp -s - "${KMS_TEE_DIR}/cert.profile" \
    && cert_profile | cmp -s - "${KMS_API_DIR}/cert.profile"
}

write_cert_profiles() {
  cert_profile > "${SM_DIR}/cert.profile"
  cert_profile > "${KMS_TEE_DIR}/cert.profile"
  cert_profile > "${KMS_API_DIR}/cert.profile"
  chmod 644 "${SM_DIR}/cert.profile" "${KMS_TEE_DIR}/cert.profile" \
    "${KMS_API_DIR}/cert.profile"
}

cert_files_present() {
  [ -f "${SM_DIR}/tls.crt" ] && [ -f "${SM_DIR}/tls.key" ] \
    && [ -f "${KMS_TEE_DIR}/kms-tee.crt" ] && [ -f "${KMS_TEE_DIR}/kms-tee.key" ] \
    && [ -f "${KMS_API_DIR}/kms-api.crt" ] && [ -f "${KMS_API_DIR}/kms-api.key" ]
}

certs_match_current_ca() {
  step certificate verify "${SM_DIR}/tls.crt" --roots "${CA_DIR}/root_ca.crt" >/dev/null 2>&1 \
    && step certificate verify "${KMS_TEE_DIR}/kms-tee.crt" --roots "${CA_DIR}/root_ca.crt" >/dev/null 2>&1 \
    && step certificate verify "${KMS_API_DIR}/kms-api.crt" --roots "${CA_DIR}/root_ca.crt" >/dev/null 2>&1
}

# Skip only if existing certs were issued by the current root CA and the
# certificate input profile still matches the requested SAN/CN/duration values.
if cert_files_present; then
  if certs_match_current_ca && cert_profile_matches; then
    log "certs already present for current CA and profile, skipping generation"
    exit 0
  fi
  log "existing certs do not match current CA/profile, regenerating"
fi

FINGERPRINT="$(step certificate fingerprint "${CA_DIR}/root_ca.crt")"
log "bootstrapping step client"
step ca bootstrap \
  --ca-url "${STEP_CA_URL}" \
  --fingerprint "${FINGERPRINT}" \
  --force >/dev/null

issue_cert() {
  subject="$1"
  crt_file="$2"
  key_file="$3"
  dns_csv="$4"
  ip_csv="$5"

  san_args=""
  old_ifs="${IFS}"
  IFS=','
  for dns in ${dns_csv}; do
    [ -n "${dns}" ] || continue
    san_args="${san_args} --san ${dns}"
  done
  for ip in ${ip_csv}; do
    [ -n "${ip}" ] || continue
    san_args="${san_args} --san ${ip}"
  done
  IFS="${old_ifs}"

  # SAN values are controlled compose env values without whitespace.
  # shellcheck disable=SC2086
  step ca certificate "${subject}" "${crt_file}" "${key_file}" \
    --ca-url "${STEP_CA_URL}" \
    --root "${CA_DIR}/root_ca.crt" \
    --provisioner "${STEP_CA_PROVISIONER}" \
    --provisioner-password-file "${STEP_CA_PASSWORD_FILE}" \
    --not-after "${CERT_NOT_AFTER}" \
    --kty RSA \
    --size 2048 \
    --force \
    ${san_args}
}

log "requesting secret-manager server certificate from step-ca"
issue_cert "${SM_CN}" "${SM_DIR}/tls.crt" "${SM_DIR}/tls.key" "${SM_DNS}" "${SM_IP}"

log "requesting KMS/TEE client certificate from step-ca"
issue_cert "${KMS_TEE_CN}" "${KMS_TEE_DIR}/kms-tee.crt" "${KMS_TEE_DIR}/kms-tee.key" "${KMS_TEE_DNS}" "${KMS_TEE_IP}"

log "requesting KMS API server certificate from step-ca"
issue_cert "${KMS_API_CN}" "${KMS_API_DIR}/kms-api.crt" "${KMS_API_DIR}/kms-api.key" "${KMS_API_DNS}" "${KMS_API_IP}"

# Runtime containers may run as non-root users. The private keys are isolated by
# per-consumer compose volumes, so make each mounted key readable in its own
# container while still keeping server/client keys separated across services.
chmod 644 "${SM_DIR}/tls.key" "${KMS_TEE_DIR}/kms-tee.key" "${KMS_API_DIR}/kms-api.key"
chmod 644 "${SM_DIR}/tls.crt" "${KMS_TEE_DIR}/kms-tee.crt" "${KMS_API_DIR}/kms-api.crt"
write_cert_profiles

log "certs written to ${CERTS_DIR}:"
log "  CA:              ${CA_DIR}/root_ca.crt"
log "  Secret manager:  ${SM_DIR}/tls.{crt,key}"
log "  KMS TEE:         ${KMS_TEE_DIR}/kms-tee.{crt,key}"
log "  KMS API:         ${KMS_API_DIR}/kms-api.{crt,key}"
