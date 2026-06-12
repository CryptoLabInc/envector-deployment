#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./deployment/scripts/auth/seed_local_keycloak_users.sh [options]

Options:
  --scheme SCHEME     URL scheme: http (default) or https
  --host HOST           Keycloak host (default: localhost)
  --port PORT           Keycloak host port (default: $KEYCLOAK_HOST_PORT or 8082)
  --realm NAME          Target realm to seed (default: $KEYCLOAK_REALM or envector)
  --admin-user NAME     Bootstrap admin username (default: $KEYCLOAK_BOOTSTRAP_ADMIN_USERNAME or kcadmin)
  --admin-pass VALUE    Bootstrap admin password (default: $KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD or kcadmin)
  --user-password PASS  Password to assign to seeded users (default: $KEYCLOAK_LOCAL_USER_PASSWORD or password)
  --tenant-id VALUE     tenant_id attribute for seeded users (default: $KEYCLOAK_LOCAL_TENANT_ID or tenant-a)
  --cacert PATH       CA certificate to trust for TLS
  --resolve VALUE      curl --resolve value such as keycloak.local.test:443:192.168.49.2
  --insecure          Skip TLS certificate verification (useful for local CA bootstrap)
  --timeout SECONDS     Wait timeout for realm readiness (default: 60)
  -h, --help            Show this help
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

json_first_array_field() {
  local payload="$1"
  local field_name="$2"

  if [[ "$json_backend" == "jq" ]]; then
    jq -r --arg field "$field_name" '.[0][$field] // empty' <<<"$payload"
    return
  fi

  printf '%s' "$payload" | "$python_cmd" -c '
import json
import sys

field = sys.argv[1]
data = json.load(sys.stdin)
value = ""
if isinstance(data, list) and data:
    item = data[0]
    if isinstance(item, dict):
        value = item.get(field, "")
if value is None:
    value = ""
if value != "":
    print(value)
' "$field_name"
}

json_error_description_equals() {
  local payload="$1"
  local expected="$2"

  if [[ "$json_backend" == "jq" ]]; then
    jq -e --arg expected "$expected" '.error_description == $expected' <<<"$payload" >/dev/null
    return
  fi

  printf '%s' "$payload" | "$python_cmd" -c '
import json
import sys

expected = sys.argv[1]
data = json.load(sys.stdin)
sys.exit(0 if isinstance(data, dict) and data.get("error_description") == expected else 1)
' "$expected"
}

