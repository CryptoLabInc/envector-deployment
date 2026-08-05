# kms-tee released image digests

`kms-tee-released-digests.json` is the **single source of truth** for released
kms-tee container image digests and their allowlist lifecycle status. Every
digest listed here is a released, content-addressed (`@sha256`) kms-tee image;
the `status` field governs whether that digest is admitted to a live
attestation allowlist.

The design document behind this pipeline is internal to enVector engineering; ask your
enVector contact if you need it for a security review.

## Why this is authoritative

The Confidential Space attestation gate admits a kms-tee workload to the base
service account only when its measured image digest is on the WIF provider's
allowlist. Every `active` digest is therefore a **standing key-access
credential**: an image with that digest, run in the expected Confidential Space
VM, passes the attestation condition, obtains the base SA token, and can unwrap
keys.

Each Workload Identity provider (enVector-managed or customer self-hosted)
**derives** its live allowlist from this manifest — the `active` subset — rather
than maintaining a hand-edited digest list. Operators edit this manifest; they
never edit a derived list. The WIF provider derivation is the live consumer of
this manifest today: editing it, reviewing it, and applying is what changes which
digests can unwrap keys. The step-ca attestation-bound issuance check (ES2-2190)
is **designed** to consume this same manifest so transport-identity issuance and
the key-access gate cannot admit different digest sets — but it is a follow-up:
mTLS issuance does not yet consult the manifest, so do not assume it already
denies a non-`active` digest. This keeps one auditable, reviewed source feeding
every derived allowlist (and, once ES2-2190 lands, the issuance check too).

## File shape

A JSON array of entries, each `{digest, release, status}`:

```json
[
  { "digest": "sha256:<64-hex>", "release": "<tag>", "status": "active" }
]
```

- `digest` — the amd64 image manifest digest the Confidential Space VM reports
  as `submods.container.image_digest`. Must match `^sha256:[0-9a-f]{64}$`.
- `release` — the release tag the digest was built from (human traceability).
  A non-empty string.
- `status` — the allowlist lifecycle state (see below).

The seed manifest is an empty array (`[]`): valid but admitting nothing.
Operators append real digests as they are released. `schema.json` in this
directory is the machine-checkable contract for that shape.

## Lifecycle: active | deprecated | revoked

- **active** — admitted to live allowlists; keys may be unwrapped under this
  digest. The `active` set should be the minimal set actually in use plus any
  digests mid-rollout.
- **deprecated** — superseded and (upstream) no longer run by any workload;
  retained here (and in git history) for audit. Deprecation is gated on *no
  longer in use* — never on age — so a deployer that deliberately holds an older
  release keeps it admitted as long as a workload pins it. Whether `deprecated`
  is *removed* from a derived allowlist depends on the derivation mode (see
  below): a managed (active-only) derivation drops it; a self-hosted derivation
  with `include_deprecated = true` keeps it admitted.
- **revoked** — a compromised digest that must not be admitted anywhere. This is
  a security signal published to every deployer: `revoked` is excluded from
  every derived allowlist regardless of `include_deprecated`, and on the next
  manifest sync and apply the digest leaves each allowlist.

The subset of statuses derived into a live allowlist depends on the derivation
mode:

- **Managed (active-only) derivation** — only `active` entries are admitted;
  `deprecated` and `revoked` are excluded. Marking a digest `deprecated` removes
  it on the next apply.
- **Self-hosted derivation with `include_deprecated = true`** — `active` **and**
  `deprecated` entries are admitted; only `revoked` is excluded. Here marking a
  digest `deprecated` does NOT remove it — it stays a standing key-access
  credential (a HOLD). To actually stop admitting it, delete its row or set it
  `revoked` (see the rollout runbook's self-hosted removal note).

`deprecated` and `revoked` entries are retained in the manifest (and git
history) to preserve the audit trail even after they leave a live allowlist.

## Deployment models

- **Managed (enVector-operated):** enVector runs the kms-tee workload and owns
  the WIF provider; the managed allowlist is derived from this manifest and
  promoted through reviewed Terraform.
- **Self-hosted (customer-operated):** the customer runs kms-tee in their own
  project and owns their WIF provider and allowlist. enVector cannot read or
  modify a customer's allowlist — it *publishes* this manifest (and advisories),
  and each deployer *derives* its own live allowlist. Revocation reaches
  self-hosted deployers as a `revoked` status here plus a security advisory.

## Changing the manifest

Edits to this manifest are the trust gate on the measurement allowlist and
require security review (see the design doc's promotion flow). Automation
proposes a change (a PR appending a captured digest as `active`); a human
reviews and admits it. Record the change reason in the promoting PR and git
history — do **not** put ticket IDs in any file under this directory (repo
policy); describe the reason in words.

## Validating locally

`schema.json` is the contract; check a manifest against it before applying. Terraform's own
precondition only checks the digest shape, so a schema-only error (an empty `release`, an
out-of-enum `status`, an extra field) reaches the allowlist unnoticed:

```bash
jq -e 'type == "array" and all(.[];
        (.digest | test("^sha256:[0-9a-f]{64}$"))
        and (.release | type == "string" and length > 0)
        and (.status | IN("active","deprecated","revoked")))' \
  kms-digests/kms-tee-released-digests.json && echo "manifest OK"
```

If you set `var.manifest_path` to a synced copy elsewhere, check **that** file — the bundled
one being valid says nothing about yours.
