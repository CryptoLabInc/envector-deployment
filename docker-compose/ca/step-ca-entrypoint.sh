#!/bin/sh
set -eu

STEP_CA_HOME="${STEP_CA_HOME:-/home/step}"
STEP_CA_NAME="${STEP_CA_NAME:-envector-local-ca}"
STEP_CA_DNS="${STEP_CA_DNS:-step-ca,localhost,127.0.0.1}"
STEP_CA_ADDRESS="${STEP_CA_ADDRESS:-:9000}"
STEP_CA_PROVISIONER="${STEP_CA_PROVISIONER:-envector-workloads}"
STEP_CA_PASSWORD="${STEP_CA_PASSWORD:-}"
STEP_CA_PASSWORD_FILE="${STEP_CA_PASSWORD_FILE:-/step-secrets/step_ca_password}"
STEP_CA_X509_DEFAULT_DUR="${STEP_CA_X509_DEFAULT_DUR:-8760h}"
STEP_CA_X509_MAX_DUR="${STEP_CA_X509_MAX_DUR:-8760h}"
ROOT_CA_OUT="${ROOT_CA_OUT:-/certs/ca/root_ca.crt}"

log() { echo "[step-ca] $*"; }

mkdir -p "$(dirname "${STEP_CA_PASSWORD_FILE}")" "$(dirname "${ROOT_CA_OUT}")"

if [ ! -s "${STEP_CA_PASSWORD_FILE}" ]; then
  if [ -n "${STEP_CA_PASSWORD}" ]; then
    log "creating local provisioner password file from STEP_CA_PASSWORD"
    printf '%s\n' "${STEP_CA_PASSWORD}" > "${STEP_CA_PASSWORD_FILE}"
  else
    log "creating local provisioner password file"
    step crypto rand --format hex 32 > "${STEP_CA_PASSWORD_FILE}"
  fi
  chmod 600 "${STEP_CA_PASSWORD_FILE}"
fi

if [ ! -f "${STEP_CA_HOME}/config/ca.json" ]; then
  log "initializing step-ca"
  step ca init \
    --name "${STEP_CA_NAME}" \
    --dns "${STEP_CA_DNS}" \
    --address "${STEP_CA_ADDRESS}" \
    --provisioner "${STEP_CA_PROVISIONER}" \
    --password-file "${STEP_CA_PASSWORD_FILE}" \
    --provisioner-password-file "${STEP_CA_PASSWORD_FILE}"
  step ca provisioner update "${STEP_CA_PROVISIONER}" \
    --x509-default-dur "${STEP_CA_X509_DEFAULT_DUR}" \
    --x509-max-dur "${STEP_CA_X509_MAX_DUR}" \
    --ca-config "${STEP_CA_HOME}/config/ca.json" >/dev/null
else
  log "existing step-ca config found"
fi

cp "${STEP_CA_HOME}/certs/root_ca.crt" "${ROOT_CA_OUT}"
chmod 644 "${ROOT_CA_OUT}"
log "root CA copied to ${ROOT_CA_OUT}"

exec step-ca "${STEP_CA_HOME}/config/ca.json" --password-file "${STEP_CA_PASSWORD_FILE}"