json_ensure_user_profile_attributes() {
  local payload="$1"

  if [[ "$json_backend" == "jq" ]]; then
    jq -c '
      .attributes = (.attributes // []) |
      .groups = (.groups // []) |
      .unmanagedAttributePolicy = "ENABLED" |
      if any(.attributes[]?; .name == "principal_id") then . else
        .attributes += [{
          name: "principal_id",
          displayName: "principal_id",
          permissions: {view: ["admin", "user"], edit: ["admin"]},
          multivalued: false
        }]
      end |
      if any(.attributes[]?; .name == "tenant_id") then . else
        .attributes += [{
          name: "tenant_id",
          displayName: "tenant_id",
          permissions: {view: ["admin", "user"], edit: ["admin"]},
          multivalued: false
        }]
      end
    ' <<<"$payload"
    return
  fi

  printf '%s' "$payload" | "$python_cmd" -c '
import json
import sys

data = json.load(sys.stdin)
if not isinstance(data, dict):
    data = {}

attributes = data.get("attributes")
if not isinstance(attributes, list):
    attributes = []
data["attributes"] = attributes

groups = data.get("groups")
if not isinstance(groups, list):
    groups = []
data["groups"] = groups

data["unmanagedAttributePolicy"] = "ENABLED"

def ensure_attr(name):
    for item in attributes:
        if isinstance(item, dict) and item.get("name") == name:
            return
    attributes.append({
        "name": name,
        "displayName": name,
        "permissions": {"view": ["admin", "user"], "edit": ["admin"]},
        "multivalued": False,
    })

ensure_attr("principal_id")
ensure_attr("tenant_id")

print(json.dumps(data, separators=(",", ":")))
'
}

json_role_names() {
  local payload="$1"

  if [[ "$json_backend" == "jq" ]]; then
    jq -r '.[].name' <<<"$payload"
    return
  fi

  printf '%s' "$payload" | "$python_cmd" -c '
import json
import sys

data = json.load(sys.stdin)
if not isinstance(data, list):
    sys.exit(0)
for item in data:
    if isinstance(item, dict):
        name = item.get("name")
        if name:
            print(name)
'
}

json_wrap_array() {
  local payload="$1"

  if [[ "$json_backend" == "jq" ]]; then
    jq -cs '.' <<<"$payload"
    return
  fi

  printf '%s' "$payload" | "$python_cmd" -c '
import json
import sys

data = json.load(sys.stdin)
print(json.dumps([data], separators=(",", ":")))
'
}

json_find_named_object() {
  local payload="$1"
  local name="$2"

  if [[ "$json_backend" == "jq" ]]; then
    jq -c --arg name "$name" 'map(select(.name == $name)) | .[0] // empty' <<<"$payload"
    return
  fi

  printf '%s' "$payload" | "$python_cmd" -c '
import json
import sys

target = sys.argv[1]
data = json.load(sys.stdin)
if not isinstance(data, list):
    sys.exit(0)
for item in data:
    if isinstance(item, dict) and item.get("name") == target:
        print(json.dumps(item, separators=(",", ":")))
        break
' "$name"
}

json_make_name_object() {
  local name="$1"

  if [[ "$json_backend" == "jq" ]]; then
    jq -cn --arg name "$name" '{name: $name}'
    return
  fi

  "$python_cmd" -c '
import json
import sys

print(json.dumps({"name": sys.argv[1]}, separators=(",", ":")))
' "$name"
}

json_csv_to_array() {
  local csv="$1"

  if [[ "$json_backend" == "jq" ]]; then
    jq -nc --arg csv "$csv" '($csv | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)))'
    return
  fi

  "$python_cmd" -c '
import json
import sys

values = [part.strip() for part in sys.argv[1].split(",")]
values = [value for value in values if value]
print(json.dumps(values, separators=(",", ":")))
' "$csv"
}

json_object_array_contains_name() {
  local payload="$1"
  local name="$2"

  if [[ "$json_backend" == "jq" ]]; then
    jq -e --arg name "$name" '.[] | select(.name == $name)' <<<"$payload" >/dev/null
    return
  fi

  printf '%s' "$payload" | "$python_cmd" -c '
import json
import sys

target = sys.argv[1]
data = json.load(sys.stdin)
if not isinstance(data, list):
    sys.exit(1)
found = any(isinstance(item, dict) and item.get("name") == target for item in data)
sys.exit(0 if found else 1)
' "$name"
}

json_string_array_contains() {
  local payload="$1"
  local value="$2"

  if [[ "$json_backend" == "jq" ]]; then
    jq -e --arg value "$value" '.[] | select(. == $value)' <<<"$payload" >/dev/null
    return
  fi

  printf '%s' "$payload" | "$python_cmd" -c '
import json
import sys

target = sys.argv[1]
data = json.load(sys.stdin)
if not isinstance(data, list):
    sys.exit(1)
found = any(item == target for item in data)
sys.exit(0 if found else 1)
' "$value"
}

json_string_array_lines() {
  local payload="$1"

  if [[ "$json_backend" == "jq" ]]; then
    jq -r '.[]' <<<"$payload"
    return
  fi

  printf '%s' "$payload" | "$python_cmd" -c '
import json
import sys

data = json.load(sys.stdin)
if not isinstance(data, list):
    sys.exit(0)
for item in data:
    if item is None:
        continue
    print(item)
'
}

json_make_user_payload() {
  local username="$1"
  local email="$2"
  local first_name="$3"
  local last_name="$4"
  local principal_id="$5"
  local tenant_value="$6"

  if [[ "$json_backend" == "jq" ]]; then
    jq -n \
      --arg username "$username" \
      --arg email "$email" \
      --arg first_name "$first_name" \
      --arg last_name "$last_name" \
      --arg principal_id "$principal_id" \
      --arg tenant_id "$tenant_value" \
      '{
        username: $username,
        email: $email,
        firstName: $first_name,
        lastName: $last_name,
        enabled: true,
        emailVerified: true,
        attributes: {
          principal_id: [$principal_id],
          tenant_id: [$tenant_id]
        }
      }'
    return
  fi

  "$python_cmd" -c '
import json
import sys

print(json.dumps({
    "username": sys.argv[1],
    "email": sys.argv[2],
    "firstName": sys.argv[3],
    "lastName": sys.argv[4],
    "enabled": True,
    "emailVerified": True,
    "attributes": {
        "principal_id": [sys.argv[5]],
        "tenant_id": [sys.argv[6]],
    },
}, separators=(",", ":")))
' "$username" "$email" "$first_name" "$last_name" "$principal_id" "$tenant_value"
}

json_make_password_payload() {
  local password_value="$1"

  if [[ "$json_backend" == "jq" ]]; then
    jq -n --arg value "$password_value" '{type: "password", temporary: false, value: $value}'
    return
  fi

  "$python_cmd" -c '
import json
import sys

print(json.dumps({
    "type": "password",
    "temporary": False,
    "value": sys.argv[1],
}, separators=(",", ":")))
' "$password_value"
}

json_user_attributes_match() {
  local payload="$1"
  local principal_id="$2"
  local tenant_value="$3"

  if [[ "$json_backend" == "jq" ]]; then
    jq -e \
      --arg principal_id "$principal_id" \
      --arg tenant_id "$tenant_value" \
      '
        .attributes.principal_id[0] == $principal_id and
        .attributes.tenant_id[0] == $tenant_id
      ' <<<"$payload" >/dev/null
    return
  fi

  printf '%s' "$payload" | "$python_cmd" -c '
import json
import sys

principal_id = sys.argv[1]
tenant_id = sys.argv[2]
data = json.load(sys.stdin)
attributes = data.get("attributes", {}) if isinstance(data, dict) else {}
principal_values = attributes.get("principal_id") if isinstance(attributes, dict) else None
tenant_values = attributes.get("tenant_id") if isinstance(attributes, dict) else None
matches = (
    isinstance(principal_values, list) and principal_values[:1] == [principal_id] and
    isinstance(tenant_values, list) and tenant_values[:1] == [tenant_id]
)
sys.exit(0 if matches else 1)
' "$principal_id" "$tenant_value"
}

find_docker_cmd() {
  if command -v docker >/dev/null 2>&1; then
    command -v docker
    return
  fi
  for candidate in /usr/local/bin/docker /opt/homebrew/bin/docker /Applications/Docker.app/Contents/Resources/bin/docker; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done
  return 1
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

scheme="${KEYCLOAK_SCHEME:-http}"
host="${KEYCLOAK_HOST:-localhost}"
port="${KEYCLOAK_HOST_PORT:-8082}"
realm="${KEYCLOAK_REALM:-envector}"
admin_user="${KEYCLOAK_BOOTSTRAP_ADMIN_USERNAME:-kcadmin}"
admin_pass="${KEYCLOAK_BOOTSTRAP_ADMIN_PASSWORD:-kcadmin}"
user_password="${KEYCLOAK_LOCAL_USER_PASSWORD:-password}"
tenant_id="${KEYCLOAK_LOCAL_TENANT_ID:-tenant-a}"
timeout_seconds=60
ca_cert=""
resolve_value=""
insecure=false
forward_local_http_as_https="${KEYCLOAK_FORWARD_LOCAL_HTTP_AS_HTTPS:-true}"

while (($#)); do
  case "$1" in
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
    --admin-user)
      [[ $# -ge 2 ]] || { echo "--admin-user requires a value" >&2; exit 1; }
      admin_user="$2"
      shift 2
      ;;
    --admin-pass)
      [[ $# -ge 2 ]] || { echo "--admin-pass requires a value" >&2; exit 1; }
      admin_pass="$2"
      shift 2
      ;;
    --user-password)
      [[ $# -ge 2 ]] || { echo "--user-password requires a value" >&2; exit 1; }
      user_password="$2"
      shift 2
      ;;
    --tenant-id)
      [[ $# -ge 2 ]] || { echo "--tenant-id requires a value" >&2; exit 1; }
      tenant_id="$2"
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
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      echo "Unexpected argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_cmd curl
setup_json_backend

case "$scheme" in
  http|https) ;;
  *)
    echo "--scheme must be one of: http, https" >&2
    exit 1
    ;;
esac

curl_common=(-fsS)
curl_no_fail=(-sS)
if "$insecure"; then
  curl_common+=(-k)
  curl_no_fail+=(-k)
fi
if [[ "$scheme" == "http" ]] && [[ "$forward_local_http_as_https" == "true" ]] && is_loopback_host "$host"; then
  curl_common+=(-H "X-Forwarded-Proto: https")
  curl_no_fail+=(-H "X-Forwarded-Proto: https")
fi
if [[ -n "$ca_cert" ]]; then
  curl_common+=(--cacert "$ca_cert")
  curl_no_fail+=(--cacert "$ca_cert")
fi
if [[ -n "$resolve_value" ]]; then
  curl_common+=(--resolve "$resolve_value")
  curl_no_fail+=(--resolve "$resolve_value")
fi

base_url="${scheme}://$(format_host_for_url "$host"):${port}"
realm_ready_url="${base_url}/realms/${realm}/.well-known/openid-configuration"
admin_token_url="${base_url}/realms/master/protocol/openid-connect/token"
admin_api="${base_url}/admin/realms/${realm}"

find_keycloak_container_by_port() {
  local host_port="$1"
  docker ps --format '{{.Names}}\t{{.Ports}}' | awk -F'\t' -v port="$host_port" '
    $2 ~ ("0.0.0.0:" port "->8080/tcp") || $2 ~ ("\\[::\\]:" port "->8080/tcp") { print $1; exit }
  '
}

seed_via_container_kcadm() {
  local docker_cmd
  docker_cmd="$(find_docker_cmd)" || {
    echo "Missing required command: docker" >&2
    return 1
  }

  local container
  container="$("$docker_cmd" ps --format '{{.Names}}\t{{.Ports}}' | awk -F'\t' -v host_port="$port" '
    $2 ~ ("0.0.0.0:" host_port "->8080/tcp") || $2 ~ ("\\[::\\]:" host_port "->8080/tcp") { print $1; exit }
  ')"
  if [[ -z "$container" ]]; then
    echo "Failed to locate Keycloak container bound to host port ${port}" >&2
    return 1
  fi

  "$docker_cmd" exec -i "$container" bash -s <<EOF
set -euo pipefail
KC=/opt/keycloak/bin/kcadm.sh
\$KC config credentials --server http://127.0.0.1:8080 --realm master --user "${admin_user}" --password "${admin_pass}" >/dev/null
realm="${realm}"
pw="${user_password}"
default_tenant="${tenant_id}"

lookup_user_id() {
  "\$KC" get users -r "\$realm" -q username="\$1" --fields id,username --format csv --noquotes 2>/dev/null | tail -n +2 | cut -d, -f1 | head -n1
}

ensure_realm_role() {
  local role_name="\$1"
  if ! "\$KC" get "roles/\$role_name" -r "\$realm" >/dev/null 2>&1; then
    "\$KC" create roles -r "\$realm" -s name="\$role_name" >/dev/null
  fi
}

ensure_user() {
  local username="\$1" email="\$2" first="\$3" last="\$4" principal="\$5" roles_csv="\$6" tenant="\${7:-\$default_tenant}"
  local uid
  uid="\$(lookup_user_id "\$username")"
  if [[ -z "\$uid" ]]; then
    "\$KC" create users -r "\$realm" \
      -s username="\$username" \
      -s enabled=true \
      -s email="\$email" \
      -s emailVerified=true \
      -s firstName="\$first" \
      -s lastName="\$last" \
      -s "attributes.principal_id=[\"\$principal\"]" \
      -s "attributes.tenant_id=[\"\$tenant\"]" >/dev/null 2>&1 || true
    uid="\$(lookup_user_id "\$username")"
  else
    "\$KC" update "users/\$uid" -r "\$realm" \
      -s username="\$username" \
      -s enabled=true \
      -s email="\$email" \
      -s emailVerified=true \
      -s firstName="\$first" \
      -s lastName="\$last" \
      -s "attributes.principal_id=[\"\$principal\"]" \
      -s "attributes.tenant_id=[\"\$tenant\"]" >/dev/null
  fi
  "\$KC" set-password -r "\$realm" --username "\$username" --new-password "\$pw" >/dev/null
  IFS=, read -ra roles <<< "\$roles_csv"
  for role in "\${roles[@]}"; do
    role="\$(echo "\$role" | xargs)"
    [[ -n "\$role" ]] || continue
    ensure_realm_role "\$role"
    "\$KC" add-roles -r "\$realm" --uusername "\$username" --rolename "\$role" >/dev/null
  done
}

for role in security ops app keymanager topk pubkey-reader audit-only audit-exporter; do
  ensure_realm_role "\$role"
done

ensure_user envector-admin envector-admin@example.com envector Admin envector-admin-id security
"\$KC" add-roles -r "\$realm" --uusername envector-admin --cclientid realm-management --rolename realm-admin >/dev/null || true
ensure_user security security@example.com Security Admin security-user-id security
ensure_user ops ops@example.com Ops Operator ops-user-id ops
ensure_user app app@example.com App User app-user-id app,keymanager,topk
ensure_user app-a app-a@example.com App UserA app-a-user-id app,keymanager,topk
ensure_user app-b app-b@example.com App UserB app-b-user-id app,keymanager,topk tenant-b
ensure_user keymanager keymanager@example.com Key Manager keymanager-user-id keymanager
ensure_user topk topk@example.com TopK User topk-user-id topk
ensure_user pubkey-reader pubkey-reader@example.com PubKey Reader pubkey-reader-user-id pubkey-reader
ensure_user audit-only audit-only@example.com Audit Reader audit-only-user-id audit-only
ensure_user audit-exporter audit-exporter@example.com Audit Exporter audit-exporter-user-id audit-exporter
echo "Seeded Keycloak users in realm '\$realm' using bootstrap admin '${admin_user}'."
echo "Realm admin user: envector-admin (password: \$pw)"
EOF
}

start_time=$(date +%s)
until curl "${curl_common[@]}" "$realm_ready_url" >/dev/null 2>&1; do
  now=$(date +%s)
  if (( now - start_time >= timeout_seconds )); then
    echo "Timed out waiting for Keycloak realm readiness: ${realm_ready_url}" >&2
    exit 1
  fi
  sleep 1
done

admin_token_response="$(
  curl "${curl_no_fail[@]}" \
    -X POST "$admin_token_url" \
    -H "content-type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "client_id=admin-cli" \
    --data-urlencode "username=${admin_user}" \
    --data-urlencode "password=${admin_pass}" || true
)"
admin_token="$(json_get_field "$admin_token_response" "access_token" 2>/dev/null || true)"

if [[ -z "$admin_token" ]]; then
  if json_error_description_equals "$admin_token_response" "HTTPS required" >/dev/null 2>&1; then
    seed_via_container_kcadm
    exit 0
  fi
  echo "Failed to acquire Keycloak admin token" >&2
  [[ -n "$admin_token_response" ]] && printf '%s\n' "$admin_token_response" >&2
  exit 1
fi

kc_user_profile_get() {
  curl "${curl_common[@]}" \
    -H "Authorization: Bearer ${admin_token}" \
    "${base_url}/admin/realms/${realm}/users/profile"
}

kc_user_profile_put() {
  local payload="$1"
  curl "${curl_common[@]}" -X PUT \
    -H "Authorization: Bearer ${admin_token}" \
    -H "content-type: application/json" \
    -d "$payload" \
    "${base_url}/admin/realms/${realm}/users/profile" >/dev/null
}

ensure_user_profile_attributes() {
  local current_profile updated_profile
  current_profile="$(kc_user_profile_get)"
  updated_profile="$(json_ensure_user_profile_attributes "$current_profile")"

  if [[ "$updated_profile" != "$current_profile" ]]; then
    kc_user_profile_put "$updated_profile"
  fi
}

ensure_user_profile_attributes

kc_get() {
  local path="$1"
  curl "${curl_common[@]}" -H "Authorization: Bearer ${admin_token}" "${admin_api}${path}"
}

kc_post() {
  local path="$1"
  local payload="$2"
  curl "${curl_common[@]}" -X POST \
    -H "Authorization: Bearer ${admin_token}" \
    -H "content-type: application/json" \
    -d "$payload" \
    "${admin_api}${path}" >/dev/null
}

kc_put() {
  local path="$1"
  local payload="$2"
  curl "${curl_common[@]}" -X PUT \
    -H "Authorization: Bearer ${admin_token}" \
    -H "content-type: application/json" \
    -d "$payload" \
    "${admin_api}${path}" >/dev/null
}

kc_delete_payload() {
  local path="$1"
  local payload="$2"
  curl "${curl_common[@]}" -X DELETE \
    -H "Authorization: Bearer ${admin_token}" \
    -H "content-type: application/json" \
    -d "$payload" \
    "${admin_api}${path}" >/dev/null
}

kc_delete() {
  local path="$1"
  curl "${curl_common[@]}" -X DELETE \
    -H "Authorization: Bearer ${admin_token}" \
    "${admin_api}${path}" >/dev/null
}

ensure_client_id() {
  local client_name="$1"
  local client_id

  client_id="$(json_first_array_field "$(kc_get "/clients?clientId=${client_name}")" "id")"
  if [[ -z "$client_id" ]]; then
    echo "Failed to find Keycloak client: ${client_name}" >&2
    exit 1
  fi

  printf '%s\n' "$client_id"
}

ensure_user_client_role() {
  local user_id="$1"
  local client_name="$2"
  local role_name="$3"

  local client_id
  client_id="$(ensure_client_id "$client_name")"

  local current_roles
  current_roles="$(json_role_names "$(kc_get "/users/${user_id}/role-mappings/clients/${client_id}")")"
  if grep -qx "$role_name" <<<"$current_roles"; then
    return
  fi

  local role_payload
  role_payload="$(kc_get "/clients/${client_id}/roles/${role_name}")"
  if [[ -z "$role_payload" ]]; then
    echo "Failed to find Keycloak client role: ${client_name}/${role_name}" >&2
    exit 1
  fi

  kc_post "/users/${user_id}/role-mappings/clients/${client_id}" "$(json_wrap_array "$role_payload")"
}

ensure_realm_role() {
  local role_name="$1"
  local role_payload

  role_payload="$(json_find_named_object "$(kc_get "/roles")" "$role_name")"
  if [[ -n "$role_payload" ]]; then
    printf '%s\n' "$role_payload"
    return
  fi

  kc_post "/roles" "$(json_make_name_object "$role_name")"
  role_payload="$(json_find_named_object "$(kc_get "/roles")" "$role_name")"
  if [[ -z "$role_payload" ]]; then
    echo "Failed to create Keycloak realm role: ${role_name}" >&2
    exit 1
  fi

  printf '%s\n' "$role_payload"
}

sync_envector_roles() {
  local user_id="$1"
  local desired_roles_csv="$2"

  local current_roles_json
  current_roles_json="$(kc_get "/users/${user_id}/role-mappings/realm")"

  local desired_roles_json
  desired_roles_json="$(json_csv_to_array "$desired_roles_csv")"

  local role_name
  for role_name in security ops app keymanager topk pubkey-reader audit-only audit-exporter; do
    local role_payload
    role_payload="$(ensure_realm_role "$role_name")"
    if json_object_array_contains_name "$current_roles_json" "$role_name"; then
      if ! json_string_array_contains "$desired_roles_json" "$role_name"; then
        kc_delete_payload "/users/${user_id}/role-mappings/realm" "$(json_wrap_array "$role_payload")"
      fi
    fi
  done

  current_roles_json="$(kc_get "/users/${user_id}/role-mappings/realm")"
  while IFS= read -r role_name; do
    [[ -n "$role_name" ]] || continue
    if ! json_object_array_contains_name "$current_roles_json" "$role_name"; then
      kc_post "/users/${user_id}/role-mappings/realm" "$(json_wrap_array "$(ensure_realm_role "$role_name")")"
    fi
  done < <(json_string_array_lines "$desired_roles_json")
}

ensure_user() {
  local username="$1"
  local email="$2"
  local first_name="$3"
  local last_name="$4"
  local principal_id="$5"
  local desired_roles_csv="$6"
  local user_tenant_id="${7:-$tenant_id}"

  local user_id
  user_id="$(json_first_array_field "$(kc_get "/users?username=${username}&exact=true")" "id")"

  local payload
  payload="$(json_make_user_payload "$username" "$email" "$first_name" "$last_name" "$principal_id" "$user_tenant_id")"

  if [[ -z "$user_id" ]]; then
    kc_post "/users" "$payload"
    user_id="$(json_first_array_field "$(kc_get "/users?username=${username}&exact=true")" "id")"
  else
    kc_put "/users/${user_id}" "$payload"
  fi

  if [[ -z "$user_id" ]]; then
    echo "Failed to create or update Keycloak user: ${username}" >&2
    exit 1
  fi

  kc_put "/users/${user_id}/reset-password" "$(json_make_password_payload "$user_password")"
  sync_envector_roles "$user_id" "$desired_roles_csv"

  local persisted_user
  persisted_user="$(kc_get "/users/${user_id}")"
  if ! json_user_attributes_match "$persisted_user" "$principal_id" "$user_tenant_id"; then
    echo "Failed to persist Keycloak user attributes for ${username}" >&2
    exit 1
  fi

  printf '%s\n' "$user_id"
}

ensure_realm_role security >/dev/null
ensure_realm_role ops >/dev/null
ensure_realm_role app >/dev/null
ensure_realm_role keymanager >/dev/null
ensure_realm_role topk >/dev/null
ensure_realm_role pubkey-reader >/dev/null
ensure_realm_role audit-only >/dev/null
ensure_realm_role audit-exporter >/dev/null

envector_admin_id="$(ensure_user "envector-admin" "envector-admin@example.com" "envector" "Admin" "envector-admin-id" "security")"
ensure_user_client_role "$envector_admin_id" "realm-management" "realm-admin"

ensure_user "security" "security@example.com" "Security" "Admin" "security-user-id" "security" >/dev/null
ensure_user "ops" "ops@example.com" "Ops" "Operator" "ops-user-id" "ops" >/dev/null
ensure_user "app" "app@example.com" "App" "User" "app-user-id" "app,keymanager,topk" >/dev/null
ensure_user "app-a" "app-a@example.com" "App" "UserA" "app-a-user-id" "app,keymanager,topk" >/dev/null
ensure_user "app-b" "app-b@example.com" "App" "UserB" "app-b-user-id" "app,keymanager,topk" "tenant-b" >/dev/null
ensure_user "keymanager" "keymanager@example.com" "Key" "Manager" "keymanager-user-id" "keymanager" >/dev/null
ensure_user "topk" "topk@example.com" "TopK" "User" "topk-user-id" "topk" >/dev/null
ensure_user "pubkey-reader" "pubkey-reader@example.com" "PubKey" "Reader" "pubkey-reader-user-id" "pubkey-reader" >/dev/null
ensure_user "audit-only" "audit-only@example.com" "Audit" "Reader" "audit-only-user-id" "audit-only" >/dev/null
ensure_user "audit-exporter" "audit-exporter@example.com" "Audit" "Exporter" "audit-exporter-user-id" "audit-exporter" >/dev/null

echo "Seeded Keycloak users in realm '${realm}' using bootstrap admin '${admin_user}'."
echo "Realm admin user: envector-admin (password: ${user_password})"
