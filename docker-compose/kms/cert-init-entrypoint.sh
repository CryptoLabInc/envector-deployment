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

# Internal-gRPC (:50062) mutual-TLS pair. CPTEE_SRV_* is the server certificate
# envector-kms-tee presents on the KmsTeeService listener; CPTEE_CLI_* is the
# client certificate envector-kms (control plane) presents. Both verify against
# the same step-ca root — the local realization of the intra-KMS mTLS transport
# (Confidential Space attestation-bound issuance is a separate path).
CPTEE_SRV_DIR="${CERTS_DIR}/cp-tee-srv"
CPTEE_SRV_DNS="${CPTEE_SRV_TLS_DNS:-cptee-server}"
CPTEE_SRV_IP="${CPTEE_SRV_TLS_IP:-}"
CPTEE_SRV_CN="${CPTEE_SRV_TLS_CN:-}"

CPTEE_CLI_DIR="${CERTS_DIR}/cp-tee-cli"
CPTEE_CLI_DNS="${CPTEE_CLI_TLS_DNS:-cptee-client}"
CPTEE_CLI_IP="${CPTEE_CLI_TLS_IP:-}"
CPTEE_CLI_CN="${CPTEE_CLI_TLS_CN:-}"

STEP_CA_URL="${STEP_CA_URL:-https://step-ca:9000}"
STEP_CA_PROVISIONER="${STEP_CA_PROVISIONER:-envector-workloads}"
STEP_CA_PASSWORD_FILE="${STEP_CA_PASSWORD_FILE:-/step-secrets/step_ca_password}"
CERT_NOT_AFTER="${CERT_NOT_AFTER:-8760h}"
STEPPATH="${STEPPATH:-/tmp/step}"
export STEPPATH

log() { echo "[cert-init] $*"; }

mkdir -p "${CA_DIR}" "${SM_DIR}" "${KMS_TEE_DIR}" "${KMS_API_DIR}" \
  "${CPTEE_SRV_DIR}" "${CPTEE_CLI_DIR}"

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
CPTEE_SRV_DNS="$(sanitize_csv "${CPTEE_SRV_DNS}")"
CPTEE_SRV_IP="$(sanitize_csv "${CPTEE_SRV_IP}")"
CPTEE_CLI_DNS="$(sanitize_csv "${CPTEE_CLI_DNS}")"
CPTEE_CLI_IP="$(sanitize_csv "${CPTEE_CLI_IP}")"
SM_CN="${SM_CN:-$(subject_from_san "${SM_DNS}" "${SM_IP}" "kms-secret-manager")}"
KMS_TEE_CN="${KMS_TEE_CN:-$(subject_from_san "${KMS_TEE_DNS}" "${KMS_TEE_IP}" "envector-kms-tee")}"
KMS_API_CN="${KMS_API_CN:-$(subject_from_san "${KMS_API_DNS}" "${KMS_API_IP}" "envector-kms")}"
CPTEE_SRV_CN="${CPTEE_SRV_CN:-$(subject_from_san "${CPTEE_SRV_DNS}" "${CPTEE_SRV_IP}" "cptee-server")}"
CPTEE_CLI_CN="${CPTEE_CLI_CN:-$(subject_from_san "${CPTEE_CLI_DNS}" "${CPTEE_CLI_IP}" "cptee-client")}"

# cert_profile emits a PER-CERT snapshot of the inputs that determine a leaf's
# identity/validity, so a rerun can skip regeneration when nothing about THIS
# cert changed. Scoping the profile to a single cert (cn/dns/ip) means a
# SAN/CN/duration change reissues only the affected cert and never rotates the
# others.
cert_profile() {
  cn="$1"
  dns="$2"
  ip="$3"
  cat <<EOF
step_ca_url=${STEP_CA_URL}
step_ca_provisioner=${STEP_CA_PROVISIONER}
cert_not_after=${CERT_NOT_AFTER}
cn=${cn}
dns=${dns}
ip=${ip}
EOF
}

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

# bootstrap_once runs `step ca bootstrap` at most one time per invocation, and
# only when at least one cert actually needs (re)issuing. A fully-current run
# therefore never contacts the CA.
STEP_BOOTSTRAPPED=0
bootstrap_once() {
  [ "${STEP_BOOTSTRAPPED}" = "1" ] && return 0
  log "bootstrapping step client"
  step ca bootstrap \
    --ca-url "${STEP_CA_URL}" \
    --fingerprint "$(step certificate fingerprint "${CA_DIR}/root_ca.crt")" \
    --force >/dev/null
  STEP_BOOTSTRAPPED=1
}

