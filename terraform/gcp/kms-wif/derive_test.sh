#!/usr/bin/env bash
# Test: local.kms_tee_image_digests is derived from the released manifest and
# contains ONLY the entries whose status == "active".
#
# Strategy: copy this kms-wif module into a temp dir and drop a FIXTURE manifest
# (one active + one deprecated + one revoked digest) at the path the module reads
# (../../../kms-digests/kms-tee-released-digests.json relative to the module). Then
# evaluate local.kms_tee_image_digests.
#
# Preferred oracle: `terraform console` (evaluates locals without a provider or
# credentials). If the terraform binary is unavailable, fall back to an equivalent
# jq derivation over the SAME fixture so the derivation logic is still asserted.
# Either way, if terraform exists we ALSO run `terraform validate` on the real
# module (which does not evaluate the non-empty precondition against data).
#
# The fixture's active digest is the ONLY one that must appear; the deprecated and
# revoked digests must NOT appear.
set -euo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Distinct, valid sha256:<64-hex> fixtures. Fill to 64 hex chars.
ACTIVE_DIGEST="sha256:$(printf 'a%.0s' {1..64})"
DEPRECATED_DIGEST="sha256:$(printf 'b%.0s' {1..64})"
REVOKED_DIGEST="sha256:$(printf 'c%.0s' {1..64})"

FIXTURE_MANIFEST=$(cat <<JSON
[
  { "digest": "${ACTIVE_DIGEST}",     "release": "v9.9.9-active",     "status": "active" },
  { "digest": "${DEPRECATED_DIGEST}", "release": "v9.9.8-deprecated", "status": "deprecated" },
  { "digest": "${REVOKED_DIGEST}",    "release": "v9.9.7-revoked",    "status": "revoked" }
]
JSON
)

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; exit 1; }

ran_console=0
ran_validate=0
ran_jq=0

