#!/usr/bin/env bash
# 在部署机执行：将本地脚本及运行依赖复制到远程临时目录后执行。
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
require_cmd ssh
require_cmd scp
[[ $# -ge 2 ]] || die "用法：$0 <all|masters|workers> <scripts/script-name.sh> [--parallel]"

GROUP="$1"
SCRIPT_ARG="$2"
shift 2
PARALLEL=""
for arg in "$@"; do
  case "$arg" in
    --parallel) [[ -z "$PARALLEL" ]] || die "--parallel 不能重复"; PARALLEL=1 ;;
    *) die "不支持的参数：$arg（仅支持 --parallel）" ;;
  esac
done

# 只允许仓库 scripts/ 目录中的脚本，避免路径穿越。
[[ "$SCRIPT_ARG" == scripts/*.sh && "$SCRIPT_ARG" != *"/../"* && "$SCRIPT_ARG" != ../* ]] \
  || die "脚本参数必须是仓库根目录下 scripts/ 目录中的相对 .sh 路径，例如 scripts/02-install-runtime.sh"
SCRIPT_REL="$SCRIPT_ARG"
LOCAL_SCRIPT="$ROOT/$SCRIPT_REL"
LOCAL_LIB="$ROOT/scripts/lib.sh"
LOCAL_CONFIG="$ROOT/config/cluster.env"
[[ -f "$LOCAL_SCRIPT" ]] || die "本地不存在脚本：$LOCAL_SCRIPT"
[[ -f "$LOCAL_LIB" ]] || die "本地缺少脚本依赖：$LOCAL_LIB"
[[ -f "$LOCAL_CONFIG" ]] || die "本地缺少配置文件：$LOCAL_CONFIG"

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

# 每次执行使用独立临时目录，避免并行任务互相覆盖。
REMOTE_TMP="/tmp/kubernetes-binary-ha-$(basename "$SCRIPT_REL" .sh)-$$"

run_node() {
  local node="$1" ip="$2" remote_cmd
  log "创建远程临时目录并复制脚本、lib.sh 和 cluster.env -> $node ($ip)"
  ssh_remote "$ip" "mkdir -p '$REMOTE_TMP/scripts' '$REMOTE_TMP/config'"
  scp -P "$SSH_PORT" -o BatchMode=yes \
    "$LOCAL_SCRIPT" "$LOCAL_LIB" "$SSH_USER@$ip:$REMOTE_TMP/scripts/"
  scp -P "$SSH_PORT" -o BatchMode=yes \
    "$LOCAL_CONFIG" "$SSH_USER@$ip:$REMOTE_TMP/config/cluster.env"

  # 通过临时目录中的脚本执行；无论成功或失败都清理临时目录，并保留脚本退出码。
  remote_cmd="set +e; bash '$REMOTE_TMP/$SCRIPT_REL'; rc=\$?; rm -rf '$REMOTE_TMP'; exit \$rc"
  ssh_remote "$ip" "$remote_cmd"
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
