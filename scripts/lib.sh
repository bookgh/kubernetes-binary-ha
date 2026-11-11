#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${ROOT}/config/cluster.env"
if [[ ! -f "$CONFIG" ]]; then
  printf '\033[1;31m[错误]\033[0m 缺少配置文件：%s；请先复制 cluster.env.example 并完成配置。\n' "$CONFIG" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG"
# SSH 和 Release 下载参数统一从 cluster.env 读取。
SSH_USER="${SSH_USER:-root}"
SSH_PORT="${SSH_PORT:-22}"
SSH_PASSWORD="${SSH_PASSWORD:-}"
GITHUB_REPOSITORY_URL="${GITHUB_REPOSITORY_URL:-}"
GITHUB_RELEASE_BASE_URL="${GITHUB_RELEASE_BASE_URL:-}"

[[ "$SSH_USER" =~ ^[a-z_][a-zA-Z0-9_.-]*[$]?$ ]] || {
  printf '[错误] SSH_USER 格式无效。\n' >&2
  exit 1
}
[[ "$SSH_PORT" =~ ^[1-9][0-9]{0,4}$ ]] && (( SSH_PORT <= 65535 )) || {
  printf '[错误] SSH_PORT 必须是 1-65535 之间的端口。\n' >&2
  exit 1
}

ssh_remote() {
  local ip="$1"
  local command="$2"
  local quoted

  if [[ "$SSH_USER" == root ]]; then
    ssh -p "$SSH_PORT" -o BatchMode=yes "$SSH_USER@$ip" "$command"
  else
    printf -v quoted '%q' "$command"
    ssh -p "$SSH_PORT" -o BatchMode=yes "$SSH_USER@$ip" "sudo -n bash -c $quoted"
  fi
}

