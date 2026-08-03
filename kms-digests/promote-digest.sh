#!/usr/bin/env bash
#
# promote-digest.sh — append a released kms-tee digest to the manifest (idempotent).
#
# The single source of truth for admitted kms-tee image digests is the manifest
# (kms-digests/kms-tee-released-digests.json). Both the promote
# workflow (.github/workflows/kms-digest-promote.yaml) and the digest-rollout
# runbook (docs/runbooks/kms/digest-rollout.md) call THIS script to apply the
# status-branch edit, so the two cannot drift.
#
# Usage:
#   promote-digest.sh <digest> <release> [manifest-path]
#     <digest>        amd64 image manifest digest to promote (sha256:<64-hex>).
#     <release>       release tag the digest was built from (human traceability).
#     [manifest-path] manifest JSON to edit; defaults to the manifest bundled
#                     next to this script (kms-tee-released-digests.json).
#
# Status-branch on the digest's EXISTING row (not merely on presence):
#   - absent               -> append {digest, release, status:"active"} IN PLACE,
#                             then print `true` (the changed flag).
#   - present AND active   -> genuine no-op (idempotent), print `false`.
#   - present but NON-active (deprecated/revoked) -> CONFLICT: print an
#     `::error::` line to STDERR and exit 1. A GA release that rebuilds/retags a
#     digest already present as deprecated/revoked must NOT silently skip: the
#     managed (active-only) allowlist would still EXCLUDE it, so the rollout
#     could ship an image that cannot attest while the release looks promoted.
#     Re-admitting it needs a deliberate reactivation PR (and a revoked digest
#     must never be silently re-admitted).
#
# STDOUT CONTRACT: on success, STDOUT carries ONLY the `true`/`false` changed
# flag, so a caller can do `changed="$(promote-digest.sh ...)"`. All
# human/info/error text is written to STDERR.
#
# Do NOT put ticket IDs in the committed manifest (repo policy) — describe the
# reason in the PR body and git history.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DIGEST="${1:-}"
RELEASE="${2:-}"
MANIFEST="${3:-${SCRIPT_DIR}/kms-tee-released-digests.json}"

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "::error::usage: $0 <digest> <release> [manifest-path]" >&2
  exit 1
fi

# --- Validate inputs -------------------------------------------------------
# The pattern is anchored with ^ and $, so `=~` in [[ ]] cannot partial-match;
# bash's regex `$` does NOT match before a trailing newline (unlike Python's
# re), so "sha256:<64-hex>\n" and any extra trailing character are rejected. A
# 63-hex string fails the {64} quantifier.
if [[ ! "${DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "::error::digest '${DIGEST}' does not match ^sha256:[0-9a-f]{64}$" >&2
  exit 1
fi
if [ -z "${RELEASE}" ]; then
  echo "::error::release must be a non-empty string" >&2
  exit 1
fi
if [ ! -f "${MANIFEST}" ]; then
  echo "::error::manifest not found: ${MANIFEST}" >&2
  exit 1
fi

# --- Serialize the read-modify-write ---------------------------------------
# The status read below, the jq rewrite, and the mv are not atomic together, so
# two overlapping promotions could each read the old manifest and the second mv
# would silently drop the first's append. Hold an exclusive lock for the whole
# critical section. Promotions are serialized by the PR/CI path today, so this is
# a backstop for the manual runbook path. flock auto-releases if the process dies.
if command -v flock >/dev/null 2>&1; then
  exec 9>"${MANIFEST}.lock"
  if ! flock -w 30 9; then
    echo "::error::timed out acquiring the manifest lock (${MANIFEST}.lock); another promote may be in progress" >&2
    exit 1
  fi
else
  echo "::warning::flock not found; proceeding without a manifest lock (relying on the PR/CI path to serialize concurrent promotions)" >&2
fi

# --- Status-branch on the existing row -------------------------------------
status="$(jq -r --arg d "${DIGEST}" \
  'map(select(.digest == $d)) | if length == 0 then "absent" else .[0].status end' \
  "${MANIFEST}")"

case "${status}" in
  absent)
    jq --arg d "${DIGEST}" --arg r "${RELEASE}" \
      '. + [{"digest": $d, "release": $r, "status": "active"}]' \
      "${MANIFEST}" > "${MANIFEST}.tmp"
    mv "${MANIFEST}.tmp" "${MANIFEST}"
    echo "digest ${DIGEST} appended as 'active' (release ${RELEASE}) in ${MANIFEST}" >&2
    echo "true"
    ;;
  active)
    echo "digest ${DIGEST} already present as 'active' in ${MANIFEST}; no-op." >&2
    echo "false"
    ;;
  *)
    echo "::error::digest ${DIGEST} already present as ${status}; promoting a non-active released digest requires an explicit reactivation PR" >&2
    exit 1
    ;;
esac
