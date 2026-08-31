#!/usr/bin/env bash
# numa_autopin.sh — detect host NUMA topology (+ memory bandwidth) and emit enVector
# cpuset env vars. Usage: eval "$(./numa_autopin.sh)", or start_envector.sh --numa-auto.
#
# Placement: compute = one NUMA node's physical cores (HT excluded); support/infra =
#   the other node's cores, off compute. Never spread cross-node — except dual mode,
#   which gives compute both nodes.
#
# Env knobs:
#   ENVECTOR_COMPUTE_MAX_CORES  cap compute cores (overrides the profile recommendation)
#   ENVECTOR_COMPUTE_HT=auto|on|off  local-mode HT: auto=add HT siblings iff bandwidth
#                               headroom BW(P)/BW(P/2) >= 1.20; default auto
#   ENVECTOR_WORKER_RATIO       workers = cores × ratio (default 1.0)
#   ENVECTOR_NUM_COMPUTE=N      partition the pool into N disjoint per-replica cpusets
#                               (emitted as ENVECTOR_COMPUTE_CPUSET_<n>)
#   ENVECTOR_COMPUTE_PROFILE=light|heavy  (--numa-heavy) light=single node, heavy=dual.
#                               Light/latency-sensitive queries lose on dual; heavy
#                               (high-nprobe) queries can win. A/B your own workload.
#   ENVECTOR_NUMA_QUICKPROBE=0  skip the first-run ~5s STREAM-triad bandwidth probe
# Bandwidth profile (cached per host):
#   ${ENVECTOR_NUMA_PROFILE:-~/.config/envector/numa-profile-<host>.env}
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./numa_common.sh
source "$SCRIPT_DIR/numa_common.sh"

