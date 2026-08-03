#!/usr/bin/env bash
#
# promote-digest_test.sh — test for promote-digest.sh.
#
# Self-contained: builds each manifest fixture in a fresh temp file (so an
# in-place append never leaks across cases) and drives promote-digest.sh with an
# EXPLICIT manifest-path argument. Asserts both the process exit status and the
# STDOUT contract (STDOUT carries ONLY `true`/`false`; nothing else).
#
# Cases:
#   1. absent digest        -> appends an `active` row + prints exactly `true`.
#   2. present + active      -> no-op + prints exactly `false` (idempotent).
#   3. present + deprecated  -> exit non-zero (non-active conflict).
#   4. present + revoked     -> exit non-zero (non-active conflict).
#   5. malformed digest (63 hex)          -> exit non-zero.
#   6. malformed digest (trailing newline) -> exit non-zero.
#   7. empty release         -> exit non-zero.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/promote-digest.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# 64-hex sha256 digests for the fixtures.
D_NEW="sha256:$(printf 'a%.0s' {1..64})"
D_EXISTING="sha256:$(printf 'b%.0s' {1..64})"
D_63HEX="sha256:$(printf 'c%.0s' {1..63})" # one hex short -> invalid

pass=0
fail=0

# Write a manifest fixture built from JSON row literals ("" for empty array).
write_manifest() {
  local path="$1"; shift
  if [ "$#" -eq 0 ]; then
    printf '[]\n' > "${path}"
  else
    { printf '['; local first=1; local row
      for row in "$@"; do
        [ "${first}" -eq 1 ] || printf ','
        printf '%s' "${row}"
        first=0
      done
      printf ']\n'
    } > "${path}"
  fi
}

# --- Case 1: absent -> appended active, STDOUT exactly "true" --------------
c1() {
  local m="${WORK}/absent.json"
  write_manifest "${m}"  # empty array: NEW is absent
  local out rc
  out="$("${SCRIPT}" "${D_NEW}" "1.5.0" "${m}" 2>/dev/null)"; rc=$?
  if [ "${rc}" -ne 0 ]; then
    echo "FAIL: absent -> expected exit 0, got ${rc}"; fail=$((fail + 1)); return
  fi
  if [ "${out}" != "true" ]; then
    echo "FAIL: absent -> STDOUT expected exactly 'true', got '${out}'"; fail=$((fail + 1)); return
  fi
  # The row must actually be appended as active.
  local n
  n="$(jq --arg d "${D_NEW}" '[.[] | select(.digest == $d and .status == "active" and .release == "1.5.0")] | length' "${m}")"
  if [ "${n}" -ne 1 ]; then
    echo "FAIL: absent -> expected exactly one appended active row, found ${n}"; fail=$((fail + 1)); return
  fi
  echo "PASS: absent digest appended as active + STDOUT 'true'"; pass=$((pass + 1))
}

# --- Case 2: present + active -> no-op, STDOUT exactly "false" --------------
c2() {
  local m="${WORK}/present_active.json"
  write_manifest "${m}" "{\"digest\":\"${D_EXISTING}\",\"release\":\"1.4.0\",\"status\":\"active\"}"
  local before; before="$(cat "${m}")"
  local out rc
  out="$("${SCRIPT}" "${D_EXISTING}" "1.4.0" "${m}" 2>/dev/null)"; rc=$?
  if [ "${rc}" -ne 0 ]; then
    echo "FAIL: present-active -> expected exit 0, got ${rc}"; fail=$((fail + 1)); return
  fi
  if [ "${out}" != "false" ]; then
    echo "FAIL: present-active -> STDOUT expected exactly 'false', got '${out}'"; fail=$((fail + 1)); return
  fi
  if [ "$(cat "${m}")" != "${before}" ]; then
    echo "FAIL: present-active -> manifest must be unchanged (no-op)"; fail=$((fail + 1)); return
  fi
  echo "PASS: present-active no-op + STDOUT 'false' + manifest unchanged"; pass=$((pass + 1))
}

# --- Cases 3 & 4: present + non-active -> exit non-zero ---------------------
c_nonactive() {
  local status="$1" label="$2"
  local m="${WORK}/present_${status}.json"
  write_manifest "${m}" "{\"digest\":\"${D_EXISTING}\",\"release\":\"1.4.0\",\"status\":\"${status}\"}"
  local before; before="$(cat "${m}")"
  local rc
  "${SCRIPT}" "${D_EXISTING}" "1.4.0" "${m}" >/dev/null 2>&1 && rc=0 || rc=$?
  if [ "${rc}" -eq 0 ]; then
    echo "FAIL: present-${status} -> expected non-zero exit (conflict), got 0"; fail=$((fail + 1)); return
  fi
  if [ "$(cat "${m}")" != "${before}" ]; then
    echo "FAIL: present-${status} -> manifest must be unchanged on conflict"; fail=$((fail + 1)); return
  fi
  echo "PASS: present-${status} conflict -> exit ${rc} (${label})"; pass=$((pass + 1))
}

# --- Cases 5-7: invalid inputs -> exit non-zero ----------------------------
expect_fail_input() {
  local name="$1"; shift  # remaining args are the promote-digest.sh args
  local m="${WORK}/invalid_input.json"
  write_manifest "${m}"  # empty array
  local rc
  "${SCRIPT}" "$@" "${m}" >/dev/null 2>&1 && rc=0 || rc=$?
  if [ "${rc}" -eq 0 ]; then
    echo "FAIL: ${name} -> expected non-zero exit, got 0"; fail=$((fail + 1)); return
  fi
  if [ "$(cat "${m}")" != "$(printf '[]\n')" ]; then
    echo "FAIL: ${name} -> manifest must be unchanged on invalid input"; fail=$((fail + 1)); return
  fi
  echo "PASS: ${name} rejected -> exit ${rc}"; pass=$((pass + 1))
}

echo "== promote-digest.sh test =="
c1
c2
c_nonactive "deprecated" "non-active released digest"
c_nonactive "revoked"    "revoked digest never silently re-admitted"
# 63-hex digest: one nibble short of the {64} quantifier.
expect_fail_input "malformed digest (63 hex)" "${D_63HEX}" "1.5.0"
# Trailing newline embedded in the digest arg: bash's `$` in the =~ anchor does
# NOT match before a trailing newline, so it must be rejected.
expect_fail_input "malformed digest (trailing newline)" "${D_NEW}"$'\n' "1.5.0"
# Empty release string.
expect_fail_input "empty release" "${D_NEW}" ""

echo "== ${pass} passed, ${fail} failed =="
[ "${fail}" -eq 0 ]
