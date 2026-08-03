# gcp/kms-root — apply `kms-iam` + `kms-wif` in one pass

Wires the two GCP KMS modules into a single root so `terraform apply` provisions the whole
attestation stack at once: the five per-role SAs and their least-privilege Cloud KMS /
Secret Manager IAM (`../kms-iam`), and the Workload Identity pool, attested provider, base
SA and runner SA (`../kms-wif`).

## Why a root instead of applying each module

The modules depend on each other in **opposite directions**, but on different resources:

```
kms-iam's 5 per-role SAs  ->  kms-wif's base->per-role tokenCreator bindings
kms-wif's runner SA       ->  kms-iam's Artifact Registry reader binding
```

Passing each as a real reference (`module.kms_wif.runner_sa_email`,
`module.kms_iam.per_role_sa_emails`) gives Terraform both edges, and the graph is a DAG — it
orders the resources itself. A module-wide `depends_on` between the two collapses those
edges to module granularity and **is** a cycle; do not add one.

Applying the modules separately still works, it just costs an extra pass: `kms-iam`'s AR
binding cannot apply before the runner SA exists (granting a role to a nonexistent service
account is a hard `400`), so `runner_sa_email` defaults to empty and skips it until you set
it. See `../kms-iam/README.md`.

## Usage

```bash
cd terraform/gcp/kms-root
# terraform.tfvars — see docs/runbooks/kms/gcp-kms-backend-guide.md §3.1 for a worked example
terraform init
terraform apply -var-file=terraform.tfvars
```

`manifest_path` is resolved from the directory Terraform runs in, so a relative test
manifest belongs here in `kms-root/`. Leave it unset in production to read the committed
`kms-digests/kms-tee-released-digests.json`.

Outputs: `per_role_sa_emails`, `base_sa_email`, `runner_sa_email`, `provider_audience`,
`attribute_condition`, `external_account_credential_config` — the values the Confidential
Space launcher pins as attested `tee-env-*` metadata.

**Do not mix paths in one project.** This root keeps its own state; applying a module
standalone afterwards would try to create everything a second time.
