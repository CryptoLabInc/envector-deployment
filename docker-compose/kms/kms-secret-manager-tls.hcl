ui = true

# Backend-neutral secret-manager TLS config. ONE HCL drives both Vault-protocol
# backends — HashiCorp Vault (default) and OpenBao — because they speak the same
# server config; the OpenBao profile differs only by container image
# (ENVECTOR_KMS_SM_IMAGE/_BIN), nothing here.
#
# Nothing in this file is vault- or bao-specific: the listener cert/key live at
# the neutral /certs/secret-manager slot (issued by cert-init from SM_TLS_*),
# and storage is the neutral /secret-manager/file path (both images run as root,
# so a root-owned named volume mounted there is writable for either backend).
listener "tcp" {
  address                            = "0.0.0.0:8200"
  tls_cert_file                      = "/certs/secret-manager/tls.crt"
  tls_key_file                       = "/certs/secret-manager/tls.key"
  tls_client_ca_file                 = "/certs/ca/root_ca.crt"
  tls_require_and_verify_client_cert = true
}

# Loopback listener without client-cert requirement, for the container
# healthcheck (`<vault|bao> status -address=https://127.0.0.1:8201`).
listener "tcp" {
  address       = "127.0.0.1:8201"
  tls_cert_file = "/certs/secret-manager/tls.crt"
  tls_key_file  = "/certs/secret-manager/tls.key"
}

storage "file" {
  path = "/secret-manager/file"
}
