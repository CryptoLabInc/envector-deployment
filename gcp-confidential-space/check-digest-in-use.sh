#!/usr/bin/env bash
# check-digest-in-use.sh — list the kms-tee image digests currently pinned by
# running Confidential Space instances, and (optionally) assert a specific
# digest is NOT among them (i.e. it is safe to deprecate/remove from the
# release-digest allowlist).
#
# Rollout deprecation safety: before flipping a released digest from `active`
# to `deprecated` (or deleting it from the WIF allowlist), a deployer must
# prove no live workload still runs it. Confidential Space records the image
# each CVM runs in the instance's `tee-image-reference` metadata value, in the
# form <registry>/<repo>@sha256:<hex>. This script reads that value across the
# running fleet and reports the live in-use digest set.
#
# This helper is intentionally PARAMETERIZED by --project and --filter and has
# NO hard-coded project: it works for any deployer (managed or self-hosted)
# from the rollout runbook. It performs read-only gcloud calls.
#
# Usage:
#   check-digest-in-use.sh --project <id> --filter <gcloud-instance-filter>
#       Print the set of in-use @sha256:... digests (one per line), sorted.
#
#   check-digest-in-use.sh --project <id> --filter <gcloud-instance-filter> \
#       --assert-absent <digest>
#       Exit 0 IFF <digest> is NOT in the live set (removable/deprecatable),
#       non-zero if it IS live. Prints nothing on the happy path except a
#       short status line to stderr. <digest> may be given with or without the
#       leading "sha256:" prefix.
#
# Example (deprecate old digest only if no CVM runs it):
#   ./check-digest-in-use.sh --project my-proj \
#       --filter 'labels.workload=kms-tee AND status=RUNNING' \
#       --assert-absent sha256:deadbeef... && echo "safe to deprecate"
set -euo pipefail

# This script parses gcloud JSON with python3 (see below). Fail fast with a clear
# message rather than a confusing "python3: command not found" surfacing mid-run
# after the gcloud calls have already executed.
command -v python3 >/dev/null 2>&1 || {
  echo "error: python3 is required but was not found on PATH" >&2
  exit 2
}

PROJECT=""
FILTER=""
ASSERT_ABSENT=""
ASSERT_ABSENT_SET=0
MIN_LIVE=1
ALLOW_EMPTY_FLEET=0

usage() {
  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      PROJECT="${2:-}"; shift 2 ;;
    --filter)
      FILTER="${2:-}"; shift 2 ;;
    --assert-absent)
      # Distinguish "flag not given" (list mode) from "flag given with an empty
      # value". An empty value ($OLD unset/empty) must ERROR here, not fall
      # through to list mode and exit 0 — otherwise a runbook
      # `... --assert-absent "$OLD" && echo safe` would proceed WITHOUT asserting
      # absence, green-lighting deprecation of an unproven digest.
      if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
        echo "error: --assert-absent requires a non-empty digest value" >&2
        usage 2
      fi
      ASSERT_ABSENT="$2"; ASSERT_ABSENT_SET=1; shift 2 ;;
    --min-live)
      # Positive-confirmation floor for --assert-absent: minimum instances the
      # filter must match before an ABSENT result is trusted (default 1).
      MIN_LIVE="${2:-}"; shift 2 ;;
    --allow-empty-fleet)
      # Explicit opt-out of the floor: certify ABSENT even against an empty fleet
      # (only when the deployment is intentionally empty).
      ALLOW_EMPTY_FLEET=1; shift ;;
    -h|--help)
      usage 0 ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage 2 ;;
  esac
done

if [ -z "$PROJECT" ]; then
  echo "error: --project <id> is required (no project is hard-coded)" >&2
  usage 2
fi
if [ -z "$FILTER" ]; then
  echo "error: --filter <gcloud-instance-filter> is required" >&2
  usage 2
fi
if ! printf '%s' "$MIN_LIVE" | grep -qxE '[0-9]+'; then
  echo "error: --min-live must be a non-negative integer: $MIN_LIVE" >&2
  usage 2
fi

# List running Confidential Space instances matching the filter as JSON, then
# parse each instance's metadata.items[] for the `tee-image-reference` key (CS
# stores the pinned image reference there as <registry>/<repo>@sha256:<hex>).
# Parse in python3 rather than a gcloud projection: the projection `filter()`
# transform takes a single "key:value" expression, not two positional args, so
# the previous `filter("key","tee-image-reference")` was invalid and could
# silently yield an EMPTY set on a real fleet, making --assert-absent falsely
# report a still-live digest as "safe to deprecate".
raw_json="$(gcloud compute instances list \
  --project="$PROJECT" \
  --filter="$FILTER" \
  --format=json)"

