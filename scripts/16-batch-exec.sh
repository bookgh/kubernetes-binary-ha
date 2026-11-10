#!/usr/bin/env bash
# 在部署机执行：按节点角色批量运行远程部署脚本。
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
require_cmd ssh
[[ $# -eq 2 ]] || die "用法：$0 <all|masters|workers> <script-name>"
GROUP="$1"
SCRIPT="$2"
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
for i in "${!NODES[@]}"; do
  node="${NODES[$i]}"; ip="${IPS[$i]}"
  log "执行 $SCRIPT -> $node ($ip)"
  ssh -o BatchMode=yes "root@$ip" "bash '$REMOTE_ROOT/scripts/$SCRIPT'"
  ok "$node 执行完成"
done
