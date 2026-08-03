# Workload Identity Federation + Confidential Space attestation for the KMS TEE.
#
# The kms-tee per-role backend impersonates 5 per-role service accounts from a
# BASE identity. This module makes that base identity attestation-gated: only a
# Confidential Space workload running an allowlisted kms-tee image digest, in THIS
# project, can federate (via a Workload Identity Pool) to the attested base SA,
# which in turn holds serviceAccountTokenCreator on the 5 per-role SAs. A tampered
# image, a copy of the image in another project, a general VM, or any non-attested
# workload fails the pool's attribute condition and never obtains the base SA — so
# it can never impersonate the per-role SAs or unwrap sk.
#
# This module provisions the pool/provider/base-SA and the base->per-role
# tokenCreator seam. It does NOT provision the per-role SAs' own SM/KMS IAM (that
# is each role's least-privilege grant, managed elsewhere), the CMEK, or the
# Confidential Space deployment.
#
# Claim schema: https://cloud.google.com/confidential-computing/confidential-space/docs/reference/token-claims

terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
}

# Derive the project number from the project id rather than taking it as a
# separate input: a manually-entered wrong number applies cleanly but pins
# another project in the attribute condition, so every real attestation token is
# rejected — a silent federation failure. Deriving it removes that error class.
data "google_project" "this" {
  project_id = var.project_id
}