# Parse the JSON with python3:
#  - Walk instances[].metadata.items[] and pick items whose key ==
#    "tee-image-reference".
#  - Extract the sha256:<64-hex> digest from each such value.
#  - FAIL-CLOSED per instance: EVERY matched instance must expose an extractable
#    tee-image-reference sha256 digest. If ANY lacks one, exit non-zero — do NOT
#    emit a partial set. A missing/malformed digest on one instance must not let
#    --assert-absent report "safe" while that unproven instance keeps running the
#    digest (a metadata-schema change, partially-migrated fleet, or truncated
#    value would otherwise silently drop it from the in-use set).
#  - An empty instance list (zero matches) is a legitimate empty in-use set.
in_use="$(printf '%s' "$raw_json" | python3 -c '
import json, re, sys

DIGEST_RE = re.compile(r"sha256:[0-9a-f]{64}")

try:
    instances = json.load(sys.stdin)
except (ValueError, json.JSONDecodeError) as exc:
    sys.stderr.write("error: could not parse gcloud --format=json output: %s\n" % exc)
    sys.exit(3)

if not isinstance(instances, list):
    sys.stderr.write("error: expected a JSON array of instances from gcloud\n")
    sys.exit(3)

digests = set()
instances_with_digest = 0
for inst in instances:
    items = ((inst or {}).get("metadata") or {}).get("items") or []
    inst_digest = None
    for item in items:
        if (item or {}).get("key") == "tee-image-reference":
            m = DIGEST_RE.search(str(item.get("value", "")))
            if m:
                inst_digest = m.group(0)
                break
    if inst_digest is not None:
        digests.add(inst_digest)
        instances_with_digest += 1

# Fail-closed: if any matched instance lacked an extractable digest, refuse to
# emit a partial in-use set (see the FAIL-CLOSED note above).
total_instances = len(instances)
if instances_with_digest < total_instances:
    missing = total_instances - instances_with_digest
    sys.stderr.write(
        "error: %d of %d instance(s) matched the filter but exposed NO "
        "extractable tee-image-reference sha256 digest; refusing to emit a "
        "partial in-use set (fail-closed to avoid falsely reporting a live "
        "digest as removable)\n" % (missing, total_instances)
    )
    sys.exit(4)

for d in sorted(digests):
    print(d)
')"

# --assert-absent mode: succeed only if the given digest is NOT live. Gated on
# the flag actually being given (ASSERT_ABSENT_SET), not on ASSERT_ABSENT being
# non-empty: an empty value already errored at parse time, so reaching here with
# the flag unset means list mode.
if [ "$ASSERT_ABSENT_SET" -eq 1 ]; then
  # Normalize: accept both "sha256:<hex>" and bare "<hex>".
  needle="$ASSERT_ABSENT"
  case "$needle" in
    sha256:*) : ;;
    *) needle="sha256:$needle" ;;
  esac

  # Validate the (normalized) needle is EXACTLY sha256:<64-lowercase-hex>. A
  # malformed value (typo, truncated hex, wrong prefix) would never match any
  # live digest and would then fall through to "ABSENT / safe to deprecate" —
  # a fail-open that could green-light removing a still-live digest. Reject it.
  if ! printf '%s' "$needle" | grep -qxE 'sha256:[0-9a-f]{64}'; then
    echo "error: --assert-absent value is not a valid sha256:<64-lowercase-hex> digest: $ASSERT_ABSENT" >&2
    exit 2
  fi

  if printf '%s\n' "$in_use" | grep -qxF "$needle"; then
    echo "IN-USE: $needle is pinned by a running instance — NOT safe to deprecate" >&2
    exit 1
  fi

  # Positive-confirmation floor. An ABSENT result is only trustworthy if the query
  # actually matched a fleet: a wrong --project/--filter or a missing label returns
  # an empty set that is INDISTINGUISHABLE from "this digest is genuinely idle", so
  # certifying ABSENT off an empty/undersized result can green-light revoking a
  # still-pinned digest — a KMS outage on the next CVM restart. Require at least
  # --min-live matched instances (default 1) unless the operator explicitly asserts
  # an intentionally-empty fleet with --allow-empty-fleet.
  matched_instances="$(printf '%s' "$raw_json" | python3 -c 'import json, sys
try:
    d = json.load(sys.stdin)
    print(len(d) if isinstance(d, list) else 0)
except Exception:
    print(0)')"
  if [ "$ALLOW_EMPTY_FLEET" -ne 1 ] && [ "${matched_instances:-0}" -lt "$MIN_LIVE" ]; then
    echo "error: only ${matched_instances:-0} instance(s) matched --filter in project $PROJECT (floor --min-live=$MIN_LIVE); refusing to certify $needle ABSENT. An empty or undersized match can mean a wrong --project/--filter or a missing label, not a genuinely idle digest — verify the filter matches your running kms-tee CVMs, or pass --allow-empty-fleet if the deployment is intentionally empty." >&2
    exit 5
  fi
  echo "ABSENT: $needle is not in the live set — safe to deprecate" >&2
  exit 0
fi

# Default (list) mode: print the in-use digest set, one digest per line.
printf '%s\n' "$in_use"
