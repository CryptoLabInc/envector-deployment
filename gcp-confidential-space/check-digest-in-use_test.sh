#!/usr/bin/env bash
# Test for check-digest-in-use.sh.
#
# Stubs `gcloud` on PATH so no real GCP calls are made. The stub emulates
# `gcloud compute instances list ... --format=...` returning two running
# Confidential Space instances whose `tee-image-reference` metadata pins the
# kms-tee image at @sha256:AAA and @sha256:BBB respectively.
#
# Assertions:
#   1. The script prints the in-use digest set {AAA, BBB}.
#   2. `--assert-absent <CCC>` (a digest NOT in the set) exits 0 (removable).
#   3. `--assert-absent <AAA>` (a digest IN the set)     exits non-zero (live).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/check-digest-in-use.sh"

# Digests the mocked fleet has pinned (must match the stub below).
AAA="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
BBB="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
CCC="sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# --- Stub gcloud on PATH ----------------------------------------------------
# The stub emulates the exact call the script makes:
#   gcloud compute instances list --project=<P> --filter=<F> --format=json
# returning a realistic instances array where each instance carries a
# metadata.items[] list including the `tee-image-reference` key. This exercises
# the script's REAL json parse (walk metadata.items[], match key, extract the
# sha256 digest) rather than feeding it a pre-extracted digest line.
#
# It records its args so the test can assert the script passes --project /
# --filter through and does NOT hard-code a project.
BINDIR="$WORKDIR/bin"
mkdir -p "$BINDIR"
cat > "$BINDIR/gcloud" <<STUB
#!/usr/bin/env bash
# Record invocation for later assertions.
printf '%s\n' "\$*" >> "$WORKDIR/gcloud_args.log"

# Only emulate: compute instances list ... --format=json
if [ "\$1" = "compute" ] && [ "\$2" = "instances" ] && [ "\$3" = "list" ]; then
  # A mixed fleet (one valid tee-image-reference + one matched instance that
  # exposes NO tee-image-reference digest) is selected by a marker in the
  # --filter, so the fail-closed-per-instance path can be exercised distinctly.
  if printf '%s\n' "\$*" | grep -qF 'MIXED_FLEET'; then
    cat <<'JSON'
[
  {
    "name": "kms-tee-cvm-1",
    "status": "RUNNING",
    "metadata": {
      "items": [
        { "key": "tee-image-reference", "value": "asia-northeast3-docker.pkg.dev/my-gcp-project/envector/envector-kms-tee@${AAA}" }
      ]
    }
  },
  {
    "name": "kms-tee-cvm-missing",
    "status": "RUNNING",
    "metadata": {
      "items": [
        { "key": "enable-oslogin", "value": "TRUE" }
      ]
    }
  }
]
JSON
    exit 0
  fi

  # An empty fleet (zero matched instances) is selected by a marker in the
  # --filter, to exercise the positive-confirmation floor for --assert-absent.
  if printf '%s\n' "\$*" | grep -qF 'EMPTY_FLEET'; then
    printf '[]\n'
    exit 0
  fi

  # Two running CS instances. Each has a realistic metadata.items[] array with
  # several keys; the tee-image-reference value embeds the pinned image digest
  # as <registry>/<repo>@sha256:<hex>. The script must find the right key and
  # extract the sha256 digest from the value itself.
  cat <<'JSON'
[
  {
    "name": "kms-tee-cvm-1",
    "status": "RUNNING",
    "metadata": {
      "items": [
        { "key": "enable-oslogin", "value": "TRUE" },
        { "key": "tee-image-reference", "value": "asia-northeast3-docker.pkg.dev/my-gcp-project/envector/envector-kms-tee@${AAA}" },
        { "key": "tee-container-log-redirect", "value": "cloud_logging" }
      ]
    }
  },
  {
    "name": "kms-tee-cvm-2",
    "status": "RUNNING",
    "metadata": {
      "items": [
        { "key": "tee-image-reference", "value": "asia-northeast3-docker.pkg.dev/my-gcp-project/envector/envector-kms-tee@${BBB}" }
      ]
    }
  }
]
JSON
  exit 0
fi

echo "stub gcloud: unexpected args: \$*" >&2
exit 64
STUB
chmod +x "$BINDIR/gcloud"
export PATH="$BINDIR:$PATH"

PROJECT="test-deployer-project"
FILTER="labels.workload=kms-tee AND status=RUNNING"

fail() { echo "FAIL: $1" >&2; exit 1; }

# --- Assertion 1: prints the in-use set {AAA, BBB} --------------------------
OUT="$("$SCRIPT" --project "$PROJECT" --filter "$FILTER")"
echo "--- script output (list mode) ---"
echo "$OUT"
echo "----------------------------------"

echo "$OUT" | grep -qF "$AAA" || fail "expected AAA ($AAA) in in-use set"
echo "$OUT" | grep -qF "$BBB" || fail "expected BBB ($BBB) in in-use set"
# CCC must NOT appear — it is not pinned by any live instance.
if echo "$OUT" | grep -qF "$CCC"; then fail "CCC leaked into in-use set"; fi

# The set should contain exactly two digests.
COUNT="$(echo "$OUT" | grep -c 'sha256:' || true)"
[ "$COUNT" -eq 2 ] || fail "expected exactly 2 in-use digests, got $COUNT"

# --- Assertion (project passthrough): no hard-coded project -----------------
grep -qF "project=$PROJECT" "$WORKDIR/gcloud_args.log" \
  || fail "script did not pass --project=$PROJECT to gcloud"
