#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${ROOT}/config/cluster.env"
[[ -f "$CONFIG" ]] || { echo "Missing $CONFIG; copy cluster.env.example first" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG"
log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }
require_root(){ [[ ${EUID} -eq 0 ]] || die "Run as root"; }
require_cmd(){ command -v "$1" >/dev/null 2>&1 || die "Required command missing: $1"; }
node_ip(){
  case "$(hostname -s)" in
    master-01) echo "$MASTER1_IP";;
    master-02) echo "$MASTER2_IP";;
    master-03) echo "$MASTER3_IP";;
    worker-01) echo "$WORKER1_IP";;
    worker-02) echo "$WORKER2_IP";;
    worker-03) echo "$WORKER3_IP";;
    *) die "Unknown hostname $(hostname -s); set hostname to the planned node name";;
  esac
}
