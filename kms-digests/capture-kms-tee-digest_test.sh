#!/usr/bin/env bash
#
# capture-kms-tee-digest_test.sh — test for capture-kms-tee-digest.sh.
#
# Stubs `gcloud` on PATH (no real GCP calls) so the `describe` returns a fixed
# `sha256:<64-hex>` digest. Asserts both the process exit status and the STDOUT
# contract (STDOUT carries ONLY the digest, or NOTHING for a non-GA tag).
#
# Cases:
#   1. GA tag `1.2.3`               -> prints the stub digest, exit 0.
#   2. non-GA tags                  -> print NOTHING, exit 0 (no promotion):
#        - `1.2.3rc1`   (rc suffix)
#        - `v1.2.3`     (v prefix)
#        - `1.2.3-alpha.1` (hyphenated prerelease)
#        - `1.2.3dev1`  (dev suffix)
#   3. GA tag whose stub gcloud returns an EMPTY digest -> exit non-zero.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT_DIR}/capture-kms-tee-digest.sh"

# 64-hex sha256 the stub `gcloud ... describe` returns for the normal path.
STUB_DIGEST="sha256:$(printf 'a%.0s' {1..64})"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# --- Stub gcloud on PATH ----------------------------------------------------
# Emulates the exact call the script makes:
#   gcloud artifacts docker images describe <img> --format='value(image_summary.digest)'
# returning STUB_DIGEST. When the requested image tag contains the marker
# `EMPTY_DIGEST`, it returns an EMPTY string to exercise the "image not found"
# error path. Any other args are an error (so an unexpected call is caught).
BINDIR="${WORK}/bin"
mkdir -p "${BINDIR}"
cat > "${BINDIR}/gcloud" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "artifacts" ] && [ "\$2" = "docker" ] && [ "\$3" = "images" ] && [ "\$4" = "describe" ]; then
  if printf '%s\n' "\$*" | grep -qF 'EMPTY_DIGEST'; then
    printf ''            # empty digest -> image not found
  else
    printf '%s\n' "${STUB_DIGEST}"
  fi
  exit 0
fi
echo "stub gcloud: unexpected args: \$*" >&2
exit 64
STUB
chmod +x "${BINDIR}/gcloud"
export PATH="${BINDIR}:${PATH}"

pass=0
fail=0

# --- Case 1: GA tag -> prints the stub digest, exit 0 -----------------------
c_ga() {
  local out rc
  out="$("${SCRIPT}" "1.2.3" 2>/dev/null)"; rc=$?
  if [ "${rc}" -ne 0 ]; then
    echo "FAIL: GA 1.2.3 -> expected exit 0, got ${rc}"; fail=$((fail + 1)); return
  fi
  if [ "${out}" != "${STUB_DIGEST}" ]; then
    echo "FAIL: GA 1.2.3 -> STDOUT expected exactly '${STUB_DIGEST}', got '${out}'"; fail=$((fail + 1)); return
  fi
  echo "PASS: GA 1.2.3 -> prints stub digest + exit 0"; pass=$((pass + 1))
}

# --- Case 2: non-GA tag -> prints NOTHING, exit 0 ---------------------------
c_nonga() {
  local tag="$1"
  local out rc
  out="$("${SCRIPT}" "${tag}" 2>/dev/null)"; rc=$?
  if [ "${rc}" -ne 0 ]; then
    echo "FAIL: non-GA '${tag}' -> expected exit 0, got ${rc}"; fail=$((fail + 1)); return
  fi
  if [ -n "${out}" ]; then
    echo "FAIL: non-GA '${tag}' -> STDOUT expected empty, got '${out}'"; fail=$((fail + 1)); return
  fi
  echo "PASS: non-GA '${tag}' -> prints nothing + exit 0 (no promotion)"; pass=$((pass + 1))
}

# --- Case 3: GA tag, stub returns empty digest -> exit non-zero -------------
c_empty() {
  # The AR base carries the EMPTY_DIGEST marker so the stub returns "".
  local rc
  "${SCRIPT}" "1.2.3" "asia-northeast3-docker.pkg.dev/my-gcp-project/EMPTY_DIGEST/envector-kms-tee" >/dev/null 2>&1 && rc=0 || rc=$?
  if [ "${rc}" -eq 0 ]; then
    echo "FAIL: GA + empty digest -> expected non-zero exit, got 0"; fail=$((fail + 1)); return
  fi
  echo "PASS: GA + empty digest -> exit ${rc} (image not found)"; pass=$((pass + 1))
}

echo "== capture-kms-tee-digest.sh test =="
c_ga
c_nonga "1.2.3rc1"
c_nonga "v1.2.3"
c_nonga "1.2.3-alpha.1"
c_nonga "1.2.3dev1"
c_empty

echo "== ${pass} passed, ${fail} failed =="
[ "${fail}" -eq 0 ]
