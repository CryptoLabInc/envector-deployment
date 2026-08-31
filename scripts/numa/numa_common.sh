#!/usr/bin/env bash
# numa_common.sh — shared helpers for the numa placement scripts.
#
# Sourced, not executed. Provides NUMA topology detection, cpuset range compression, the
# per-host profile path, the memory-bandwidth probe binary (host-tagged build), and
# running-compute detection, so a topology/dedup change lands in one place.

# numa_profile_path — echo the per-host NUMA profile file path. Keyed by hostname so a
# shared HOME (NFS) keeps per-machine profiles separate.
numa_profile_path() {
  echo "${ENVECTOR_NUMA_PROFILE:-${XDG_CONFIG_HOME:-$HOME/.config}/envector/numa-profile-$(hostname -s).env}"
}

# numa_detect_topology — from `lscpu -p`, populate globals NODE_PHYS[node] (physical-core
# leader CPUs) and NODE_HT[node] (HT-sibling CPUs). The dedup key includes the socket
# because CORE ids repeat per socket (else numa=off / multi-socket nodes lose cores).
numa_detect_topology() {
  declare -gA NODE_PHYS=() NODE_HT=()
  local -A _seen=()
  local cpu core sock node _ k
  while IFS=, read -r cpu core sock node _; do
    [[ "$cpu" =~ ^# ]] && continue
    [[ -z "$node" ]] && node=0        # NUMA disabled (numa=off) leaves NODE empty → one node
    k="$node:$sock:$core"
    if [[ -z "${_seen[$k]:-}" ]]; then _seen[$k]=1; NODE_PHYS[$node]+="$cpu "
    else NODE_HT[$node]+="$cpu "; fi
  done < <(lscpu -p=CPU,CORE,SOCKET,NODE)
}

# numa_sorted_nodes — echo NUMA node ids, most-physical-cores first (one per line).
# Requires numa_detect_topology to have run.
numa_sorted_nodes() {
  local n
  for n in "${!NODE_PHYS[@]}"; do echo "$(echo ${NODE_PHYS[$n]} | wc -w) $n"; done \
    | sort -rn | awk '{print $2}'
}

# numa_compress INT... — encode integers as a cpuset range string, e.g. "0-3,5"
# (fork-free range encoder).
numa_compress() {
  local a; a=($(printf '%s\n' "$@" | sort -n)); local out="" s="" p="" x
  for x in "${a[@]}"; do
    if [[ -z "$s" ]]; then s=$x; p=$x
    elif (( x==p+1 )); then p=$x
    elif [[ $s != $p ]]; then out+="${s}-${p},"; s=$x; p=$x
    else out+="${s},"; s=$x; p=$x; fi
  done
  if [[ -n "$s" ]]; then
    if [[ $s != $p ]]; then out+="${s}-${p}"; else out+="${s}"; fi
  fi
  echo "$out"
}

# numa_probe_bin — host-tagged probe binary path. Tagged by hostname because the probe is
# `-march=native`, so a binary built on a newer CPU SIGILLs on an older one (shared NFS HOME).
numa_probe_bin() {
  echo "$HOME/.cache/envector/membw_probe-$(hostname -s)"
}

# numa_build_probe SRC — build the probe binary from SRC if missing/stale; echo its
# path on success, return non-zero on failure. cc's own stderr is left intact so a
# caller that wants it silent can redirect at the call site.
numa_build_probe() {
  local src=$1 bin
  bin="$(numa_probe_bin)"
  [[ -f "$src" ]] || { echo "numa_build_probe: source not found: $src" >&2; return 1; }
  if [[ ! -x "$bin" || "$src" -nt "$bin" ]]; then
    mkdir -p "${bin%/*}"
    cc -O3 -march=native -pthread -o "$bin" "$src" || return 1
  fi
  echo "$bin"
}

# numa_compute_container — running compute container name (or empty). Matches the service
# suffix prefix-agnostically; $USER guessing broke under non-default compose project names.
numa_compute_container() {
  docker ps --format '{{.Names}}' 2>/dev/null \
    | grep -E -- '-envector-compute-[0-9]+$' | head -1
}
