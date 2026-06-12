#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./deployment/scripts/auth/get_keycloak_token.sh [options] USERNAME [PASSWORD]

Options:
  --field NAME        Response field to print: id_token (default), access_token, refresh_token, json
  --scheme SCHEME     URL scheme: http (default) or https
  --host HOST         Keycloak host (default: localhost)
  --port PORT         Keycloak host port (default: $KEYCLOAK_HOST_PORT or 8082)
  --realm NAME        Keycloak realm (default: $KEYCLOAK_REALM or envector)
  --client-id ID      OAuth client ID (default: $KEYCLOAK_CLIENT_ID or envector-cli)
  --client-secret S   OAuth client secret (optional)
  --scopes VALUE      OAuth scopes (default: $KEYCLOAK_TOKEN_SCOPES or "openid profile email" or "openid profile email audit:read audit:export")
  --cacert PATH       CA certificate to trust for TLS
  --resolve VALUE     curl --resolve value such as keycloak.local.test:443:192.168.49.2
  --insecure          Skip TLS certificate verification (useful for local CA bootstrap)
  --timeout SECONDS   Wait timeout for Keycloak readiness (default: 30)
  -h, --help          Show this help

Examples:
  ./deployment/scripts/auth/get_keycloak_token.sh app password
  ./deployment/scripts/auth/get_keycloak_token.sh --field json ops password
  ./deployment/scripts/auth/get_keycloak_token.sh --scheme https --host keycloak.local.test --port 443 --insecure app password
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

json_backend=""
python_cmd=""

setup_json_backend() {
  if command -v jq >/dev/null 2>&1; then
    json_backend="jq"
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    json_backend="python"
    python_cmd="$(command -v python3)"
    return
  fi
  if command -v python >/dev/null 2>&1; then
    json_backend="python"
    python_cmd="$(command -v python)"
    return
  fi

  echo "Missing required command: jq or python3 or python" >&2
  exit 1
}

json_get_field() {
  local payload="$1"
  local field_name="$2"

  if [[ "$json_backend" == "jq" ]]; then
    jq -r --arg field "$field_name" '.[$field] // empty' <<<"$payload"
    return
  fi

  printf '%s' "$payload" | "$python_cmd" -c '
import json
import sys

field = sys.argv[1]
data = json.load(sys.stdin)
value = data.get(field, "")
if value is None:
    value = ""
if value != "":
    print(value)
' "$field_name"
}

format_host_for_url() {
  local value="$1"
  if [[ "$value" == *:* && "$value" != \[*\] ]]; then
    printf '[%s]\n' "$value"
    return
  fi
  printf '%s\n' "$value"
}

is_loopback_host() {
  case "$1" in
    127.0.0.1|localhost|::1)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

field="id_token"
scheme="${KEYCLOAK_SCHEME:-http}"
host="${KEYCLOAK_HOST:-localhost}"
port="${KEYCLOAK_HOST_PORT:-8082}"
realm="${KEYCLOAK_REALM:-envector}"
client_id="${KEYCLOAK_CLIENT_ID:-envector-cli}"
client_secret="${KEYCLOAK_CLIENT_SECRET:-}"
scopes="${KEYCLOAK_TOKEN_SCOPES:-openid profile email}"
timeout_seconds=30
ca_cert=""
resolve_value=""
insecure=false
forward_local_http_as_https="${KEYCLOAK_FORWARD_LOCAL_HTTP_AS_HTTPS:-true}"

