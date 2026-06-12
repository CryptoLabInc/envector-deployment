ui = true

listener "tcp" {
  address                            = "0.0.0.0:8200"
  tls_cert_file                      = "/certs/vault/vault.crt"
  tls_key_file                       = "/certs/vault/vault.key"
  tls_client_ca_file                 = "/certs/ca/root_ca.crt"
  tls_require_and_verify_client_cert = true
}

listener "tcp" {
  address       = "127.0.0.1:8201"
  tls_cert_file = "/certs/vault/vault.crt"
  tls_key_file  = "/certs/vault/vault.key"
}

storage "file" {
  path = "/vault/file"
}
