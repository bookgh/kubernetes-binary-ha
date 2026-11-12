#!/usr/bin/env bash
# 在部署机执行：按节点角色批量运行远程部署脚本。
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
require_cmd ssh
[[ $# -ge 2 ]] || die "用法：$0 <all|masters|workers> <scripts/script-name.sh> [--parallel] [--copy]"

GROUP="$1"
SCRIPT_ARG="$2"
shift 2
PARALLEL=""
COPY_MODE=0
for arg in "$@"; do
  case "$arg" in
    --parallel) [[ -z "$PARALLEL" ]] || die "--parallel 不能重复"; PARALLEL=1 ;;
    --copy) [[ "$COPY_MODE" -eq 0 ]] || die "--copy 不能重复"; COPY_MODE=1 ;;
    *) die "不支持的参数：$arg（仅支持 --parallel、--copy）" ;;
  esac
done

# 始终从仓库根目录解析脚本路径，调用时推荐传 scripts/xxx.sh。
[[ "$SCRIPT_ARG" == scripts/*.sh && "$SCRIPT_ARG" != *"/../"* && "$SCRIPT_ARG" != ../* ]] \
  || die "脚本参数必须是仓库根目录下 scripts/ 目录中的相对 .sh 路径，例如 scripts/02-install-runtime.sh"
SCRIPT_REL="$SCRIPT_ARG"
LOCAL_SCRIPT="$ROOT/$SCRIPT_REL"
[[ -f "$LOCAL_SCRIPT" ]] || die "本地不存在脚本：$LOCAL_SCRIPT"
SCRIPT_NAME="$(basename "$SCRIPT_REL")"
[[ "$COPY_MODE" -eq 0 ]] || require_cmd scp

case "$GROUP" in
  all)
    NODES=("${ALL_NAMES[@]}")
    IPS=("${ALL_IPS[@]}")
    ;;
  masters)
    NODES=("${MASTER_NAMES[@]}")
    IPS=("${MASTER_IPS[@]}")
    ;;
  workers)
    NODES=("${WORKER_NAMES[@]}")
    IPS=("${WORKER_IPS[@]}")
    ;;
  *) die "节点组仅支持 all、masters、workers" ;;
esac

REMOTE_ROOT="/opt/kubernetes-binary-ha"
REMOTE_SCRIPT="$REMOTE_ROOT/$SCRIPT_REL"
REMOTE_TMP="/tmp/kubernetes-binary-ha-$SCRIPT_NAME"

run_node() {
  local node="$1" ip="$2"
  if [[ "$COPY_MODE" -eq 1 ]]; then
    log "先 SCP 更新脚本 $SCRIPT_REL -> $node ($ip)"
    scp -P "$SSH_PORT" -o BatchMode=yes "$LOCAL_SCRIPT" "$SSH_USER@$ip:$REMOTE_TMP"
    ssh_remote "$ip" "install -m 0755 '$REMOTE_TMP' '$REMOTE_SCRIPT' && rm -f '$REMOTE_TMP' && cd '$REMOTE_ROOT' && bash '$REMOTE_SCRIPT'"
  else
    # 默认方式：通过 SSH 直接调用已分发到远端仓库目录的脚本，不再传输脚本文件。
    ssh_remote "$ip" "cd '$REMOTE_ROOT' && bash '$REMOTE_SCRIPT'"
  fi
}

if [[ -n "$PARALLEL" ]]; then
  PIDS=()
  FAILED=0
  for i in "${!NODES[@]}"; do
    node="${NODES[$i]}"; ip="${IPS[$i]}"
    log "并行执行 $SCRIPT_REL -> $node ($ip)"
    run_node "$node" "$ip" &
    PIDS+=("$!")
  done
  for i in "${!PIDS[@]}"; do
    if wait "${PIDS[$i]}"; then ok "${NODES[$i]} 执行完成"; else warn "${NODES[$i]} 执行失败"; FAILED=1; fi
  done
  [[ "$FAILED" -eq 0 ]] || die "批量执行存在失败节点，请检查对应节点日志。"
else
  for i in "${!NODES[@]}"; do
    node="${NODES[$i]}"; ip="${IPS[$i]}"
    log "执行 $SCRIPT_REL -> $node ($ip)"
    run_node "$node" "$ip"
    ok "$node 执行完成"
  done
fi