# 统一日志格式；非交互终端和 NO_COLOR 环境下不输出颜色控制符。
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'; C_INFO=$'\033[1;36m'; C_OK=$'\033[1;32m'
  C_WARN=$'\033[1;33m'; C_ERROR=$'\033[1;31m'
else
  C_RESET=''; C_INFO=''; C_OK=''; C_WARN=''; C_ERROR=''
fi
log()  { printf '%s[%s 信息]%s %s\n' "$C_INFO" "$(date '+%F %T')" "$C_RESET" "$*"; }
ok()   { printf '%s[%s 成功]%s %s\n' "$C_OK" "$(date '+%F %T')" "$C_RESET" "$*"; }
warn() { printf '%s[%s 警告]%s %s\n' "$C_WARN" "$(date '+%F %T')" "$C_RESET" "$*" >&2; }
die()  { printf '%s[%s 错误]%s %s\n' "$C_ERROR" "$(date '+%F %T')" "$C_RESET" "$*" >&2; exit 1; }
require_root() { [[ ${EUID} -eq 0 ]] || die '请使用 root 用户运行此脚本。'; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "缺少必要命令：$1"; }
derive_inventory() {
  local names_decl ips_decl i j octet n master_count total ip
  local -a octets

  names_decl="$(declare -p NODE_NAMES 2>/dev/null || true)"
  ips_decl="$(declare -p NODE_IPS 2>/dev/null || true)"
  [[ "$names_decl" == "declare -a NODE_NAMES="* ]] || die "配置缺少 NODE_NAMES 索引数组，请按 config/cluster.env.example 更新节点清单"
  [[ "$ips_decl" == "declare -a NODE_IPS="* ]] || die "配置缺少 NODE_IPS 索引数组，请按 config/cluster.env.example 更新节点清单"
  [[ "${MASTER_COUNT:-}" =~ ^(0|[1-9][0-9]*)$ ]] || die "MASTER_COUNT 必须设置为正整数"
  master_count=$((10#$MASTER_COUNT))
  total=${#NODE_NAMES[@]}
  (( master_count >= 1 )) || die "MASTER_COUNT 至少为 1"
  (( total >= 2 )) || die "NODE_NAMES/NODE_IPS 至少必须包含一个 Master 和一个 Worker"
  (( master_count < total )) || die "MASTER_COUNT 必须小于节点总数，至少保留一个 Worker"
  (( ${#NODE_IPS[@]} == total )) || die "NODE_NAMES 与 NODE_IPS 数量不一致"

  for i in "${!NODE_NAMES[@]}"; do
    [[ -n "${NODE_NAMES[$i]}" ]] || die "NODE_NAMES[$i] 不能为空"
    [[ "${NODE_NAMES[$i]}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || die "无效节点主机名：${NODE_NAMES[$i]}"
    [[ -n "${NODE_IPS[$i]}" ]] || die "NODE_IPS[$i] 不能为空"

    IFS='.' read -r -a octets <<< "${NODE_IPS[$i]}"
    [[ ${#octets[@]} -eq 4 ]] || die "无效 IPv4 地址：${NODE_IPS[$i]}"
    for octet in "${octets[@]}"; do
      [[ "$octet" =~ ^(0|[1-9][0-9]{0,2})$ ]] || die "无效 IPv4 地址：${NODE_IPS[$i]}"
      (( 10#$octet <= 255 )) || die "无效 IPv4 地址：${NODE_IPS[$i]}"
    done

    for ((j=0; j<i; j++)); do
      [[ "${NODE_NAMES[$i]}" != "${NODE_NAMES[$j]}" ]] || die "节点主机名重复：${NODE_NAMES[$i]}"
      [[ "${NODE_IPS[$i]}" != "${NODE_IPS[$j]}" ]] || die "节点 IP 重复：${NODE_IPS[$i]}"
    done
    if (( i < master_count )); then
      [[ "${NODE_NAMES[$i]}" == master-* ]] || die "NODE_NAMES 前 MASTER_COUNT 项必须使用 master-* 主机名"
    else
      [[ "${NODE_NAMES[$i]}" == worker-* ]] || die "NODE_NAMES 从 MASTER_COUNT 开始的其余项必须使用 worker-* 主机名"
    fi
  done

  MASTER_NAMES=("${NODE_NAMES[@]:0:master_count}")
  : "${HARBOR_NODE_IP:=${NODE_IPS[0]}}"
  : "${HARBOR_HOST:=harbor.${HARBOR_NODE_IP}.nip.io}"
  : "${HARBOR_URL:=http://${HARBOR_HOST}}"
  : "${HARBOR_HTTP_PORT:=80}"
  local harbor_ip_found=0
  for ip in "${NODE_IPS[@]}"; do
    [[ "$ip" == "$HARBOR_NODE_IP" ]] && harbor_ip_found=1
  done
  (( harbor_ip_found == 1 )) || die "HARBOR_NODE_IP 必须属于 NODE_IPS 节点清单"
  [[ "$HARBOR_HOST" == "harbor.${HARBOR_NODE_IP}.nip.io" ]] ||
    die "HARBOR_HOST 必须为 harbor.${HARBOR_NODE_IP}.nip.io"
  [[ "$HARBOR_URL" == "http://${HARBOR_HOST}" ]] ||
    die "当前 HTTP 模式下 HARBOR_URL 必须为 http://${HARBOR_HOST}"

  MASTER_IPS=("${NODE_IPS[@]:0:master_count}")
  WORKER_NAMES=("${NODE_NAMES[@]:master_count}")
  WORKER_IPS=("${NODE_IPS[@]:master_count}")
  ALL_NAMES=("${NODE_NAMES[@]}")
  ALL_IPS=("${NODE_IPS[@]}")

  # 为旧配置消费者保留按序号派生的标量；动态逻辑必须使用数组。
  for i in "${!MASTER_IPS[@]}"; do
    n=$((i + 1))
    printf -v "MASTER${n}_IP" '%s' "${MASTER_IPS[$i]}"
    export "MASTER${n}_IP"
  done
  for i in "${!WORKER_IPS[@]}"; do
    n=$((i + 1))
    printf -v "WORKER${n}_IP" '%s' "${WORKER_IPS[$i]}"
    export "WORKER${n}_IP"
  done
}
validate_inventory() {
  [[ ${#MASTER_NAMES[@]} -eq "$MASTER_COUNT" && ${#MASTER_IPS[@]} -eq "$MASTER_COUNT" ]] || die "Master 节点派生数量与 MASTER_COUNT 不一致"
  [[ ${#WORKER_NAMES[@]} -ge 1 && ${#WORKER_NAMES[@]} -eq ${#WORKER_IPS[@]} ]] || die "Worker 节点清单至少需要一个名称和 IP"
  [[ ${#ALL_NAMES[@]} -eq ${#NODE_NAMES[@]} && ${#ALL_IPS[@]} -eq ${#NODE_IPS[@]} ]] || die "ALL_NAMES/ALL_IPS 派生数量异常"
  if (( MASTER_COUNT == 1 )); then
    warn "MASTER_COUNT=1：etcd 为单成员部署，不具备成员故障容忍能力。"
  elif (( MASTER_COUNT % 2 == 0 )); then
    warn "MASTER_COUNT=$MASTER_COUNT 为偶数：etcd 需要多数派，任意单成员故障都可能导致失去 quorum；生产环境通常建议奇数成员。"
  fi
}
derive_inventory
validate_inventory

node_ip() {
  local current
  current="$(hostname -s)"
  for i in "${!ALL_NAMES[@]}"; do
    if [[ "${ALL_NAMES[$i]}" == "$current" ]]; then
      printf '%s\n' "${ALL_IPS[$i]}"
      return 0
    fi
  done
  die "无法识别当前主机名：$current，请检查 config/cluster.env 中的节点清单。"
}
