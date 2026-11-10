#!/usr/bin/env bash
# 在部署机执行：按节点角色批量运行远程部署脚本。
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
require_cmd ssh
[[ $# -ge 2 && $# -le 3 ]] || die "用法：$0 <all|masters|workers> <script-name> [--parallel]"
GROUP="$1"
SCRIPT="$2"
PARALLEL="${3:-}"
[[ -z "$PARALLEL" || "$PARALLEL" == --parallel ]] || die "第三个参数仅支持 --parallel"
[[ "$SCRIPT" == "$(basename "$SCRIPT")" && "$SCRIPT" == *.sh ]] || die "脚本参数必须是 scripts/ 下的 .sh 文件名"
[[ -f "$ROOT/scripts/$SCRIPT" ]] || die "本地不存在脚本：$ROOT/scripts/$SCRIPT"
case "$GROUP" in
  all)
    NODES=(master-01 master-02 master-03 worker-01 worker-02 worker-03)
    IPS=("$MASTER1_IP" "$MASTER2_IP" "$MASTER3_IP" "$WORKER1_IP" "$WORKER2_IP" "$WORKER3_IP")
    ;;
  masters)
    NODES=(master-01 master-02 master-03)
    IPS=("$MASTER1_IP" "$MASTER2_IP" "$MASTER3_IP")
    ;;
  workers)
    NODES=(worker-01 worker-02 worker-03)
    IPS=("$WORKER1_IP" "$WORKER2_IP" "$WORKER3_IP")
    ;;
  *) die "节点组仅支持 all、masters、workers" ;;
esac
REMOTE_ROOT="/opt/kubernetes-binary-ha"
if [[ "$PARALLEL" == --parallel ]]; then
  PIDS=()
  FAILED=0
  for i in "${!NODES[@]}"; do
    node="${NODES[$i]}"; ip="${IPS[$i]}"
    log "并行执行 $SCRIPT -> $node ($ip)"
    ssh -o BatchMode=yes "root@$ip" "bash '$REMOTE_ROOT/scripts/$SCRIPT'" &
    PIDS+=("$!")
  done
  for i in "${!PIDS[@]}"; do
    if wait "${PIDS[$i]}"; then ok "${NODES[$i]} 执行完成"; else warn "${NODES[$i]} 执行失败"; FAILED=1; fi
  done
  [[ "$FAILED" -eq 0 ]] || die "批量执行存在失败节点，请检查对应节点日志。"
else
  for i in "${!NODES[@]}"; do
    node="${NODES[$i]}"; ip="${IPS[$i]}"
    log "执行 $SCRIPT -> $node ($ip)"
    ssh -o BatchMode=yes "root@$ip" "bash '$REMOTE_ROOT/scripts/$SCRIPT'"
    ok "$node 执行完成"
  done
fi