while (($#)); do
  case "$1" in
    --field)
      [[ $# -ge 2 ]] || { echo "--field requires a value" >&2; exit 1; }
      field="$2"
      shift 2
      ;;
    --scheme)
      [[ $# -ge 2 ]] || { echo "--scheme requires a value" >&2; exit 1; }
      scheme="$2"
      shift 2
      ;;
    --host)
      [[ $# -ge 2 ]] || { echo "--host requires a value" >&2; exit 1; }
      host="$2"
      shift 2
      ;;
    --port)
      [[ $# -ge 2 ]] || { echo "--port requires a value" >&2; exit 1; }
      port="$2"
      shift 2
      ;;
    --realm)
      [[ $# -ge 2 ]] || { echo "--realm requires a value" >&2; exit 1; }
      realm="$2"
      shift 2
      ;;
    --client-id)
      [[ $# -ge 2 ]] || { echo "--client-id requires a value" >&2; exit 1; }
      client_id="$2"
      shift 2
      ;;
    --client-secret)
      [[ $# -ge 2 ]] || { echo "--client-secret requires a value" >&2; exit 1; }
      client_secret="$2"
      shift 2
      ;;
    --scopes)
      [[ $# -ge 2 ]] || { echo "--scopes requires a value" >&2; exit 1; }
      scopes="$2"
      shift 2
      ;;
    --cacert)
      [[ $# -ge 2 ]] || { echo "--cacert requires a value" >&2; exit 1; }
      ca_cert="$2"
      shift 2
      ;;
    --resolve)
      [[ $# -ge 2 ]] || { echo "--resolve requires a value" >&2; exit 1; }
      resolve_value="$2"
      shift 2
      ;;
    --insecure)
      insecure=true
      shift
      ;;
    --timeout)
      [[ $# -ge 2 ]] || { echo "--timeout requires a value" >&2; exit 1; }
      timeout_seconds="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

require_cmd curl
setup_json_backend

username="${1:-}"
password="${2:-password}"

if [[ -z "$username" ]]; then
  echo "USERNAME is required" >&2
  usage >&2
  exit 1
fi

case "$field" in
  id_token|access_token|refresh_token|json) ;;
  *)
    echo "--field must be one of: id_token, access_token, refresh_token, json" >&2
    exit 1
    ;;
esac

case "$scheme" in
  http|https) ;;
  *)
    echo "--scheme must be one of: http, https" >&2
    exit 1
    ;;
esac

common_curl_args=()
if "$insecure"; then
  common_curl_args+=(-k)
fi
if [[ "$scheme" == "http" ]] && [[ "$forward_local_http_as_https" == "true" ]] && is_loopback_host "$host"; then
  common_curl_args+=(-H "X-Forwarded-Proto: https")
fi
if [[ -n "$ca_cert" ]]; then
  common_curl_args+=(--cacert "$ca_cert")
fi
if [[ -n "$resolve_value" ]]; then
  common_curl_args+=(--resolve "$resolve_value")
fi

run_curl() {
  if ((${#common_curl_args[@]})); then
    curl "${common_curl_args[@]}" "$@"
    return
  fi
  curl "$@"
}

base_url="${scheme}://$(format_host_for_url "$host"):${port}"
discovery_url="${base_url}/realms/${realm}/.well-known/openid-configuration"
token_url="${base_url}/realms/${realm}/protocol/openid-connect/token"

start_time=$(date +%s)
until run_curl -fsS "$discovery_url" >/dev/null 2>&1; do
  now=$(date +%s)
  if (( now - start_time >= timeout_seconds )); then
    echo "Timed out waiting for Keycloak discovery endpoint: $discovery_url" >&2
    exit 1
  fi
  sleep 1
done

response_file="$(mktemp)"
curl_args=()
if ((${#common_curl_args[@]})); then
  curl_args+=("${common_curl_args[@]}")
fi
curl_args+=(
  -sS
  -w '%{http_code}'
  -o "$response_file"
  -X POST "$token_url"
  -H "content-type: application/x-www-form-urlencoded"
  --data-urlencode "grant_type=password"
  --data-urlencode "scope=${scopes}"
  --data-urlencode "username=${username}"
  --data-urlencode "password=${password}"
  --data-urlencode "client_id=${client_id}"
)

if [[ -n "$client_secret" ]]; then
  curl_args+=(--data-urlencode "client_secret=${client_secret}")
fi

http_status="$(curl "${curl_args[@]}")"
response="$(cat "$response_file")"
rm -f "$response_file"

if [[ "$http_status" != "200" ]]; then
  echo "Keycloak token request failed: HTTP ${http_status}" >&2
  printf '%s\n' "$response" >&2
  exit 1
fi

if [[ "$field" == "json" ]]; then
  printf '%s\n' "$response"
  exit 0
fi

token="$(json_get_field "$response" "$field")"
if [[ -z "$token" ]]; then
  echo "Keycloak response did not contain ${field}" >&2
  printf '%s\n' "$response" >&2
  exit 1
fi

printf '%s\n' "$token"