locals {
  # Single source of truth for the released kms-tee image digests. The committed
  # manifest (kms-digests/kms-tee-released-digests.json) carries every
  # released digest with an allowlist lifecycle status. Deriving the allowlist here
  # (rather than taking a var) means the reviewed manifest edit — not a separate
  # tfvars — is what changes what the provider admits, so promote/deprecate/revoke
  # is one gated PR against one file.
  #
  # `revoked` is the ONLY global hard-removal: it is NEVER admitted, so a revoke
  # drops the digest from every derived allowlist. `active` is always admitted.
  # `deprecated` is admitted ONLY when var.include_deprecated is true. A managed
  # derivation leaves the default (false, active-only), so a managed deprecation
  # removes the digest on the next apply. A self-hosted deployer whose fleet still
  # runs a deprecated release sets include_deprecated=true so a managed deprecation
  # does NOT force-remove a release they still run — only a `revoked` status forces
  # its removal, preserving the "a deployer holding an older release stays admitted
  # until the digest is revoked" guarantee.
  #
  # The path is overridable via var.manifest_path so a self-hosted root that
  # consumes kms-wif as a git-sourced module can point at its own synced/vendored
  # manifest rather than the copy packaged next to the module SOURCE. A variable
  # default cannot reference path.module, so the var default is null and we
  # coalesce it here to the in-repo manifest, keeping the in-repo layout working
  # with no override.
  _kms_tee_manifest_path = coalesce(var.manifest_path, "${path.module}/../../../kms-digests/kms-tee-released-digests.json")
  _kms_tee_manifest      = jsondecode(file(local._kms_tee_manifest_path))
  kms_tee_image_digests  = [for d in local._kms_tee_manifest : d.digest if d.status == "active" || (var.include_deprecated && d.status == "deprecated")]

  # Keyed by role NAME (not email) so the tokenCreator for_each keys are known at
  # plan time even when the per-role SA emails arrive as computed
  # google_service_account.email attributes from the sibling gcp/kms-iam module.
  # Keying on the email values would make the for_each keys apply-unknown and break
  # a single-root plan that wires kms-iam -> kms-wif.
  role_sa_emails = {
    keygen          = var.per_role_sa_emails.keygen
    rotate          = var.per_role_sa_emails.rotate
    key_info        = var.per_role_sa_emails.key_info
    score_decryptor = var.per_role_sa_emails.score_decryptor
    metadata_cipher = var.per_role_sa_emails.metadata_cipher
  }

  # Where the Confidential Space launcher writes the attestation token inside the
  # CVM; the external_account cred-config reads it as the subject token. Single
  # source so a CS-launcher spec change is a one-line edit.
  cs_attestation_token_path = "/run/container_launcher/attestation_verifier_claims_token"

  # Confidential Space attestation-token claims the pool condition checks:
  #  - swname CONFIDENTIAL_SPACE: issued by a real Confidential Space workload.
  #  - gce.project_number == our project: only THIS deployment's CS VMs, so the
  #    same image copied into another project cannot federate into the base SA.
  #  - image digest in the released allowlist: the exact reviewed image.
  #  - support_attributes contains STABLE: a supported production CS image (TCB).
  #  - dbgstat disabled-since-boot: not a debug image (prod default).
  # An empty DERIVED set (kms_tee_image_digests — active, plus deprecated when
  # include_deprecated) is a valid break-glass state (e.g. revoking the ONLY
  # admitted digest), not an error: it must produce a deny-all gate, never an
  # un-appliable provider. So when the derived set is empty, emit the constant CEL
  # literal "false" — attribute_condition becomes "... && (false) && ...", which
  # is valid CEL that admits NOTHING. A non-empty set keeps the digest disjunction.
  # This also avoids the degenerate "&& ()" an empty join(" || ", []) would yield.
  digest_clause = length(local.kms_tee_image_digests) == 0 ? "false" : join(" || ", [for d in local.kms_tee_image_digests : "assertion.submods.container.image_digest == '${d}'"])
  stable_clause = var.require_stable_support ? " && 'STABLE' in assertion.submods.confidential_space.support_attributes" : ""
  debug_clause  = var.require_debug_disabled ? " && assertion.dbgstat == 'disabled-since-boot'" : ""

  # Pin the workload SA to be EXACTLY the runner SA. assertion.google_service_accounts
  # holds the SA attached via --service-account AND any listed via
  # tee-impersonate-service-accounts, so a mere membership test could be satisfied by
  # attaching the base (or another privileged) SA while also listing the runner SA —
  # the metadata server would then expose the privileged attached SA, defeating the
  # minimal-runner invariant. Require size 1 + membership so the ONLY asserted account
  # is the runner SA. Always enforced (no legitimate reason to relax).
  sa_clause = " && size(assertion.google_service_accounts) == 1 && '${google_service_account.kms_tee_runner.email}' in assertion.google_service_accounts"

  # Pin the operator-supplied config in the attestation. The operator sets these via
  # tee-env and config.Load uses them, so without pinning, a launch with the
  # allowlisted image + runner SA but swapped values still passes the gate:
  #  - per-role SA mapping: the base SA can mint tokens for ALL five role SAs, so an
  #    unpinned swap could run e.g. score-decryptor under the keygen SA's broader IAM.
  #  - storage config (project / keyring / key / prefix): an unpinned swap could
  #    read/write a different Secret Manager namespace or seal/unseal under a
  #    different CMEK where the per-role SAs have project/keyring-level IAM.
  # The exact audience of THIS provider, built from known ids (no self-reference to the
  # provider resource, which would be a cycle). Also exported (outputs.tf) so the launcher
  # pins the identical string via ENVECTOR_KMS_GCP_WIF_AUDIENCE.
  wif_audience = "//iam.googleapis.com/projects/${data.google_project.this.number}/locations/global/workloadIdentityPools/${var.pool_id}/providers/${var.provider_id}"

  # Bind each value, as attested in submods.container.env, to its expected value.
  env_clause = join("", [
    " && assertion.submods.container.env['ENVECTOR_KMS_GCP_SA_KEYGEN'] == '${var.per_role_sa_emails.keygen}'",
    " && assertion.submods.container.env['ENVECTOR_KMS_GCP_SA_ROTATE'] == '${var.per_role_sa_emails.rotate}'",
    " && assertion.submods.container.env['ENVECTOR_KMS_GCP_SA_KEY_INFO'] == '${var.per_role_sa_emails.key_info}'",
    " && assertion.submods.container.env['ENVECTOR_KMS_GCP_SA_SCORE_DECRYPTOR'] == '${var.per_role_sa_emails.score_decryptor}'",
    " && assertion.submods.container.env['ENVECTOR_KMS_GCP_SA_METADATA_CIPHER'] == '${var.per_role_sa_emails.metadata_cipher}'",
    " && assertion.submods.container.env['ENVECTOR_KMS_GCP_PROJECT'] == '${var.project_id}'",
    " && assertion.submods.container.env['ENVECTOR_KMS_GCP_KMS_KEYRING'] == '${var.kms_keyring}'",
    " && assertion.submods.container.env['ENVECTOR_KMS_GCP_KMS_KEY'] == '${var.kms_key}'",
    # Pin the dedicated metadata CMEK env so a launch cannot enable/redirect the
    # per-type split under an unattested key. Two cases:
    #  - split ON  (kms_key_metadata set): require the EXACT configured value.
    #  - split OFF (unset): require the env to be ABSENT or EMPTY. A present,
    #    non-empty value is rejected, so an operator cannot inject a metadata CMEK
    #    into a single-CMEK deployment (the runtime enables the split whenever the
    #    env is non-empty, and it is allowlisted for override). Absent is accepted so
    #    pre-existing single-CMEK launches / older images that never emit this env
    #    still federate; the current launcher emits it empty, which also passes.
    (var.kms_key_metadata != null && var.kms_key_metadata != "" ?
      " && assertion.submods.container.env['ENVECTOR_KMS_GCP_KMS_KEY_METADATA'] == '${var.kms_key_metadata}'" :
    " && (!('ENVECTOR_KMS_GCP_KMS_KEY_METADATA' in assertion.submods.container.env) || assertion.submods.container.env['ENVECTOR_KMS_GCP_KMS_KEY_METADATA'] == '')"),
    " && assertion.submods.container.env['ENVECTOR_KMS_GCP_SECRET_PREFIX'] == '${var.secret_prefix}'",
    " && assertion.submods.container.env['ENVECTOR_KMS_GCP_BASE_SA'] == '${google_service_account.kms_tee_attested.email}'",
    # Ties the guard's client-side audience check to an ATTESTED value: a tampered launch
    # cannot point WIF_AUDIENCE at a different (weaker-condition) same-pool provider.
    " && assertion.submods.container.env['ENVECTOR_KMS_GCP_WIF_AUDIENCE'] == '${local.wif_audience}'",
    # The guard's own enable toggle must be attested: otherwise an operator can set
    # REQUIRE_ATTESTED_BASE=false via allowlisted tee-env and the token still federates,
    # silently disabling checkAttestedBase and the per-role hard-requirement.
    " && assertion.submods.container.env['ENVECTOR_KMS_GCP_REQUIRE_ATTESTED_BASE'] == 'true'",
    # The backend selector decides whether the gcp guard + per-role enforcement run at
    # all; pin it so an attested launch is provably on the gcp path (not routed to vault).
    " && assertion.submods.container.env['ENVECTOR_KMS_SECRET_BACKEND'] == 'gcp'",
    # NOTE: ENVECTOR_KMS_GCP_WIF_CREDCONFIG and ENVECTOR_KMS_LOG_LEVEL are allowlisted for
    # override but intentionally NOT pinned here. CREDCONFIG is per-deployment secret
    # material (delivered via --metadata-from-file) that the client guard re-validates on
    # the resolved ADC — a bogus one fails checkAttestedBase or the STS exchange; LOG_LEVEL
    # is a non-security operational knob.
  ])

  attribute_condition = "assertion.swname == 'CONFIDENTIAL_SPACE' && assertion.submods.gce.project_number == '${data.google_project.this.number}' && (${local.digest_clause})${local.stable_clause}${local.debug_clause}${local.sa_clause}${local.env_clause}"

  # This dedicated base-SA pool's sole provider, declared as a single-element
  # map so adding a provider means adding a map entry — which the lifecycle
  # precondition on google_iam_workload_identity_pool_provider.base rejects
  # (see there for enforcement scope, and pool_can_impersonate_base for why).
  base_pool_providers = {
    confidential_space = local.attribute_condition
  }
}