# Worker:core ratio — precedence: explicit env > profile > default 1.0. --numa-auto isolates
# support services, so compute stays busy at workers==cores and oversubscription is pure
# overhead. Raise only for a host where other services share compute's cores. Reject
# non-numeric — awk would coerce it, often to 1.
WORKER_RATIO_ENV="${ENVECTOR_WORKER_RATIO-}"
if [[ -n "$WORKER_RATIO_ENV" && ! "$WORKER_RATIO_ENV" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "numa_autopin: ENVECTOR_WORKER_RATIO must be a positive number (e.g. 1.0, 1.3)" >&2; exit 1
fi
COMPUTE_MAX_ENV="${ENVECTOR_COMPUTE_MAX_CORES-}"
if [[ -n "$COMPUTE_MAX_ENV" && ! "$COMPUTE_MAX_ENV" =~ ^[0-9]+$ ]]; then
  echo "numa_autopin: ENVECTOR_COMPUTE_MAX_CORES must be a non-negative integer" >&2; exit 1
fi
COMPUTE_PROFILE="${ENVECTOR_COMPUTE_PROFILE-}"
if [[ -n "$COMPUTE_PROFILE" && "$COMPUTE_PROFILE" != "light" && "$COMPUTE_PROFILE" != "heavy" ]]; then
  echo "numa_autopin: ENVECTOR_COMPUTE_PROFILE must be 'light' or 'heavy'" >&2; exit 1
fi
# Number of compute replicas (start_envector.sh --num-compute N). When >1, the compute
# pool is partitioned into N disjoint per-replica cpusets so replicas don't contend.
HT_MODE="${ENVECTOR_COMPUTE_HT:-auto}"   # auto: bandwidth-gated | on: force HT | off: physical only
if [[ "$HT_MODE" != auto && "$HT_MODE" != on && "$HT_MODE" != off ]]; then
  echo "numa_autopin: ENVECTOR_COMPUTE_HT must be auto|on|off" >&2; exit 1
fi
NUM_COMPUTE="${ENVECTOR_NUM_COMPUTE:-1}"
if [[ ! "$NUM_COMPUTE" =~ ^[0-9]+$ || "$NUM_COMPUTE" -lt 1 ]]; then
  echo "numa_autopin: ENVECTOR_NUM_COMPUTE must be a positive integer" >&2; exit 1
fi

PROFILE="$(numa_profile_path)"

# --- load bandwidth profile (from a prior quickprobe) ------------------------
PROF_SRC="" PROF_MAX="" NUMA_MODE="local" BW_LOCAL="" BW_SAT="" BW_HEADROOM=""
if [[ -f "$PROFILE" ]]; then
  # shellcheck source=/dev/null
  source "$PROFILE"
  PROF_SRC="${ENVECTOR_PROFILE_SOURCE:-file}"
  PROF_MAX="${ENVECTOR_PROFILE_COMPUTE_MAX:-}"
  NUMA_MODE="${ENVECTOR_NUMA_MODE:-local}"
  BW_LOCAL="${ENVECTOR_BW_LOCAL_GBS:-}"
  BW_SAT="${ENVECTOR_BW_SAT_CORES:-}"
  BW_HEADROOM="${ENVECTOR_BW_HEADROOM:-}"
fi
if [[ -n "$WORKER_RATIO_ENV" ]]; then WORKER_RATIO="$WORKER_RATIO_ENV"
elif [[ -n "${ENVECTOR_PROFILE_WORKER_RATIO:-}" ]]; then WORKER_RATIO="$ENVECTOR_PROFILE_WORKER_RATIO"
else WORKER_RATIO=1.0; fi

# --- detect topology: node -> physical-core leaders / HT-sibling logical cpus ---
numa_detect_topology
mapfile -t NODES < <(numa_sorted_nodes)
(( ${#NODES[@]} == 0 )) && { echo "numa_autopin: no CPU topology detected (lscpu -p produced no rows)" >&2; exit 1; }

cnode=${NODES[0]}
cphys=(${NODE_PHYS[$cnode]})

# --- quickprobe: no profile → measure bandwidth saturation once (~5s, cached) ---
if [[ -z "$PROF_SRC" && "${ENVECTOR_NUMA_QUICKPROBE:-1}" != "0" ]] && command -v cc >/dev/null 2>&1; then
  QP_SRC="$SCRIPT_DIR/membw_probe.c"
  qp_ok=1
  QP_BIN="$(numa_build_probe "$QP_SRC" 2>/dev/null)" || qp_ok=0
  if (( qp_ok )); then
    echo "# numa_autopin: no profile → memory-bandwidth quickprobe (first run, ~5s)..." >&2
    P=${#cphys[@]}; qpts=(); for ((n=4;n<P;n+=4)); do qpts+=("$n"); done
    qhalf=$((P/2)); [[ " ${qpts[*]} " == *" $qhalf "* ]] || qpts+=("$qhalf"); qpts+=("$P")
    declare -A QBW; qmax=0
    for n in "${qpts[@]}"; do
      qbw=$("$QP_BIN" 0.6 64 local "${cphys[@]:0:$n}" 2>/dev/null | awk '{print $2}') || qbw=""
      [[ -z "$qbw" ]] && { QBW=(); break; }
      QBW[$n]=$qbw
      awk -v a="$qbw" -v b="$qmax" 'BEGIN{exit !(a>b)}' && qmax=$qbw
    done
    if (( ${#QBW[@]} > 0 )); then
      qsat=$P
      for n in "${qpts[@]}"; do
        if awk -v x="${QBW[$n]}" -v m="$qmax" 'BEGIN{exit !(x>=0.95*m)}'; then qsat=$n; break; fi
      done
      # Cap by the search engine's per-core bandwidth demand, NOT the STREAM
      # saturation point — that point is far below what search actually needs, so
      # capping there throws away cores: min(cores, node_bw ÷ demand).
      demand="${ENVECTOR_EVI_BW_PER_CORE:-1.0}"   # GB/s per core; conservative default
      qcap=$(awk -v bw="$qmax" -v d="$demand" -v p="$P" 'BEGIN{c=int(bw/d); print (c<p)?c:p}')
      qhr=$(awk -v a="${QBW[$P]:-0}" -v b="${QBW[$qhalf]:-0}" 'BEGIN{if(b>0)printf "%.2f",a/b; else print ""}')
      mkdir -p "${PROFILE%/*}"
      {
        echo "# enVector NUMA profile — generated by numa_autopin.sh quickprobe (host=$(hostname -s) date=$(date '+%F %T'))"
        echo "# Delete this file to re-probe, or hand-edit the values from your own measurement."
        echo "ENVECTOR_PROFILE_SOURCE=quickprobe"
        echo "ENVECTOR_BW_LOCAL_GBS=${qmax}"
        echo "ENVECTOR_BW_SAT_CORES=${qsat}"
        echo "# HT headroom = BW(${P})/BW(${qhalf}) — auto-HT threshold 1.20"
        echo "ENVECTOR_BW_HEADROOM=${qhr}"
        echo "ENVECTOR_NUMA_MODE=local"
        echo "# compute_max = min(physical cores, node bandwidth / per-core demand ${demand}GB/s) — not e2e-validated"
        echo "ENVECTOR_PROFILE_COMPUTE_MAX=${qcap}"
        for n in "${qpts[@]}"; do echo "# sweep ${n} cores: ${QBW[$n]} GB/s"; done
      } > "$PROFILE"
      PROF_SRC=quickprobe; PROF_MAX=$qcap; BW_LOCAL=$qmax; BW_SAT=$qsat; BW_HEADROOM=$qhr
      echo "# numa_autopin: saturation≈${qsat} cores (node max ${qmax} GB/s) → cached ${PROFILE}" >&2
    else
      echo "# numa_autopin: quickprobe failed → falling back to core-count defaults" >&2
    fi
  fi
fi

# --- workload profile: explicit light/heavy overrides the profile file's mode ---
if [[ "$COMPUTE_PROFILE" == "heavy" ]]; then
  if (( ${#NODES[@]} >= 2 )); then NUMA_MODE=dual
  else echo "# numa_autopin: heavy profile but a single NUMA node → proceeding local" >&2; NUMA_MODE=local; fi
elif [[ "$COMPUTE_PROFILE" == "light" ]]; then
  NUMA_MODE=local
fi

# --- select compute cores (local: one node's physical / dual: both nodes) ---
if [[ "$NUMA_MODE" == "dual" && ${#NODES[@]} -ge 2 ]]; then
  compute_cpus=(); for n in "${NODES[@]}"; do compute_cpus+=(${NODE_PHYS[$n]}); done
  ccount=${#compute_cpus[@]}
  if [[ -n "$COMPUTE_MAX_ENV" ]] && (( COMPUTE_MAX_ENV>0 && COMPUTE_MAX_ENV<ccount )); then
    ccount=$COMPUTE_MAX_ENV; compute_cpus=("${compute_cpus[@]:0:$ccount}")
  fi
  # Compute owns both nodes' physical cores, so support/infra land on the support node's
  # HT siblings. Sharing a physical core with compute is the most direct contention there
  # is — an accepted trade-off once both sockets are given to compute.
  snode=${NODES[1]}
  spool=(${NODE_HT[$snode]:-})
  sdesc="node${snode} HT siblings (dual mode)"
else
  NUMA_MODE="local"
  ccount=${#cphys[@]}
  COMPUTE_MAX=0
  if [[ -n "$COMPUTE_MAX_ENV" ]]; then COMPUTE_MAX=$COMPUTE_MAX_ENV
  elif [[ "$PROF_MAX" =~ ^[0-9]+$ ]]; then COMPUTE_MAX=$PROF_MAX; fi
  (( COMPUTE_MAX>0 && COMPUTE_MAX<ccount )) && ccount=$COMPUTE_MAX
  compute_cpus=("${cphys[@]:0:$ccount}")
  # support node: the other node if any, else the compute node's leftover physical cores
  snode=""; for n in "${NODES[@]}"; do [[ "$n" != "$cnode" ]] && { snode=$n; break; }; done
  if [[ -n "$snode" ]]; then spool=(${NODE_PHYS[$snode]}); sdesc="node$snode"
  else spool=("${cphys[@]:$ccount}"); sdesc="(single socket → compute node's leftover physical cores)"; fi
fi

# --- auto-HT (local only): add this node's HT siblings when memory bandwidth has headroom.
# HT helps a search kernel only if the physical cores don't already saturate the node's
# memory bus; gate on the quickprobe ratio BW(P)/BW(P/2). A screen only — confirm with an
# A/B of your own workload. Skipped for --num-compute>1.
nphys=$ccount; HT_ON=0; HT_WHY=""
if [[ "$NUMA_MODE" == "local" && "$HT_MODE" != "off" && -n "${NODE_HT[$cnode]:-}" && "$NUM_COMPUTE" -eq 1 ]]; then
  hts=(${NODE_HT[$cnode]})
  if [[ "$HT_MODE" == "on" ]]; then HT_ON=1; HT_WHY="forced (ENVECTOR_COMPUTE_HT=on)"
  elif [[ "$HT_MODE" == "auto" && "${BW_HEADROOM:-}" =~ ^[0-9.]+$ ]]; then
    if awk -v r="$BW_HEADROOM" 'BEGIN{exit !(r>=1.20)}'; then HT_ON=1; HT_WHY="bandwidth headroom ${BW_HEADROOM}x >= 1.20"
    else HT_WHY="no headroom (${BW_HEADROOM}x < 1.20) → physical only"; fi
  elif [[ "$HT_MODE" == "auto" ]]; then HT_WHY="no bandwidth headroom data → physical only (delete profile or set ENVECTOR_COMPUTE_HT=on)"; fi
  if (( HT_ON )); then compute_cpus+=("${hts[@]:0:$nphys}"); ccount=${#compute_cpus[@]}; fi
fi

# Partition the compute pool into N contiguous per-replica slices (compose --scale can't
# template a per-replica cpuset — start_envector applies these via docker update). The
# base ENVECTOR_COMPUTE_CPUSET stays the full pool: if the apply step is skipped,
# replicas safely fall back to sharing the whole (still NUMA-local) node.
declare -A REPLICA_CS; per_replica=$ccount
if (( NUM_COMPUTE > 1 )); then
  if (( NUM_COMPUTE > ccount )); then
    echo "# numa_autopin: --num-compute ${NUM_COMPUTE} > ${ccount} compute cores → not partitioning (replicas share the pool)" >&2
    NUM_COMPUTE=1
  else
    base=$(( ccount / NUM_COMPUTE )); rem=$(( ccount % NUM_COMPUTE )); ridx=0
    for ((r=1;r<=NUM_COMPUTE;r++)); do
      cnt=$base; (( r<=rem )) && cnt=$((base+1))
      REPLICA_CS[$r]=$(numa_compress "${compute_cpus[@]:ridx:cnt}")
      ridx=$((ridx+cnt))
    done
    per_replica=$(( (ccount + NUM_COMPUTE - 1) / NUM_COMPUTE ))   # ceil: cover the largest slice
  fi
fi

# workers scale to the per-replica core count (each replica runs its own search pool)
workers=$(awk -v c="$per_replica" -v r="$WORKER_RATIO" 'BEGIN{printf "%d",(c*r)+0.5}')
(( workers<1 )) && workers=1        # guarantee at least 1 if a bad ratio rounds to 0

# Distribute support services across the support pool.
declare -A A
total=${#spool[@]}
if (( total>0 )); then
  if (( total>=4 )); then
    # Enough cores to give each service its own slice (weights orch:be:ep:shaper=3:2:2:3).
    names=(ORCHESTRATOR BACKEND ENDPOINT SHAPER); w=(3 2 2 3); idx=0
    for i in 0 1 2 3; do
      n=$(( total*${w[$i]}/10 )); (( n<1 )) && n=1
      (( idx+n>total )) && n=$(( total-idx ))
      A[${names[$i]}]="${spool[*]:$idx:$n}"; idx=$((idx+n))
    done
    (( idx<total )) && A[SHAPER]+=" ${spool[*]:$idx}"   # leftover → shaper
  else
    # Too few cores to partition — all support services share the whole pool. They
    # overlap but stay off compute's cores (an empty cpuset would run onto compute).
    for s in ORCHESTRATOR BACKEND ENDPOINT SHAPER; do A[$s]="${spool[*]}"; done
  fi
fi

# Infra (non-compute/non-support: MinIO/metadatadb/kms etc.) shares the support pool,
# so it is fully excluded from compute's cores.
INFRA=""; (( ${#spool[@]} > 0 )) && INFRA=$(numa_compress ${spool[*]})

CS_COMPUTE=$(numa_compress ${compute_cpus[*]})
# summary (stderr) -------------------------------------------------------
{
echo "# ── numa_autopin: detection result ──"
echo "#  NUMA nodes: ${#NODES[@]}  |  compute node=node${cnode} (${#cphys[@]} physical cores), support=${sdesc}"
if [[ -n "$PROF_SRC" ]]; then
  echo "#  bandwidth profile: ${PROF_SRC} (local ${BW_LOCAL:-?} GB/s, sat≈${BW_SAT:-?} cores, mode=${NUMA_MODE})"
else
  echo "#  bandwidth profile: none (core-count based)"
fi
if [[ -n "$COMPUTE_PROFILE" ]]; then
  echo "#  workload profile: ${COMPUTE_PROFILE} (explicit) → mode=${NUMA_MODE}"
  [[ "$COMPUTE_PROFILE" == "heavy" && "$NUMA_MODE" == "dual" ]] && \
    echo "#    heavy(dual) assumes heavy queries + a compute-bound machine — A/B it against --numa-auto on your own workload"
fi
if (( HT_ON )); then echo "#  compute  cpuset=${CS_COMPUTE}  cpus=${ccount} (physical ${nphys}+HT $((ccount-nphys)))  workers=${workers}/replica  [auto-HT: ${HT_WHY}]"
else echo "#  compute  cpuset=${CS_COMPUTE}  cpus=${ccount}  workers=${workers}/replica${HT_WHY:+  [HT off: ${HT_WHY}]}"; fi
if (( NUM_COMPUTE > 1 )); then
  for ((r=1;r<=NUM_COMPUTE;r++)); do
    echo "#    replica ${r}: cpuset=${REPLICA_CS[$r]}  cpus=${per_replica}"
  done
fi
for s in ORCHESTRATOR BACKEND ENDPOINT SHAPER; do
  [[ -n "${A[$s]:-}" ]] && echo "#  $(printf '%-12s' $s) cpuset=$(numa_compress ${A[$s]})"
done
[[ -n "$INFRA" ]] && echo "#  $(printf '%-12s' INFRA) cpuset=${INFRA}  (storage/metadatadb/kms shared)"
} >&2
# export (stdout) — ENVECTOR_COMPUTE_CPUS lifts compose's cpus limit (the CFS quota
# that must be >= the cpuset size, else the cpuset is throttled).
echo "export ENVECTOR_COMPUTE_CPUSET='${CS_COMPUTE}'"
echo "export ENVECTOR_COMPUTE_CPUS='${ccount}'"
echo "export NUM_SEARCH_WORKERS='${workers}'"
# per-replica slices for --num-compute N (start_envector applies them via docker update
# after --scale). CPUS_PER_REPLICA is the per-replica CFS quota to match each slice.
if (( NUM_COMPUTE > 1 )); then
  for ((r=1;r<=NUM_COMPUTE;r++)); do
    echo "export ENVECTOR_COMPUTE_CPUSET_${r}='${REPLICA_CS[$r]}'"
  done
  echo "export ENVECTOR_COMPUTE_CPUS_PER_REPLICA='${per_replica}'"
fi
for s in ORCHESTRATOR BACKEND ENDPOINT SHAPER; do
  [[ -n "${A[$s]:-}" ]] && echo "export ENVECTOR_${s}_CPUSET='$(numa_compress ${A[$s]})'"
done
[[ -n "$INFRA" ]] && echo "export ENVECTOR_INFRA_CPUSET='${INFRA}'"
