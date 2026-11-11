#!/usr/bin/env bash
# Unit tests for dynamic Master/Worker inventory derivation.
set -Eeuo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

write_inventory() {
  local dir="$1" masters="$2" workers="$3" i
  install -d "$dir/scripts" "$dir/config"
  cp "$REPO_ROOT/scripts/lib.sh" "$dir/scripts/lib.sh"
  {
    printf 'MASTER_COUNT=%s\nNODE_NAMES=(\n' "$masters"
    for ((i=1; i<=masters; i++)); do printf '  master-%02d\n' "$i"; done
    for ((i=1; i<=workers; i++)); do printf '  worker-%02d\n' "$i"; done
    printf ')\nNODE_IPS=(\n'
    for ((i=1; i<=masters; i++)); do printf '  10.10.0.%d\n' "$i"; done
    for ((i=1; i<=workers; i++)); do printf '  10.10.1.%d\n' "$i"; done
    printf ')\n'
  } > "$dir/config/cluster.env"
}

assert_topology() {
  local masters="$1" workers="$2" dir
  local last_master_var last_worker_var
  dir="$TMP/${masters}m-${workers}w"
  write_inventory "$dir" "$masters" "$workers"
  (
    source "$dir/scripts/lib.sh"
    [[ ${#MASTER_NAMES[@]} -eq "$masters" ]]
    [[ ${#MASTER_IPS[@]} -eq "$masters" ]]
    [[ ${#WORKER_NAMES[@]} -eq "$workers" ]]
    [[ ${#WORKER_IPS[@]} -eq "$workers" ]]
    [[ ${#ALL_NAMES[@]} -eq $((masters + workers)) ]]
    printf -v last_master_var 'MASTER%d_IP' "$masters"
    printf -v last_worker_var 'WORKER%d_IP' "$workers"
    [[ "${!last_master_var}" == "10.10.0.$masters" ]]
    [[ "${!last_worker_var}" == "10.10.1.$workers" ]]
    printf 'PASS: %s Master + %s Worker\n' "$masters" "$workers"
  )
}

assert_topology 1 1
assert_topology 2 2
assert_topology 3 3
assert_topology 5 2

# Reject a topology that leaves no Worker.
BAD="$TMP/invalid"
write_inventory "$BAD" 2 1
sed -i 's/^MASTER_COUNT=2$/MASTER_COUNT=3/' "$BAD/config/cluster.env"
if bash -c 'source "$1/scripts/lib.sh"' _ "$BAD" >/dev/null 2>&1; then
  echo "FAIL: accepted MASTER_COUNT equal to node count" >&2
  exit 1
fi

echo "All dynamic inventory tests passed."
