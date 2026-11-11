#!/usr/bin/env bash
# 部署端：按节点组并行执行带远端完成标记的幂等步骤。
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
require_cmd ssh
[[ $# -ge 2 && $# -le 3 ]] || die "用法：$0 <all|masters|workers> <script-name> [--parallel]"
GROUP="$1"; SCRIPT="$2"; PARALLEL="${3:-}"
[[ -z "$PARALLEL" || "$PARALLEL" == --parallel ]] || die "第三个参数仅支持 --parallel"
[[ "$SCRIPT" == "$(basename "$SCRIPT")" && "$SCRIPT" == *.sh ]] || die "非法脚本名"
case "$SCRIPT" in
  00-preflight.sh) STEP=preflight ;;
  02-install-runtime.sh) STEP=runtime ;;
  06-install-systemd.sh) STEP=systemd ;;
  07-bootstrap-etcd.sh) STEP=etcd ;;
  08-start-control-plane.sh) STEP=control-plane ;;
  09-start-worker.sh) STEP=worker ;;
  13-install-nginx-proxy.sh) STEP=nginx-proxy ;;
  *) die "不允许通过此入口执行：$SCRIPT" ;;
esac
case "$GROUP" in
  all) NODES=("${ALL_NAMES[@]}"); IPS=("${ALL_IPS[@]}") ;;
  masters) NODES=("${MASTER_NAMES[@]}"); IPS=("${MASTER_IPS[@]}") ;;
  workers) NODES=("${WORKER_NAMES[@]}"); IPS=("${WORKER_IPS[@]}") ;;
  *) die "节点组仅支持 all、masters、workers" ;;
esac
REMOTE_ROOT="/opt/kubernetes-binary-ha"
run_one() {
  local node="$1" ip="$2"
  log "执行 $STEP -> $node ($ip)"
  ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new "root@$ip" "bash '$REMOTE_ROOT/scripts/22-node-step.sh' '$SCRIPT' '$STEP'"
}
FAILED=0
if [[ "$PARALLEL" == --parallel ]]; then
  PIDS=()
  for i in "${!NODES[@]}"; do run_one "${NODES[$i]}" "${IPS[$i]}" & PIDS+=("$!"); done
  for i in "${!PIDS[@]}"; do
    if wait "${PIDS[$i]}"; then ok "${NODES[$i]} 完成"; else warn "${NODES[$i]} 失败"; FAILED=1; fi
  done
else
  for i in "${!NODES[@]}"; do
    if run_one "${NODES[$i]}" "${IPS[$i]}"; then ok "${NODES[$i]} 完成"; else warn "${NODES[$i]} 失败"; FAILED=1; break; fi
  done
fi
[[ "$FAILED" -eq 0 ]] || die "$STEP 阶段失败；已成功节点会保留标记，修复后重新执行即可跳过已完成节点。"