# Warn (do NOT block) when an attestation-hardening check is relaxed. The two
# toggles below exist only to attest a confidential-space-debug image during
# launcher troubleshooting; a production apply with either false accepts
# EXPERIMENTAL/preview or DEBUG images and is almost certainly a mistake. A check
# block emits a warning on every plan/apply (not an error), so the relaxed state
# is loud without breaking the debug workflow.
check "attestation_hardening_enabled" {
  assert {
    condition     = var.require_stable_support && var.require_debug_disabled
    error_message = "Attestation hardening is RELAXED (require_stable_support=${var.require_stable_support}, require_debug_disabled=${var.require_debug_disabled}). This accepts non-STABLE (EXPERIMENTAL/preview) or DEBUG Confidential Space images and MUST be used only for launcher troubleshooting — never in production."
  }
}

resource "google_iam_workload_identity_pool" "kms_tee" {
  project                   = var.project_id
  workload_identity_pool_id = var.pool_id
  display_name              = "enVector KMS TEE"
  description               = "Attestation-gated federation for the kms-tee Confidential Space workload."
}

# Remaps state from the pre-for_each bare address so an apply that still tracks
# it migrates in place instead of destroy-then-create (zero attribute diff).
# No-op today (no live state at the old address); additive and safe to keep.
moved {
  from = google_iam_workload_identity_pool_provider.confidential_space
  to   = google_iam_workload_identity_pool_provider.base["confidential_space"]
}