grep -qF "$FILTER" "$WORKDIR/gcloud_args.log" \
  || fail "script did not pass the --filter through to gcloud"

# --- Assertion 2: --assert-absent CCC (not in set) exits 0 ------------------
if "$SCRIPT" --project "$PROJECT" --filter "$FILTER" --assert-absent "$CCC"; then
  echo "assert-absent CCC -> exit 0 (removable) OK"
else
  fail "--assert-absent CCC should exit 0 (digest not live), but exited non-zero"
fi

# Also accept a bare digest (no sha256: prefix) for --assert-absent.
if "$SCRIPT" --project "$PROJECT" --filter "$FILTER" --assert-absent "${CCC#sha256:}"; then
  echo "assert-absent bare-CCC -> exit 0 OK"
else
  fail "--assert-absent bare CCC should exit 0"
fi

# --- Assertion 3: --assert-absent AAA (in set) exits non-zero ---------------
if "$SCRIPT" --project "$PROJECT" --filter "$FILTER" --assert-absent "$AAA"; then
  fail "--assert-absent AAA should exit non-zero (digest still live), but exited 0"
else
  echo "assert-absent AAA -> non-zero (still live) OK"
fi

# --- Assertion 4: malformed --assert-absent value is rejected ---------------
# A 63-hex digest (one short of 64) must ERROR, NOT fall through to
# "ABSENT / safe to deprecate". Fail-open here could green-light removing a
# still-live digest that was mistyped.
SHORT="sha256:$(printf 'a%.0s' {1..63})"  # 63 hex chars — too short
if "$SCRIPT" --project "$PROJECT" --filter "$FILTER" --assert-absent "$SHORT"; then
  fail "--assert-absent with a 63-hex (malformed) digest should exit non-zero, but exited 0"
else
  echo "assert-absent malformed(63-hex) -> non-zero (rejected) OK"
fi

# --- Assertion 4b: explicitly-empty --assert-absent value is rejected --------
# A caller passing `--assert-absent "$OLD"` with OLD empty/unset must ERROR, NOT
# fall through to list mode and exit 0 — a runbook `... --assert-absent "$OLD" &&
# echo safe` would otherwise proceed WITHOUT asserting absence.
if "$SCRIPT" --project "$PROJECT" --filter "$FILTER" --assert-absent "" >/dev/null 2>&1; then
  fail "--assert-absent with an empty value should exit non-zero, but exited 0"
else
  echo "assert-absent empty-value -> non-zero (rejected) OK"
fi

# The flag given with NO value at all (end of args) must likewise ERROR, not
# silently become list mode.
if "$SCRIPT" --project "$PROJECT" --filter "$FILTER" --assert-absent >/dev/null 2>&1; then
  fail "--assert-absent with no value should exit non-zero, but exited 0"
else
  echo "assert-absent no-value -> non-zero (rejected) OK"
fi

# --- Assertion 5: mixed fleet (one instance lacks a digest) fails closed -----
# A matched fleet where one instance exposes a valid tee-image-reference and
# ANOTHER matched instance exposes none must exit non-zero, NOT emit the partial
# {AAA} set. Otherwise --assert-absent for the missing instance's (unknown)
# digest would falsely report "safe to deprecate" while it keeps running.
MIXED_FILTER="labels.workload=kms-tee AND status=RUNNING AND MIXED_FLEET"

# List mode: must fail (no partial set).
if MIXED_OUT="$("$SCRIPT" --project "$PROJECT" --filter "$MIXED_FILTER" 2>/dev/null)"; then
  fail "mixed fleet (one instance without a digest) should exit non-zero in list mode, but exited 0 with: $MIXED_OUT"
else
  echo "mixed-fleet list mode -> non-zero (fail-closed) OK"
fi

# --assert-absent mode: the missing instance means we cannot prove absence, so
# even asserting a digest not in the partial set must fail closed (not report
# "safe to deprecate").
if "$SCRIPT" --project "$PROJECT" --filter "$MIXED_FILTER" --assert-absent "$CCC" >/dev/null 2>&1; then
  fail "mixed fleet --assert-absent should fail closed, but exited 0"
else
  echo "mixed-fleet --assert-absent -> non-zero (fail-closed) OK"
fi

# --- Assertion 6: empty fleet + --assert-absent hits the positive floor -------
# A query that matches ZERO instances (wrong --project/--filter, missing label)
# is indistinguishable from "digest genuinely idle", so --assert-absent must NOT
# certify "safe to deprecate" off an empty fleet — it must error (fail-open closed).
EMPTY_FILTER="labels.workload=kms-tee AND status=RUNNING AND EMPTY_FLEET"
if "$SCRIPT" --project "$PROJECT" --filter "$EMPTY_FILTER" --assert-absent "$CCC" >/dev/null 2>&1; then
  fail "--assert-absent against an empty fleet should exit non-zero (positive-confirmation floor), but exited 0"
else
  echo "empty-fleet --assert-absent -> non-zero (floor blocks fail-open) OK"
fi

# --allow-empty-fleet is the explicit opt-out for an intentionally-empty deployment.
if "$SCRIPT" --project "$PROJECT" --filter "$EMPTY_FILTER" --assert-absent "$CCC" --allow-empty-fleet; then
  echo "empty-fleet --assert-absent --allow-empty-fleet -> exit 0 OK"
else
  fail "--allow-empty-fleet should let an empty-fleet --assert-absent succeed, but it exited non-zero"
fi

echo "PASS: check-digest-in-use.sh"
