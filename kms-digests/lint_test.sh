#!/usr/bin/env bash
#
# lint_test.sh — schema-lint the kms-tee released-digest manifest.
#
# Validates a manifest JSON file against schema.json. Prefers python3 with the
# `jsonschema` package; if that package is unavailable, falls back to a pure-
# python validator implementing exactly the schema.json constraints
# (array of objects; required {digest, release, status}; additionalProperties
# forbidden; digest matches ^sha256:[0-9a-f]{64}$; release a non-empty string;
# status in {active, deprecated, revoked}).
#
# Usage:
#   lint_test.sh [manifest.json]
#     Validate the given manifest file against schema.json. With no argument it
#     validates the manifest bundled next to this script
#     (kms-tee-released-digests.json). A self-hosted deployer who set
#     var.manifest_path to a synced copy elsewhere should pass THAT path so their
#     custom file is schema-checked — otherwise this green-lights the bundled
#     file while their file may carry schema-only errors Terraform never catches
#     (empty release, extra fields).
#
# Behaviour:
#   - validate.py <schema.json> <manifest.json> exits 0 on a valid manifest,
#     non-zero (with a message on stderr) on an invalid one.
#
# This test is self-contained: it builds the good/bad fixtures inline in temp
# files and asserts the target manifest and a valid row PASS, while a bad digest,
# a bad status, and a bad CUSTOM-path file FAIL.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA="${SCRIPT_DIR}/schema.json"
# Optional manifest-path argument; default to the file bundled next to the
# script. Whichever file is passed is the one validated by the "target manifest"
# assertion below.
MANIFEST="${1:-${SCRIPT_DIR}/kms-tee-released-digests.json}"
if [ ! -f "${MANIFEST}" ]; then
  echo "error: manifest not found: ${MANIFEST}" >&2
  echo "usage: $0 [manifest.json]" >&2
  exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# --- The validator (prefers jsonschema, pure-python fallback) --------------
VALIDATOR="${WORK}/validate.py"
cat > "${VALIDATOR}" <<'PYEOF'
import json
import re
import sys

DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
STATUS_ENUM = {"active", "deprecated", "revoked"}


def load(path):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def check_unique_digests(instance):
    """Reject a manifest carrying two rows for the SAME digest.

    schema.json validates each row independently, so a manifest with two rows
    for one digest (e.g. one `active` + one `revoked`) passes plain schema
    validation; the Terraform module only catches it later via its uniqueness
    precondition. Mirror that precondition here so the lint the promotion
    workflow and runbooks rely on rejects duplicates before publishing.

    Raises ValueError on the first digest seen more than once.
    """
    if not isinstance(instance, list):
        return  # shape errors are reported by the per-row validators
    seen = set()
    for item in instance:
        if not isinstance(item, dict):
            continue
        digest = item.get("digest")
        if not isinstance(digest, str):
            continue
        if digest in seen:
            raise ValueError(f"duplicate digest across rows: {digest!r}")
        seen.add(digest)


def check_exact_digests(instance):
    """Reject any digest that is not an EXACT sha256 image digest.

    JSON Schema's `pattern` is an unanchored search, and Python's `$` also
    matches just before a trailing newline, so jsonschema accepts
    "sha256:<64-hex>\\n" against ^sha256:[0-9a-f]{64}$ even though it is not an
    exact digest (the derived WIF condition would not admit the intended
    image). Re-check with fullmatch so the jsonschema path agrees with the
    pure-python fallback, which fullmatches inline.

    Raises ValueError on the first non-exact digest.
    """
    if not isinstance(instance, list):
        return  # shape errors are reported by the schema validator
    for i, item in enumerate(instance):
        if not isinstance(item, dict):
            continue
        digest = item.get("digest")
        if not isinstance(digest, str) or not DIGEST_RE.fullmatch(digest):
            raise ValueError(f"item[{i}].digest is not an exact sha256 digest: {digest!r}")


def validate_pure(instance):
    """Pure-python validator implementing exactly schema.json's constraints.

    Raises ValueError with a human-readable message on the first violation.
    """
    if not isinstance(instance, list):
        raise ValueError("manifest must be a JSON array")
    for i, item in enumerate(instance):
        if not isinstance(item, dict):
            raise ValueError(f"item[{i}] must be an object")
        required = {"digest", "release", "status"}
        missing = required - set(item)
        if missing:
            raise ValueError(f"item[{i}] missing required key(s): {sorted(missing)}")
        extra = set(item) - required
        if extra:  # additionalProperties: false
            raise ValueError(f"item[{i}] has disallowed key(s): {sorted(extra)}")
        digest = item["digest"]
        # fullmatch, NOT match: Python's `$` also matches just before a trailing
        # newline, so re.match would accept "sha256:<64-hex>\n" — not an exact
        # image digest, and the derived WIF condition would not admit the
        # intended image. fullmatch anchors the whole string, rejecting any
        # trailing newline or other trailing character.
        if not isinstance(digest, str) or not DIGEST_RE.fullmatch(digest):
            raise ValueError(f"item[{i}].digest is not a valid sha256 digest: {digest!r}")
        release = item["release"]
        if not isinstance(release, str) or len(release) < 1:
            raise ValueError(f"item[{i}].release must be a non-empty string: {release!r}")
        status = item["status"]
        if status not in STATUS_ENUM:
            raise ValueError(f"item[{i}].status not in {sorted(STATUS_ENUM)}: {status!r}")