resource "google_iam_workload_identity_pool_provider" "base" {
  # Single-element for_each (see base_pool_providers) so a second provider is a
  # map entry the lifecycle precondition below rejects, not a silent addition.
  for_each = local.base_pool_providers

  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.kms_tee.workload_identity_pool_id
  workload_identity_pool_provider_id = var.provider_id
  display_name                       = "Confidential Space"
  description                        = "Trusts Google-signed Confidential Space attestation tokens for the allowlisted kms-tee image."

  attribute_mapping = {
    # sub is the VM selfLink, which can exceed IAM's 127-byte google.subject
    # limit; map the bounded, unique instance id instead.
    "google.subject"           = "assertion.submods.gce.instance_id"
    "attribute.image_digest"   = "assertion.submods.container.image_digest"
    "attribute.image_ref"      = "assertion.submods.container.image_reference"
    "attribute.project_number" = "assertion.submods.gce.project_number"
  }

  # Only tokens satisfying this condition can mint a pool credential.
  attribute_condition = each.value

  oidc {
    issuer_uri = "https://confidentialcomputing.googleapis.com/"
    # Confidential Space mints the attestation token with aud = the STS endpoint
    # that consumes it; the provider must accept that audience.
    allowed_audiences = ["https://sts.googleapis.com"]
  }

  # Hard-block a production apply that relaxes the hardening toggles without the
  # deliberate escape hatch. The check block above only WARNS; this precondition
  # ERRORS, so a stray troubleshooting tfvars (require_stable_support=false, etc.)
  # cannot silently weaken attestation — a real debug run must set
  # allow_relaxed_attestation=true on purpose.
  lifecycle {
    precondition {
      condition     = (var.require_stable_support && var.require_debug_disabled) || var.allow_relaxed_attestation
      error_message = "require_stable_support/require_debug_disabled are relaxed but allow_relaxed_attestation is false. Relaxing attestation checks (debug/preview images) requires setting allow_relaxed_attestation=true deliberately; do not do this in production."
    }

    # Every manifest digest must be a full sha256:<64-hex> image digest — over the
    # FULL manifest, not just the active subset. An active malformed digest would be
    # interpolated verbatim into the single-quoted CEL image_digest literal, silently
    # weakening the gate; but a deprecated/revoked row with a malformed digest also
    # matters: the manifest is the published audit/revocation signal, and the
    # uniqueness + status-enum preconditions already iterate the full manifest, so a
    # malformed digest must not slip through a deprecated/revoked row just because the
    # JSON-schema lint was skipped. Match the full manifest here for the same reason.
    precondition {
      condition     = alltrue([for d in local._kms_tee_manifest : can(regex("^sha256:[0-9a-f]{64}$", d.digest))])
      error_message = "Every kms-tee digest in the manifest must be a full sha256:<64-hex> image digest (checked over all rows, not just active)."
    }

    # Every manifest row's status must be a known lifecycle value. The active set
    # is derived as "any row with status == active", so an out-of-enum typo
    # (e.g. "actve", "Active", "deprecated " with a trailing space) is silently
    # treated as not-active: it either drops an intended-active digest from the
    # allowlist or slips an invalid lifecycle signal past review. The JSON-schema
    # lint (lint_test.sh) catches this, but Terraform must not trust the manifest
    # blindly — assert the enum here so a status typo fails plan/apply even when
    # the lint was skipped.
    precondition {
      condition     = alltrue([for d in local._kms_tee_manifest : contains(["active", "deprecated", "revoked"], d.status)])
      error_message = "Every kms-tee manifest row's status must be one of: active, deprecated, revoked. An out-of-enum value (typo, wrong case, or trailing whitespace) is silently treated as not-active and can drop an intended-active digest or admit an invalid lifecycle signal."
    }

    # GCP caps a provider attribute_condition at 4096 characters. The condition
    # grows by one image_digest equality clause (~120 chars) per digest in the
    # DERIVED set — the active rows, plus deprecated rows when include_deprecated
    # is on — so an accumulating manifest would silently push the CEL past the cap
    # and make every subsequent apply fail with a raw GCP error. Guard it at plan
    # time with an actionable message. To shorten the condition, REVOKE stale
    # digests (revoked rows are excluded from the derived set in every mode);
    # merely deprecating an active digest does NOT help when include_deprecated is
    # true, because deprecated rows still count.
    precondition {
      condition     = length(each.value) <= 4096
      error_message = "The derived WIF attribute_condition exceeds GCP's 4096-character limit. Revoke stale digests in kms-digests/kms-tee-released-digests.json (revoked rows are excluded from the derived set in every mode). If include_deprecated is enabled, deprecating an active digest will NOT shorten the condition — revoke it, or disable include_deprecated."
    }

    # NOTE: an empty DERIVED set is intentionally ALLOWED. The derived set is the
    # admitted subset (active, plus deprecated when include_deprecated); it is a
    # valid break-glass state — revoking the last admitted digest empties it — and
    # the digest_clause above turns it into a deny-all "false" gate (a valid CEL
    # provider that admits nothing) rather than an un-appliable "&& ()" syntax
    # error. So there is deliberately NO non-empty precondition here: dropping a
    # compromised last digest must apply cleanly, and the resulting provider
    # simply admits no workload until a new digest is promoted to active.

    # Every digest in the FULL manifest must be unique across ALL rows. The
    # active set is derived as "any row with status == active", so a manifest
    # carrying both {D, active} and a later {D, revoked|deprecated} row keeps D
    # in the allowlist despite the revoke/deprecate intent — an accidental
    # append (instead of an in-place status edit) would silently fail to remove
    # key access. Rejecting duplicate digests forces status changes to be
    # in-place edits of the single row for that digest.
    precondition {
      condition     = length(distinct([for d in local._kms_tee_manifest : d.digest])) == length(local._kms_tee_manifest)
      error_message = "Duplicate digest in the kms-tee manifest: each digest must appear in exactly one row. Change a digest's lifecycle status by editing its existing row in place, not by appending a new row for the same digest."
    }

    # A metadata CMEK equal to the sk CMEK would pin the sk key as the metadata key
    # in the attestation condition, so a launch that collapses the per-type boundary
    # still attests. Reject it (mirrors the kms-iam data-source precondition and the
    # runtime fail-fast).
    precondition {
      condition     = var.kms_key_metadata == null || var.kms_key_metadata == "" || var.kms_key_metadata != var.kms_key
      error_message = "kms_key_metadata must differ from kms_key: pinning the sk key as the metadata CMEK lets a launch that collapses the sk/metadata boundary still attest."
    }

    # Enforces the single-strong-provider invariant: a lifecycle precondition
    # fails plan/apply on a second base_pool_providers entry, where a `check`
    # block would only warn and let apply proceed. Scope is honest — it guards
    # the map-extension path only; a separate provider resource pointed at this
    # pool would bypass it and remains a code-review catch.
    precondition {
      condition     = length(local.base_pool_providers) == 1
      error_message = "envector-kms-tee-base must have exactly one strong attestation provider. Do not extend base_pool_providers -- a second identity source belongs in a SEPARATE pool. See the SECURITY INVARIANT comment on pool_can_impersonate_base below."
    }
  }
}

