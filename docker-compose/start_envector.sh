#!/usr/bin/env bash
set -euo pipefail

# Start/stop enVector using compose files in this directory

usage() {
  cat <<'EOF'
Usage: ./start_envector.sh [options]

Options:
  --gpu                  Include docker-compose.gpu.yml
  --env-file FILE        Env file path (default: ./.env)
  --config               Print merged docker compose config and exit
  -p, --project NAME     Compose project name (optional)
  --num-es2c N           Number of compute workers (CPU: scales es2c, GPU: enables up to N GPUs)
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

Notes:
- Relative paths for --env-file and --log-file are resolved from the current working directory (pwd), not the compose folder.
- --config prints the fully-resolved docker compose configuration and does not start containers.
EOF
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
COMPOSE_DIR="${script_dir}"
ORIG_PWD="$(pwd)"

# Defaults
GPU=false
ENV_FILE="${ORIG_PWD}/.env"
PROJECT=""
DOWN=false
DRY_RUN=false
LOG_FILE="${ORIG_PWD}/docker-logs.log"
NUM_ES2C=1
ENV_OVERRIDES=()
DOWN_VOLUMES=false
CONFIG_MODE=false

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
      # convenience: allow KEY=VAL tokens directly
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

# Normalize paths: resolve relative --env-file/--log-file against the caller's working directory
if [[ -n "${ENV_FILE:-}" && "${ENV_FILE}" != /* ]]; then
  ENV_FILE="${ORIG_PWD}/${ENV_FILE}"
fi
if [[ -n "${LOG_FILE:-}" && "${LOG_FILE}" != /* ]]; then
  LOG_FILE="${ORIG_PWD}/${LOG_FILE}"
fi

# Ensure env file exists; if missing, copy from .env.example when available
if [[ ! -f "$ENV_FILE" ]]; then
  if [[ -f "$COMPOSE_DIR/.env.example" ]]; then
    mkdir -p "$(dirname "$ENV_FILE")"
    cp "$COMPOSE_DIR/.env.example" "$ENV_FILE"
    echo "Created env file from example: $ENV_FILE"
  else
    echo "Env file not found and no .env.example available: $ENV_FILE" >&2
    exit 1
  fi
fi

# Base compose files (gpu override must come before infra)
compose_args=(
  -f docker-compose.envector.yml
)

if "$GPU"; then
  compose_args+=( -f docker-compose.gpu.yml )
fi

compose_args+=( -f docker-compose.infra.yml )

# No additional compose files beyond the standard set above

pushd "$COMPOSE_DIR" >/dev/null

cmd=( docker compose "${compose_args[@]}" --env-file "$ENV_FILE" )
if [[ -n "$PROJECT" ]]; then
  cmd+=( -p "$PROJECT" )
fi

# Apply num-es2c differently for CPU vs GPU
if "$GPU"; then
  # GPU: base es2c uses GPU0; additional GPUs are enabled via profiles gpu1..gpu3
  # Support up to 4 GPUs by default
  if "$DOWN"; then
    # When tearing down, include all known GPU profiles so all GPU containers are removed
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
  # For down, place subcommand first, then optional -v
  cmd+=( down )
  if "$DOWN_VOLUMES"; then
    cmd+=( -v )
  fi
elif "$CONFIG_MODE"; then
  # Print merged config only
  cmd+=( config )
else
  # For up, place service-specific flags like --scale after the subcommand
  cmd+=( up -d )
  if ! "$GPU" && (( NUM_ES2C > 1 )); then
    cmd+=( --scale "es2c=${NUM_ES2C}" )
  fi
fi

if "$DRY_RUN"; then
  # Show env overrides and command
  if ((${#ENV_OVERRIDES[@]})); then
    echo "Env overrides: ${ENV_OVERRIDES[*]}"
  fi
  printf 'Command: '
  printf '%q ' "${cmd[@]}"
  echo
  popd >/dev/null
  exit 0
fi

# Execute with inline env overrides in a subshell
(
  set -euo pipefail
  for kv in "${ENV_OVERRIDES[@]}"; do
    export "$kv"
  done
  "${cmd[@]}"
)

# After successful up, start background log tail (skip for down/config)
if ! "$DOWN" && ! "$CONFIG_MODE"; then
  mkdir -p "$(dirname "$LOG_FILE")"
  # Truncate log file on each start to avoid appending to old logs
  : > "$LOG_FILE"
  # Build a fresh logs command mirroring compose args and project/profiles
  log_cmd=( docker compose "${compose_args[@]}" --env-file "$ENV_FILE" )
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
  # Run logs -f in background with same env overrides
  (
    set -euo pipefail
    for kv in "${ENV_OVERRIDES[@]}"; do
      export "$kv"
    done
    "${log_cmd[@]}" logs -f >"$LOG_FILE" 2>&1 &
  )
  echo "Logging to: $LOG_FILE"
fi

popd >/dev/null
echo "Done."
