ui = true

# Backend-neutral secret-manager config, no-TLS dev profile. ONE HCL drives both
# Vault-protocol backends (HashiCorp Vault default, OpenBao) — the bao profile
# differs only by container image. Storage is the neutral /secret-manager/file
# path (both images run as root, so the root-owned named volume is writable).
listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}

storage "file" {
  path = "/secret-manager/file"
}