# The attested base identity. It holds NO direct Secret Manager / Cloud KMS
# roles — only the ability to be federated-into (workloadIdentityUser) and to mint
# tokens for the per-role SAs (tokenCreator). This is the whole least-privilege
# point: the base is a pure impersonation hop, gated by attestation.
resource "google_service_account" "kms_tee_attested" {
  project      = var.project_id
  account_id   = var.base_sa_account_id
  display_name = "enVector KMS TEE (attested base)"
  description  = "Federated-into by the Confidential Space kms-tee; impersonates the 5 per-role SAs. No direct SM/KMS roles."
}

# The CVM runner identity — attached to the Confidential Space VM (NOT the base
# SA). This separation is load-bearing for the attestation gate: the metadata
# server hands the attached SA to ANY container on the VM without attestation, so
# attaching the base SA (which holds tokenCreator on the 5 per-role SAs) would let
# a tampered image on the same VM read it from the metadata server and impersonate
# the per-role SAs — bypassing the WIF/attestation check. The runner SA is kept
# powerless (no tokenCreator on the per-role SAs); the only path to the base SA is
# the attested WIF exchange, which succeeds only for an allowlisted image. The
# runner SA needs artifactregistry.reader (repo-scoped, granted outside this
# module like the per-role SM/KMS IAM), plus the two project-level roles below.
resource "google_service_account" "kms_tee_runner" {
  project      = var.project_id
  account_id   = var.runner_sa_account_id
  display_name = "enVector KMS TEE (CVM runner)"
  description  = "Attached to the Confidential Space CVM. Minimal: AR reader + workloadUser + logWriter. NO tokenCreator on per-role SAs; the base SA is reached only via attested WIF."
}

