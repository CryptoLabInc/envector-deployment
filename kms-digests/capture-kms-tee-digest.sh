#!/usr/bin/env bash
#
# capture-kms-tee-digest.sh — resolve the released kms-tee amd64 image digest.
#
# The single source of the "which digest did release <TAG> produce" logic. Both
# the release workflow (.github/workflows/release.yaml, the capture-kms-tee-digest
# job) and the digest-rollout runbook (docs/runbooks/kms/digest-rollout.md, Step 1)
# call THIS script to resolve the digest, so the two cannot drift.
#
# Usage:
#   capture-kms-tee-digest.sh <release-tag> [ar-image-base]
#     <release-tag>   the release tag whose amd64 image digest to resolve.
#     [ar-image-base] the Artifact Registry image (no tag); defaults to the
#                     managed AR repo
#                     asia-northeast3-docker.pkg.dev/my-gcp-project/envector/envector-kms-tee.
#
# EXACT GA gate (GitHub Actions `if:` has no regex, so the gate lives here):
#   GA tags are `X.Y.Z` with NO `v` prefix and NO suffix (see the `on: push:
#   tags:` globs and the create-manifest `:latest` gate). A prerelease or any
#   suffixed tag (`X.Y.ZrcN`, `X.Y.Z-alpha.N`, `X.Y.ZdevN`, `vX.Y.Z`, ...) must
#   NOT become a standing `active` key-access digest, so for a non-GA tag this
#   script prints NOTHING to STDOUT and exits 0, signalling "not a GA release ->
#   no promotion" (see STDOUT CONTRACT).
#
# STDOUT CONTRACT: STDOUT carries ONLY the resolved digest (sha256:<64-hex>), or
# nothing at all for a non-GA tag. Every note/error goes to STDERR, so a caller
# can do `digest="$(capture-kms-tee-digest.sh "$TAG")"` and treat an empty
# result as "no promotion".
set -euo pipefail

TAG="${1:-}"
AR_IMAGE_BASE="${2:-asia-northeast3-docker.pkg.dev/my-gcp-project/envector/envector-kms-tee}"

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "::error::usage: $0 <release-tag> [ar-image-base]" >&2
  exit 1
fi
if [ -z "${TAG}" ]; then
  echo "::error::release-tag must be a non-empty string" >&2
  exit 1
fi

# --- EXACT GA gate ---------------------------------------------------------
# `=~` in [[ ]] carries both ^ and $ anchors; bash's regex `$` does NOT match
# before a trailing newline (unlike Python's re), so a `X.Y.Z\n` or any trailing
# character is rejected — only an exact `X.Y.Z` (no `v`, no suffix) passes.
if [[ ! "${TAG}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Tag '${TAG}' is not an exact GA SemVer (X.Y.Z); skipping kms-tee digest capture (no promotion)." >&2
  exit 0
fi

# --- Resolve the amd64 image digest ----------------------------------------
# The "-amd64" suffix is a contract with the release workflow
# (.github/workflows/release.yaml), which publishes the kms-tee image per-arch as
# "<tag>-amd64" — the WIF digest allowlist pins one concrete amd64 manifest, not a
# multiarch index. If the release tagging scheme ever changes, update both sides;
# a tag that does not exist yields an empty digest, rejected just below.
DIGEST="$(gcloud artifacts docker images describe \
  "${AR_IMAGE_BASE}:${TAG}-amd64" \
  --format='value(image_summary.digest)')"
if [ -z "${DIGEST}" ]; then
  echo "::error::empty kms-tee amd64 digest — image not found in AR" >&2
  exit 1
fi

printf '%s\n' "${DIGEST}"