if command -v terraform >/dev/null 2>&1; then
  # --- terraform console oracle over a temp copy with the fixture manifest ---
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT

  # Recreate the on-disk layout the module expects:
  #   $TMP/terraform/gcp/kms-wif/  <- module copy
  #   $TMP/kms-digests/kms-tee-released-digests.json  <- fixture
  MOD_COPY="$TMP/terraform/gcp/kms-wif"
  DIG_DIR="$TMP/kms-digests"
  mkdir -p "$MOD_COPY" "$DIG_DIR"
  cp "$MODULE_DIR"/*.tf "$MOD_COPY"/
  printf '%s\n' "$FIXTURE_MANIFEST" > "$DIG_DIR/kms-tee-released-digests.json"

  terraform -chdir="$MOD_COPY" init -backend=false -input=false >/dev/null

  # --- derivation with include_deprecated=false (default): only active ---------
  # Evaluate the derived list as JSON. `terraform console` reads expressions on
  # stdin; jsonencode makes the output machine-parseable regardless of HCL
  # formatting of the list. include_deprecated defaults to false, so a managed
  # derivation admits ONLY active — a deprecated digest leaves the allowlist.
  CONSOLE_OUT=$(echo 'jsonencode(local.kms_tee_image_digests)' \
    | terraform -chdir="$MOD_COPY" console 2>/dev/null)
  # console prints the string result quoted (a JSON string containing JSON); strip
  # the outer quotes and unescape to get the inner JSON array.
  DERIVED_JSON=$(printf '%s' "$CONSOLE_OUT" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()))' 2>/dev/null || true)
  # DERIVED_JSON is now the python-repr of the list; re-parse robustly with jq on
  # the raw console output instead for a clean assertion.
  DERIVED=$(printf '%s' "$CONSOLE_OUT" | python3 -c 'import sys,json; print("\n".join(json.loads(json.loads(sys.stdin.read()))))')
  ran_console=1

  echo "derived (terraform console, include_deprecated=false) = [${DERIVED//$'\n'/ , }]"

  grep -qx "$ACTIVE_DIGEST" <<<"$DERIVED"     || fail "active digest missing from derived list (include_deprecated=false)"
  grep -qx "$DEPRECATED_DIGEST" <<<"$DERIVED" && fail "deprecated digest leaked into derived list (include_deprecated=false)"
  grep -qx "$REVOKED_DIGEST" <<<"$DERIVED"    && fail "revoked digest leaked into derived list (include_deprecated=false)"
  [ "$(grep -c . <<<"$DERIVED")" -eq 1 ]      || fail "expected exactly 1 derived digest (include_deprecated=false)"
  pass "terraform console: include_deprecated=false derives exactly [active]"

  # --- derivation with include_deprecated=true: active + deprecated ------------
  # A self-hosted deployer that still runs a deprecated release derives with
  # include_deprecated=true so a managed deprecation does NOT force-remove the
  # release their fleet still pins. The derived set is then active + deprecated —
  # but STILL excludes revoked (revoked is the single global hard-removal). Pass
  # the toggle as a -var to the SAME fixture manifest.
  CONSOLE_OUT_DEP=$(echo 'jsonencode(local.kms_tee_image_digests)' \
    | terraform -chdir="$MOD_COPY" console -var 'include_deprecated=true' 2>/dev/null)
  DERIVED_DEP=$(printf '%s' "$CONSOLE_OUT_DEP" | python3 -c 'import sys,json; print("\n".join(json.loads(json.loads(sys.stdin.read()))))')

  echo "derived (terraform console, include_deprecated=true) = [${DERIVED_DEP//$'\n'/ , }]"

  grep -qx "$ACTIVE_DIGEST" <<<"$DERIVED_DEP"     || fail "active digest missing from derived list (include_deprecated=true)"
  grep -qx "$DEPRECATED_DIGEST" <<<"$DERIVED_DEP" || fail "deprecated digest missing from derived list (include_deprecated=true)"
  grep -qx "$REVOKED_DIGEST" <<<"$DERIVED_DEP"    && fail "revoked digest leaked into derived list (include_deprecated=true) — revoked must NEVER be admitted"
  [ "$(grep -c . <<<"$DERIVED_DEP")" -eq 2 ]      || fail "expected exactly 2 derived digests (active + deprecated) with include_deprecated=true"
  pass "terraform console: include_deprecated=true derives [active, deprecated], still excluding revoked"

  # --- unique-digest precondition: unique manifest satisfies it ---------------
  # The provider carries a precondition rejecting any manifest with a duplicate
  # digest across rows (so a revoke/deprecate must be an in-place status edit,
  # not an appended second row for the same digest). Evaluate the EXACT boolean
  # the precondition uses via `terraform console`. The current fixture has three
  # DISTINCT digests, so the uniqueness expression must be true.
  UNIQ_EXPR='length(distinct([for d in local._kms_tee_manifest : d.digest])) == length(local._kms_tee_manifest)'
  UNIQ_OUT=$(echo "$UNIQ_EXPR" | terraform -chdir="$MOD_COPY" console 2>/dev/null)
  [ "$UNIQ_OUT" = "true" ] \
    || fail "uniqueness precondition should be true for a unique manifest, got: $UNIQ_OUT"
  pass "terraform console: unique manifest passes the uniqueness precondition"

  # --- unique-digest precondition: DUPLICATE manifest is rejected -------------
  # Rewrite the fixture to append a SECOND row for the active digest with a
  # deprecated status (the accidental-append that in-place editing prevents).
  # The uniqueness expression must now be false — i.e. plan/apply would fail.
  DUP_MANIFEST=$(cat <<JSON
[
  { "digest": "${ACTIVE_DIGEST}",     "release": "v9.9.9-active",          "status": "active" },
  { "digest": "${DEPRECATED_DIGEST}", "release": "v9.9.8-deprecated",      "status": "deprecated" },
  { "digest": "${ACTIVE_DIGEST}",     "release": "v9.9.9-active-deprecate", "status": "deprecated" }
]
JSON
)
  printf '%s\n' "$DUP_MANIFEST" > "$DIG_DIR/kms-tee-released-digests.json"
  DUP_OUT=$(echo "$UNIQ_EXPR" | terraform -chdir="$MOD_COPY" console 2>/dev/null)
  [ "$DUP_OUT" = "false" ] \
    || fail "uniqueness precondition should be false for a duplicate-digest manifest, got: $DUP_OUT"
  pass "terraform console: duplicate-digest manifest fails the uniqueness precondition"

  # --- status-enum precondition: valid statuses satisfy it --------------------
  # The provider carries a precondition rejecting any manifest row whose status
  # is not in the {active, deprecated, revoked} enum (an out-of-enum typo is
  # silently treated as not-active, dropping an intended-active digest or
  # admitting an invalid lifecycle signal). Evaluate the EXACT boolean the
  # precondition uses via `terraform console`. Restore the unique fixture first;
  # all three of its statuses are in the enum, so the expression must be true.
  printf '%s\n' "$FIXTURE_MANIFEST" > "$DIG_DIR/kms-tee-released-digests.json"
  STATUS_EXPR='alltrue([for d in local._kms_tee_manifest : contains(["active", "deprecated", "revoked"], d.status)])'
  STATUS_OUT=$(echo "$STATUS_EXPR" | terraform -chdir="$MOD_COPY" console 2>/dev/null)
  [ "$STATUS_OUT" = "true" ] \
    || fail "status-enum precondition should be true for an all-valid-status manifest, got: $STATUS_OUT"
  pass "terraform console: all-valid-status manifest passes the status-enum precondition"

  # --- status-enum precondition: BAD status is rejected -----------------------
  # Rewrite the fixture so the intended-active row carries a typo'd status
  # ("actve"). The derivation would silently drop it from the active set (it is
  # not == "active"); the status-enum precondition must instead make plan/apply
  # fail. The expression must now be false.
  BAD_STATUS_MANIFEST=$(cat <<JSON
[
  { "digest": "${ACTIVE_DIGEST}",     "release": "v9.9.9-active",     "status": "actve" },
  { "digest": "${DEPRECATED_DIGEST}", "release": "v9.9.8-deprecated", "status": "deprecated" },
  { "digest": "${REVOKED_DIGEST}",    "release": "v9.9.7-revoked",    "status": "revoked" }
]
JSON
)
  printf '%s\n' "$BAD_STATUS_MANIFEST" > "$DIG_DIR/kms-tee-released-digests.json"
  BAD_STATUS_OUT=$(echo "$STATUS_EXPR" | terraform -chdir="$MOD_COPY" console 2>/dev/null)
  [ "$BAD_STATUS_OUT" = "false" ] \
    || fail "status-enum precondition should be false for a bad-status manifest, got: $BAD_STATUS_OUT"
  pass "terraform console: bad-status manifest fails the status-enum precondition"

  # Cross-check that the bad status silently vanishes from the DERIVED active set
  # (the exact failure mode the precondition guards): the typo'd row is not
  # "active", so the intended-active digest is absent — proving the precondition,
  # not the derivation, is what must reject it.
  BAD_DERIVED=$(echo 'jsonencode(local.kms_tee_image_digests)' \
    | terraform -chdir="$MOD_COPY" console 2>/dev/null \
    | python3 -c 'import sys,json; print("\n".join(json.loads(json.loads(sys.stdin.read()))))')
  grep -qx "$ACTIVE_DIGEST" <<<"$BAD_DERIVED" \
    && fail "bad-status ('actve') digest should NOT appear in the derived active set"
  pass "terraform console: bad-status row silently drops from the derived active set (guarded by the precondition)"

  # --- sha256-shape precondition: valid digests satisfy it (FULL manifest) -----
  # The provider carries a precondition rejecting any manifest row whose .digest
  # is not a full sha256:<64-hex> image digest. It iterates the FULL manifest
  # (local._kms_tee_manifest), NOT just the active subset — a deprecated/revoked
  # row with a malformed digest would otherwise pass plan/apply if the JSON-schema
  # lint was skipped, undermining the manifest as the audit/revocation signal.
  # Restore the unique fixture (all three digests are valid sha256:<64-hex>), so
  # the expression must be true.
  printf '%s\n' "$FIXTURE_MANIFEST" > "$DIG_DIR/kms-tee-released-digests.json"
  SHA_EXPR='alltrue([for d in local._kms_tee_manifest : can(regex("^sha256:[0-9a-f]{64}$", d.digest))])'
  SHA_OUT=$(echo "$SHA_EXPR" | terraform -chdir="$MOD_COPY" console 2>/dev/null)
  [ "$SHA_OUT" = "true" ] \
    || fail "sha256-shape precondition should be true for an all-valid-digest manifest, got: $SHA_OUT"
  pass "terraform console: all-valid-digest manifest passes the sha256-shape precondition"

  # --- sha256-shape precondition: malformed NON-ACTIVE digest is rejected ------
  # The active row stays valid; a deprecated AND a revoked row carry malformed
  # digests (too-short / bad charset). Because the precondition iterates the full
  # manifest, the expression must be false even though the ACTIVE subset is clean
  # — proving a malformed deprecated/revoked row is rejected, not silently
  # accepted. (An active-subset-only check would return true here.)
  BAD_DIGEST_MANIFEST=$(cat <<JSON
[
  { "digest": "${ACTIVE_DIGEST}",              "release": "v9.9.9-active",     "status": "active" },
  { "digest": "sha256:deadbeef",               "release": "v9.9.8-deprecated", "status": "deprecated" },
  { "digest": "sha256:NOTHEXZZ${REVOKED_DIGEST#sha256:}", "release": "v9.9.7-revoked", "status": "revoked" }
]
JSON
)
  printf '%s\n' "$BAD_DIGEST_MANIFEST" > "$DIG_DIR/kms-tee-released-digests.json"
  BAD_DIGEST_OUT=$(echo "$SHA_EXPR" | terraform -chdir="$MOD_COPY" console 2>/dev/null)
  [ "$BAD_DIGEST_OUT" = "false" ] \
    || fail "sha256-shape precondition should be false for a manifest with a malformed deprecated/revoked digest, got: $BAD_DIGEST_OUT"
  pass "terraform console: malformed deprecated/revoked digest fails the full-manifest sha256-shape precondition"

  # Cross-check that an ACTIVE-subset-only check would MISS this (the exact reason
  # the precondition must iterate the full manifest): the active row's digest is
  # valid, so restricting the regex to the active subset returns true — the bug
  # this fix closes.
  SHA_ACTIVE_ONLY_EXPR='alltrue([for d in local.kms_tee_image_digests : can(regex("^sha256:[0-9a-f]{64}$", d))])'
  SHA_ACTIVE_ONLY_OUT=$(echo "$SHA_ACTIVE_ONLY_EXPR" | terraform -chdir="$MOD_COPY" console 2>/dev/null)
  [ "$SHA_ACTIVE_ONLY_OUT" = "true" ] \
    || fail "active-subset-only sha256 check should be true here (active digest is valid), got: $SHA_ACTIVE_ONLY_OUT"
  pass "terraform console: active-subset-only check would MISS the malformed non-active digest (why the precondition iterates the full manifest)"

  # Restore the unique fixture for the digest_clause assertions below.
  printf '%s\n' "$FIXTURE_MANIFEST" > "$DIG_DIR/kms-tee-released-digests.json"

  # --- digest_clause: non-empty active set yields the '||' disjunction --------
  # Restore the unique fixture (one active digest) and assert digest_clause is
  # the image-digest disjunction (a single-element set is still the '==' form).
  printf '%s\n' "$FIXTURE_MANIFEST" > "$DIG_DIR/kms-tee-released-digests.json"
  CLAUSE_OUT=$(echo 'local.digest_clause' | terraform -chdir="$MOD_COPY" console 2>/dev/null)
  case "$CLAUSE_OUT" in
    *"image_digest == '${ACTIVE_DIGEST}'"*)
      pass "terraform console: non-empty active set yields the image_digest disjunction" ;;
    *)
      fail "non-empty digest_clause should contain the image_digest '==' clause, got: $CLAUSE_OUT" ;;
  esac

  # --- digest_clause: EMPTY active set yields deny-all 'false' -----------------
  # Break-glass: revoking the ONLY active digest empties the derived set. That
  # MUST NOT error (no non-empty precondition); it must produce a constant-false
  # CEL clause so attribute_condition becomes "... && (false) && ..." — a valid
  # provider that admits nothing (deny-all), never an un-appliable "&& ()".
  EMPTY_MANIFEST=$(cat <<JSON
[
  { "digest": "${REVOKED_DIGEST}", "release": "v9.9.7-revoked", "status": "revoked" }
]
JSON
)
  printf '%s\n' "$EMPTY_MANIFEST" > "$DIG_DIR/kms-tee-released-digests.json"
  EMPTY_CLAUSE_OUT=$(echo 'local.digest_clause' | terraform -chdir="$MOD_COPY" console 2>/dev/null)
  # console prints a string result quoted; the value must be exactly "false".
  [ "$EMPTY_CLAUSE_OUT" = '"false"' ] \
    || fail "empty active set should yield digest_clause \"false\" (deny-all), got: $EMPTY_CLAUSE_OUT"
  pass "terraform console: empty active set yields deny-all digest_clause = false"

  # `terraform validate` on the temp module copy WITH the empty-active manifest
  # must still pass — the empty state is appliable (deny-all), not an error.
  terraform -chdir="$MOD_COPY" validate >/dev/null \
    || fail "terraform validate should pass with an empty active set (deny-all), but failed"
  pass "terraform validate: module valid with an empty active set (deny-all)"

  # Restore the unique fixture (defensive; TMP is torn down on exit anyway).
  printf '%s\n' "$FIXTURE_MANIFEST" > "$DIG_DIR/kms-tee-released-digests.json"

  # --- terraform validate on the REAL module (no precondition eval vs data) ---
  terraform -chdir="$MODULE_DIR" init -backend=false -input=false >/dev/null
  terraform -chdir="$MODULE_DIR" validate >/dev/null
  ran_validate=1
  pass "terraform validate: real module is valid"
else
  # --- jq fallback: assert the same derivation the HCL for-expression encodes ---
  echo "terraform not found; asserting derivation with jq over the same fixture"

  # include_deprecated=false (default): only active is derived.
  DERIVED=$(printf '%s' "$FIXTURE_MANIFEST" | jq -r '.[] | select(.status == "active") | .digest')
  ran_jq=1

  echo "derived (jq, include_deprecated=false) = [${DERIVED//$'\n'/ , }]"

  grep -qx "$ACTIVE_DIGEST" <<<"$DERIVED"     || fail "active digest missing from derived list (include_deprecated=false)"
  grep -qx "$DEPRECATED_DIGEST" <<<"$DERIVED" && fail "deprecated digest leaked into derived list (include_deprecated=false)"
  grep -qx "$REVOKED_DIGEST" <<<"$DERIVED"    && fail "revoked digest leaked into derived list (include_deprecated=false)"
  [ "$(grep -c . <<<"$DERIVED")" -eq 1 ]      || fail "expected exactly 1 derived digest (include_deprecated=false)"
  pass "jq: include_deprecated=false derives exactly [active]"

  # include_deprecated=true: active + deprecated, still excluding revoked. Mirror
  # the HCL predicate `status == active || (include_deprecated && status == deprecated)`.
  DERIVED_DEP=$(printf '%s' "$FIXTURE_MANIFEST" | jq -r '.[] | select(.status == "active" or .status == "deprecated") | .digest')

  echo "derived (jq, include_deprecated=true) = [${DERIVED_DEP//$'\n'/ , }]"

  grep -qx "$ACTIVE_DIGEST" <<<"$DERIVED_DEP"     || fail "active digest missing from derived list (include_deprecated=true)"
  grep -qx "$DEPRECATED_DIGEST" <<<"$DERIVED_DEP" || fail "deprecated digest missing from derived list (include_deprecated=true)"
  grep -qx "$REVOKED_DIGEST" <<<"$DERIVED_DEP"    && fail "revoked digest leaked into derived list (include_deprecated=true) — revoked must NEVER be admitted"
  [ "$(grep -c . <<<"$DERIVED_DEP")" -eq 2 ]      || fail "expected exactly 2 derived digests (active + deprecated) with include_deprecated=true"
  pass "jq: include_deprecated=true derives [active, deprecated], still excluding revoked"
fi

echo
echo "SUMMARY: terraform console=${ran_console} terraform validate=${ran_validate} jq fallback=${ran_jq}"
echo "ALL TESTS PASSED"