# ensure_cert keeps an existing cert untouched only when it still verifies
# against the current root CA AND its recorded per-cert profile still matches the
# requested cn/dns/ip/duration; otherwise it (re)issues ONLY this cert. So a
# genuine SAN/CN/duration change reissues just the affected cert, and adding a
# new cert never rotates an existing valid one. This matters for the
# Vault-cert-auth kms-tee leaf: Vault registers its exact certificate, so a
# needless reissue would break cert-login against the persisted Vault until an
# operator re-bootstraps with unseal shares. The leaf is left in place unless
# ITS own inputs or the CA change.
ensure_cert() {
  subject="$1"
  dir="$2"
  crt_file="$3"
  key_file="$4"
  dns_csv="$5"
  ip_csv="$6"

  want="$(cert_profile "${subject}" "${dns_csv}" "${ip_csv}")"
  if [ -f "${crt_file}" ] && [ -f "${key_file}" ] \
    && step certificate verify "${crt_file}" --roots "${CA_DIR}/root_ca.crt" >/dev/null 2>&1; then
    if [ -f "${dir}/cert.profile" ] && printf '%s' "${want}" | cmp -s - "${dir}/cert.profile"; then
      log "keeping existing cert: ${crt_file}"
      return 0
    fi
    # A profile written by the previous (global-format) script does not match the
    # new per-cert format even when this cert's inputs are unchanged. Do NOT
    # rotate a still-valid leaf on that one-time format migration: the Vault
    # cert-auth kms-tee leaf is pinned as the exact PEM, so reissuing it would
    # break cert-login against the persisted Vault until an operator re-bootstraps
    # with unseal shares. Detect a legacy profile by the absence of the new bare
    # "cn=" line, keep the existing cert, and rewrite the profile in the new
    # format. A genuine cn/dns/ip change (new-format profile mismatch) still falls
    # through and reissues only this cert.
    if [ -f "${dir}/cert.profile" ] && ! grep -q '^cn=' "${dir}/cert.profile"; then
      log "migrating legacy cert profile, keeping existing cert: ${crt_file}"
      printf '%s' "${want}" > "${dir}/cert.profile"
      chmod 644 "${dir}/cert.profile"
      return 0
    fi
  fi
  bootstrap_once
  log "issuing certificate from step-ca: ${crt_file}"
  issue_cert "${subject}" "${crt_file}" "${key_file}" "${dns_csv}" "${ip_csv}"
  # Runtime containers may run as non-root users. The private keys are isolated
  # by per-consumer compose volumes, so make each mounted file readable in its
  # own container while still keeping server/client keys separated across
  # services.
  chmod 644 "${crt_file}" "${key_file}"
  printf '%s' "${want}" > "${dir}/cert.profile"
  chmod 644 "${dir}/cert.profile"
}

ensure_cert "${SM_CN}" "${SM_DIR}" "${SM_DIR}/tls.crt" "${SM_DIR}/tls.key" "${SM_DNS}" "${SM_IP}"
ensure_cert "${KMS_TEE_CN}" "${KMS_TEE_DIR}" "${KMS_TEE_DIR}/kms-tee.crt" "${KMS_TEE_DIR}/kms-tee.key" "${KMS_TEE_DNS}" "${KMS_TEE_IP}"
ensure_cert "${KMS_API_CN}" "${KMS_API_DIR}" "${KMS_API_DIR}/kms-api.crt" "${KMS_API_DIR}/kms-api.key" "${KMS_API_DNS}" "${KMS_API_IP}"
ensure_cert "${CPTEE_SRV_CN}" "${CPTEE_SRV_DIR}" "${CPTEE_SRV_DIR}/tls.crt" "${CPTEE_SRV_DIR}/tls.key" "${CPTEE_SRV_DNS}" "${CPTEE_SRV_IP}"
ensure_cert "${CPTEE_CLI_CN}" "${CPTEE_CLI_DIR}" "${CPTEE_CLI_DIR}/tls.crt" "${CPTEE_CLI_DIR}/tls.key" "${CPTEE_CLI_DNS}" "${CPTEE_CLI_IP}"

log "certs written to ${CERTS_DIR}:"
log "  CA:               ${CA_DIR}/root_ca.crt"
log "  Secret manager:   ${SM_DIR}/tls.{crt,key}"
log "  KMS TEE (vault):  ${KMS_TEE_DIR}/kms-tee.{crt,key}"
log "  KMS API:          ${KMS_API_DIR}/kms-api.{crt,key}"
log "  gRPC :50062 srv:  ${CPTEE_SRV_DIR}/tls.{crt,key}"
log "  gRPC :50062 cli:  ${CPTEE_CLI_DIR}/tls.{crt,key}"