def main():
    schema_path, manifest_path = sys.argv[1], sys.argv[2]
    instance = load(manifest_path)
    try:
        import jsonschema  # type: ignore
    except Exception:
        try:
            validate_pure(instance)
            check_unique_digests(instance)
        except ValueError as exc:
            print(f"INVALID (pure): {exc}", file=sys.stderr)
            return 1
        print("VALID (pure-python fallback)")
        return 0
    schema = load(schema_path)
    try:
        jsonschema.validate(instance=instance, schema=schema)
    except jsonschema.ValidationError as exc:
        print(f"INVALID (jsonschema): {exc.message}", file=sys.stderr)
        return 1
    # jsonschema's `pattern` is an unanchored, `$`-permissive search, and
    # schema.json cannot express cross-row digest uniqueness; enforce both here
    # so the jsonschema path agrees with the pure-python fallback and Terraform.
    try:
        check_exact_digests(instance)
        check_unique_digests(instance)
    except ValueError as exc:
        print(f"INVALID (jsonschema): {exc}", file=sys.stderr)
        return 1
    print("VALID (jsonschema)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYEOF

run() { python3 "${VALIDATOR}" "${SCHEMA}" "$1"; }

pass=0
fail=0

expect_pass() {
    local name="$1" file="$2"
    if run "${file}" >/dev/null 2>&1; then
        echo "PASS: ${name} (validates)"
        pass=$((pass + 1))
    else
        echo "FAIL: ${name} (expected valid, validator rejected)"
        run "${file}" || true
        fail=$((fail + 1))
    fi
}

expect_fail() {
    local name="$1" file="$2"
    if run "${file}" >/dev/null 2>&1; then
        echo "FAIL: ${name} (expected invalid, validator accepted)"
        fail=$((fail + 1))
    else
        echo "PASS: ${name} (rejected as expected)"
        pass=$((pass + 1))
    fi
}

# --- Fixtures (built inline) -----------------------------------------------
VALID_DIGEST="sha256:$(printf 'a%.0s' {1..64})"

GOOD_ROW="${WORK}/good_row.json"
cat > "${GOOD_ROW}" <<EOF
[
  { "digest": "${VALID_DIGEST}", "release": "1.5.0", "status": "active" }
]
EOF

BAD_DIGEST="${WORK}/bad_digest.json"
cat > "${BAD_DIGEST}" <<EOF
[
  { "digest": "sha256:xyz", "release": "1.5.0", "status": "active" }
]
EOF

BAD_STATUS="${WORK}/bad_status.json"
cat > "${BAD_STATUS}" <<EOF
[
  { "digest": "${VALID_DIGEST}", "release": "1.5.0", "status": "enabled" }
]
EOF

# A "custom path" file with a schema-only error Terraform never catches (empty
# release + a disallowed extra field). Stands in for a self-hosted deployer's
# var.manifest_path file that must be caught when passed explicitly.
BAD_CUSTOM="${WORK}/custom_manifest.json"
cat > "${BAD_CUSTOM}" <<EOF
[
  { "digest": "${VALID_DIGEST}", "release": "", "status": "active", "note": "x" }
]
EOF

# Two rows for the SAME digest (active + revoked). Each row is individually
# schema-valid, so plain per-row schema validation accepts it; only the
# cross-row uniqueness check (mirroring Terraform's precondition) rejects it.
DUP_DIGEST="${WORK}/dup_digest.json"
cat > "${DUP_DIGEST}" <<EOF
[
  { "digest": "${VALID_DIGEST}", "release": "1.5.0", "status": "active" },
  { "digest": "${VALID_DIGEST}", "release": "1.5.0", "status": "revoked" }
]
EOF

# A digest with a TRAILING NEWLINE embedded in the JSON string value. Both a
# bare re.match anchor and JSON Schema's `pattern` accept "sha256:<64-hex>\n"
# because `$` matches just before a trailing newline; only fullmatch (exact
# anchoring) rejects it. Built with python json.dumps so the "\n" lands inside
# the string as a real newline, not two literal characters.
NEWLINE_DIGEST="${WORK}/newline_digest.json"
python3 - "${VALID_DIGEST}" > "${NEWLINE_DIGEST}" <<'PY'
import json, sys
digest = sys.argv[1] + "\n"
print(json.dumps([{"digest": digest, "release": "1.5.0", "status": "active"}]))
PY

# --- Assertions -------------------------------------------------------------
echo "== kms-tee released-digest manifest schema lint =="
echo "-- validating target manifest: ${MANIFEST} --"
expect_pass "target manifest ${MANIFEST##*/}"    "${MANIFEST}"
expect_pass "empty array fixture"                <(printf '[]\n')
expect_pass "valid active row"                   "${GOOD_ROW}"
expect_fail "bad digest (sha256:xyz)"            "${BAD_DIGEST}"
expect_fail "bad status (enabled)"               "${BAD_STATUS}"
expect_fail "bad custom-path file (empty release + extra field)" "${BAD_CUSTOM}"
expect_fail "duplicate digest across rows (active + revoked)" "${DUP_DIGEST}"
expect_fail "digest with trailing newline (sha256:<64-hex>\\n)" "${NEWLINE_DIGEST}"

echo "== ${pass} passed, ${fail} failed =="
[ "${fail}" -eq 0 ]
