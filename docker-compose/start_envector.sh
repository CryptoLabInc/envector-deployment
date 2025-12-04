#!/usr/bin/env bash
set -euo pipefail

# Allow the script to be customized by other wrappers (e.g., ./scripts/start_envector.sh)
ENABLE_PREFLIGHTS=${START_ENVECTOR_ENABLE_PREFLIGHTS:-true}
REQUIRE_LICENSE=${START_ENVECTOR_REQUIRE_LICENSE:-true}
CHECK_DOCKERHUB=${START_ENVECTOR_CHECK_DOCKERHUB:-true}
PROMPT_VERSION=${START_ENVECTOR_PROMPT_VERSION:-true}
EXTRA_COMPOSE_FILES="${START_ENVECTOR_EXTRA_COMPOSE_FILES:-}"

usage() {
  cat <<'USAGE'
Usage: ./start_envector.sh [options]

Options:
  --gpu                  Include docker-compose.gpu.yml
  --env-file FILE        Env file path (default: pwd/.env or override)
  --config               Print merged docker compose config and exit
  -p, --project NAME     Compose project name (optional)
  --num-es2c N           Number of compute workers (CPU: scales es2c, GPU: enables up to N GPUs)
  --num-es2o N           Number of orchestrator
  --set KEY=VAL          Inline env override (repeatable). You can also pass KEY=VAL directly.
  --down                 Stop and remove the stack (default action is up -d)
  --down-volumes         When used with --down, also remove named/anonymous volumes (-v)
  --log-file PATH        Write compose logs to PATH after up -d (default: ./docker-logs.log)
  --dry-run              Print the final command without executing
  -h, --help             Show this help and exit

Examples (run from this directory):
  ./start_envector.sh --gpu --set ES2E_HOST_PORT=50055 --set VERSION_TAG=dev
  ./start_envector.sh --num-es2c 4
  ./start_envector.sh --down
  ./start_envector.sh --config
USAGE
  if "$ENABLE_PREFLIGHTS"; then
    cat <<'USAGE'
Notes:
- Preflight checks verify Docker, Docker Hub access (cryptolabinc), and presence of ./token.jwt.
USAGE
  fi
  cat <<'USAGE'
- Relative paths for --env-file and --log-file are resolved from your current working directory (pwd).
- --config prints the fully-resolved docker compose configuration and does not start containers.
USAGE
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
COMPOSE_DIR="${START_ENVECTOR_COMPOSE_DIR:-$script_dir}"
REPO_ROOT="${START_ENVECTOR_REPO_ROOT:-$(cd "${script_dir}/../.." && pwd)}"
ORIG_PWD="$(pwd)"
PROJECT_DIR="${START_ENVECTOR_PROJECT_DIR:-}"

DEFAULT_ENV_FILE="${START_ENVECTOR_DEFAULT_ENV_FILE:-${ORIG_PWD}/.env}"
LOG_FILE="${START_ENVECTOR_DEFAULT_LOG_FILE:-${ORIG_PWD}/docker-logs.log}"
ENV_FILE="$DEFAULT_ENV_FILE"

ENV_EXAMPLE_SOURCE="${START_ENVECTOR_ENV_EXAMPLE_SOURCE:-${COMPOSE_DIR}/.env.example}"
if [[ -n "$ENV_EXAMPLE_SOURCE" && "$ENV_EXAMPLE_SOURCE" != /* ]]; then
  ENV_EXAMPLE_SOURCE="${REPO_ROOT}/${ENV_EXAMPLE_SOURCE}"
fi

GPU=false
PROJECT=""
DOWN=false
DRY_RUN=false
NUM_ES2C=1
NUM_ES2O=1
ENV_OVERRIDES=()
DOWN_VOLUMES=false
CONFIG_MODE=false
USE_ENV_FILE=true

has_inline_version=false
chosen_version=""

# --- Preflight helpers ---
require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker not found. Please install Docker: https://docs.docker.com/get-docker/" >&2
    exit 1
  fi
  if ! docker info >/dev/null 2>&1; then
    echo "Docker daemon is not reachable. Start Docker or fix permissions (e.g., add your user to the 'docker' group)." >&2
    exit 1
  fi
}

require_docker_compose_v2() {
  if docker compose version >/dev/null 2>&1; then
    return 0
  fi
  echo "Docker Compose v2 (the 'docker compose' CLI) is required. Install the Compose plugin: https://docs.docker.com/compose/install/" >&2
  exit 1
}

ensure_license() {
  local token_path="${COMPOSE_DIR}/token.jwt"
  if ! "$REQUIRE_LICENSE"; then
    return 0
  fi
  if [[ -f "${token_path}" ]]; then
    return 0
  fi
  echo "License file not found at Docker-mounted path: ${token_path}"
  read -rp "Enter path to your ES2 license token.jwt: " src
  if [[ -z "${src}" || ! -f "${src}" ]]; then
    echo "License file not found: ${src:-<empty>}" >&2
    exit 1
  fi
  local src_abs
  src_abs=$(readlink -f "$src" 2>/dev/null || true)
  local dst_abs
  dst_abs=$(readlink -f "${COMPOSE_DIR}" 2>/dev/null || echo "${COMPOSE_DIR}")/token.jwt
  cp "${src}" "${token_path}"
  if [[ -n "$src_abs" ]]; then
    echo "Copied license from: ${src_abs}"
  else
    echo "Copied license from: ${src}"
  fi
  echo "                to: ${dst_abs}"
}

prompt_version_if_needed() {
  if "$has_inline_version" || ! "$PROMPT_VERSION"; then
    return 0
  fi
  local default_tag="${VERSION_TAG:-latest}"
  local input
  read -rp "enVector version tag [${default_tag}]: " input || true
  if [[ -z "${input}" ]]; then
    chosen_version="${default_tag}"
  else
    chosen_version="${input}"
  fi
}

check_or_login_dockerhub() {
  if ! "$CHECK_DOCKERHUB"; then
    return 0
  fi
  local tag_for_check=${1:-latest}
  local image="cryptolabinc/es2e:${tag_for_check}"
  echo "Checking Docker Hub access for ${image} ... (this may take a few seconds)"
  if docker manifest inspect "${image}" >/dev/null 2>&1; then
    echo "Docker Hub access succeeded."
    return 0
  fi
  local pat="${DOCKERHUB_PAT:-}"
  echo "Access to enVector Images requires Docker Hub login."
  if [[ -z "${pat}" ]]; then
    echo "Enter a Docker Hub Personal Access Token (PAT) for user 'cltrial'."
    read -rsp "PAT: " pat
    echo
  fi
  if ! echo "${pat}" | docker login -u cltrial --password-stdin >/dev/null; then
    echo "Docker login failed. Please verify your PAT and try again." >&2
    exit 1
  fi
  echo "Rechecking access for ${image} ..."
  if ! docker manifest inspect "${image}" >/dev/null 2>&1; then
    echo "Cannot access ${image}. Check your PAT and network connectivity." >&2
    exit 1
  fi
  echo "Docker Hub access succeeded."
}

while (($#)); do
  case "$1" in
    --gpu)
      GPU=true; shift ;;
    --env-file)
      [[ $# -ge 2 ]] || { echo "--env-file requires a value" >&2; exit 1; }
      ENV_FILE="$2"; shift 2 ;;
    --config)
      CONFIG_MODE=true; shift ;;
    -p|--project)
      [[ $# -ge 2 ]] || { echo "--project requires a value" >&2; exit 1; }
      PROJECT="$2"; shift 2 ;;
    --num-es2c)
      [[ $# -ge 2 ]] || { echo "--num-es2c requires a number" >&2; exit 1; }
      if ! [[ "$2" =~ ^[0-9]+$ ]]; then
        echo "--num-es2c must be an integer" >&2; exit 1;
      fi
      NUM_ES2C="$2"; shift 2 ;;
    --num-es2o)
      [[ $# -ge 2 ]] || { echo "--num-es2o requires a number" >&2; exit 1; }
      if ! [[ "$2" =~ ^[0-9]+$ ]]; then
        echo "--num-es2o must be an integer" >&2; exit 1;
      fi
      NUM_ES2O="$2"; shift 2 ;;
    --set)
      [[ $# -ge 2 ]] || { echo "--set requires KEY=VAL" >&2; exit 1; }
      ENV_OVERRIDES+=("$2"); shift 2 ;;
    --down)
      DOWN=true; shift ;;
    --down-volumes)
      DOWN_VOLUMES=true; shift ;;
    --dry-run)
      DRY_RUN=true; shift ;;
    --log-file)
      [[ $# -ge 2 ]] || { echo "--log-file requires a path" >&2; exit 1; }
      LOG_FILE="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *=*)
      ENV_OVERRIDES+=("$1"); shift ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1 ;;
  esac
done

if [[ ! -d "$COMPOSE_DIR" ]]; then
  echo "Compose directory not found: $COMPOSE_DIR" >&2
  exit 1
fi

if [[ -n "${ENV_FILE:-}" && "${ENV_FILE}" != /* ]]; then
  ENV_FILE="${ORIG_PWD}/${ENV_FILE}"
fi
if [[ -n "${LOG_FILE:-}" && "${LOG_FILE}" != /* ]]; then
  LOG_FILE="${ORIG_PWD}/${LOG_FILE}"
fi

if ! "$DOWN"; then
  if [[ ! -f "$ENV_FILE" ]]; then
    if [[ -n "$ENV_EXAMPLE_SOURCE" && -f "$ENV_EXAMPLE_SOURCE" ]]; then
      mkdir -p "$(dirname "$ENV_FILE")"
      cp "$ENV_EXAMPLE_SOURCE" "$ENV_FILE"
      echo "Created env file from example: $ENV_FILE"
    else
      echo "Env file not found and no .env.example available: $ENV_FILE" >&2
      exit 1
    fi
  fi
else
  if [[ ! -f "$ENV_FILE" ]]; then
    USE_ENV_FILE=false
  fi
fi

if ((${#ENV_OVERRIDES[@]})); then
  for kv in "${ENV_OVERRIDES[@]}"; do
    if [[ "$kv" == VERSION_TAG=* ]]; then
      has_inline_version=true
      chosen_version="${kv#VERSION_TAG=}"
      break
    fi
  done
fi

if ! "$DOWN" && ! "$CONFIG_MODE" && ! "$DRY_RUN" && "$ENABLE_PREFLIGHTS"; then
  require_docker
  require_docker_compose_v2
  probe_tag="${chosen_version:-${VERSION_TAG:-latest}}"
  check_or_login_dockerhub "${probe_tag}"
  ensure_license
  prompt_version_if_needed
  if ! "$has_inline_version" && [[ -n "$chosen_version" ]]; then
    ENV_OVERRIDES+=("VERSION_TAG=${chosen_version}")
  fi
fi

compose_args=(
  -f "${COMPOSE_DIR}/docker-compose.envector.yml"
)

if "$GPU"; then
  compose_args+=( -f "${COMPOSE_DIR}/docker-compose.gpu.yml" )
fi

if "$DOWN"; then
  case " ${compose_args[*]} " in
    *" ${COMPOSE_DIR}/docker-compose.gpu.yml "*) : ;;
    *) compose_args+=( -f "${COMPOSE_DIR}/docker-compose.gpu.yml" ) ;;
  esac
fi

compose_args+=( -f "${COMPOSE_DIR}/docker-compose.infra.yml" )

if [[ -n "$EXTRA_COMPOSE_FILES" ]]; then
  while IFS= read -r extra_file; do
    [[ -z "$extra_file" ]] && continue
    compose_args+=( -f "$extra_file" )
  done <<< "$EXTRA_COMPOSE_FILES"
fi

pushd "$COMPOSE_DIR" >/dev/null

cmd=( docker compose "${compose_args[@]}" )
if "$USE_ENV_FILE"; then
  cmd+=( --env-file "$ENV_FILE" )
fi
if [[ -n "$PROJECT_DIR" ]]; then
  cmd+=( --project-directory "$PROJECT_DIR" )
fi
if [[ -n "$PROJECT" ]]; then
  cmd+=( -p "$PROJECT" )
fi

if "$GPU"; then
  if "$DOWN"; then
    for i in 1 2 3; do
      cmd+=( --profile "gpu${i}" )
    done
  else
    if (( NUM_ES2C > 1 )); then
      max_extra=$(( NUM_ES2C - 1 ))
      if (( max_extra > 3 )); then
        echo "Requested --num-es2c=$NUM_ES2C exceeds default GPU services (max 4). Enabling 4. Update compose files to extend." >&2
        max_extra=3
      fi
      for i in $(seq 1 "$max_extra"); do
        cmd+=( --profile "gpu${i}" )
      done
    fi
  fi
fi

if "$DOWN"; then
  for i in 1 2 3; do
    cmd+=( --profile "gpu${i}" )
  done
  cmd+=( down )
  if "$DOWN_VOLUMES"; then
    cmd+=( -v )
  fi
elif "$CONFIG_MODE"; then
  cmd+=( config )
else
  cmd+=( up -d )
  if ! "$GPU" && (( NUM_ES2C > 1 )); then
    cmd+=( --scale "es2c=${NUM_ES2C}" )
  fi
  if (( NUM_ES2O > 1 )); then
    cmd+=( --scale "es2o=${NUM_ES2O}" )
  fi
fi

if "$DRY_RUN"; then
  if ((${#ENV_OVERRIDES[@]})); then
    echo "Env overrides: ${ENV_OVERRIDES[*]}"
  fi
  printf 'Command: '
  printf '%q ' "${cmd[@]}"
  echo
  popd >/dev/null
  exit 0
fi

(
  set -euo pipefail
  if ((${#ENV_OVERRIDES[@]})); then
    for kv in "${ENV_OVERRIDES[@]}"; do
      export "$kv"
    done
  fi
  "${cmd[@]}"
)

if ! "$DOWN" && ! "$CONFIG_MODE"; then
  mkdir -p "$(dirname "$LOG_FILE")"
  : > "$LOG_FILE"
  log_cmd=( docker compose "${compose_args[@]}" )
  if "$USE_ENV_FILE"; then
    log_cmd+=( --env-file "$ENV_FILE" )
  fi
  if [[ -n "$PROJECT_DIR" ]]; then
    log_cmd+=( --project-directory "$PROJECT_DIR" )
  fi
  if [[ -n "$PROJECT" ]]; then
    log_cmd+=( -p "$PROJECT" )
  fi
  if "$GPU" && (( NUM_ES2C > 1 )); then
    max_extra=$(( NUM_ES2C - 1 ))
    (( max_extra > 3 )) && max_extra=3
    for i in $(seq 1 "$max_extra"); do
      log_cmd+=( --profile "gpu${i}" )
    done
  fi
  (
    set -euo pipefail
    if ((${#ENV_OVERRIDES[@]})); then
      for kv in "${ENV_OVERRIDES[@]}"; do
        export "$kv"
      done
    fi
    "${log_cmd[@]}" logs -f >"$LOG_FILE" 2>&1 &
  )
  echo "Logging to: $LOG_FILE"
fi

popd >/dev/null
echo "Done."