# workloadUser lets the attached SA obtain the Confidential Space attestation
# token; logWriter lets the launcher redirect container logs to Cloud Logging.
resource "google_project_iam_member" "runner_workload_user" {
  project = var.project_id
  role    = "roles/confidentialcomputing.workloadUser"
  member  = "serviceAccount:${google_service_account.kms_tee_runner.email}"
}

resource "google_project_iam_member" "runner_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.kms_tee_runner.email}"
}

# Any workload whose attestation token satisfied the provider attribute_condition
# above (Confidential Space + our project + an allowlisted image digest + STABLE)
# may impersonate the base SA. The member is pool-wide (/*) BY DESIGN: the digest
# ALLOWLIST is the rollout control and lives in the provider condition, not in the
# member string — scoping the member to a single digest would break multi-digest
# rollout. Enforcement is the condition, not the member.
#
# SECURITY INVARIANT (single strong provider): the member is pool-wide and IAM has
# no provider-scoped principalSet, so ANY provider in this pool can mint the base SA
# — each provider's OWN attribute_condition is the only gate. This pool
# (envector-kms-tee-base) is therefore DEDICATED to one provider (confidential_space),
# held to exactly one by the lifecycle precondition on ...base above. Do NOT add
# another workload's provider here: a launch through it (with a matching
# ENVECTOR_KMS_GCP_WIF_AUDIENCE) would bypass this provider's env/image pins — a
# second identity source belongs in its OWN pool. This is the GCP realization of a
# cloud-neutral invariant — "attested base = dedicated single-strong-attestation-
# condition trust boundary" — that AWS/OCI realize via their own native primitives,
# not WIF. The client-side WIF_AUDIENCE pin defends against a stale/misrouted
# cred-config through THIS provider, not a deliberately added pool.
resource "google_service_account_iam_member" "pool_can_impersonate_base" {
  service_account_id = google_service_account.kms_tee_attested.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/projects/${data.google_project.this.number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.kms_tee.workload_identity_pool_id}/*"
}

# Remaps the two renamed for_each instance keys (metadata->key_info,
# score_decrypt->score_decryptor) so an upgraded deployment migrates the
# base->per-role tokenCreator bindings in place instead of destroy-then-create.
# Only these two role keys were renamed; keygen/rotate/metadata_cipher are
# unchanged. No-op today (no live state at the old keys); additive and safe to keep.
moved {
  from = google_service_account_iam_member.base_can_impersonate_roles["metadata"]
  to   = google_service_account_iam_member.base_can_impersonate_roles["key_info"]
}

moved {
  from = google_service_account_iam_member.base_can_impersonate_roles["score_decrypt"]
  to   = google_service_account_iam_member.base_can_impersonate_roles["score_decryptor"]
}

# The seam to the per-role layer: the attested base SA can mint tokens for each of
# the 5 per-role SAs (and nothing else). Replaces the ambient-ADC base grant used
# in the non-attested (normal-VM) deployment.
resource "google_service_account_iam_member" "base_can_impersonate_roles" {
  for_each           = local.role_sa_emails
  service_account_id = "projects/${var.project_id}/serviceAccounts/${each.value}"
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.kms_tee_attested.email}"
}
