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
  local names_decl ips_decl i j octet n
  local -a octets

  names_decl="$(declare -p NODE_NAMES 2>/dev/null || true)"
  ips_decl="$(declare -p NODE_IPS 2>/dev/null || true)"
  [[ "$names_decl" == "declare -a NODE_NAMES="* ]] || die "配置缺少 NODE_NAMES 索引数组，请按 config/cluster.env.example 更新节点清单"
  [[ "$ips_decl" == "declare -a NODE_IPS="* ]] || die "配置缺少 NODE_IPS 索引数组，请按 config/cluster.env.example 更新节点清单"
  [[ "${MASTER_COUNT:-}" =~ ^[0-9]+$ ]] || die "MASTER_COUNT 必须设置为整数 3"
  [[ "$MASTER_COUNT" -eq 3 ]] || die "当前项目仅支持 MASTER_COUNT=3（三 Master + 三 Worker）"
  [[ ${#NODE_NAMES[@]} -eq 6 ]] || die "NODE_NAMES 必须恰好包含 6 个节点"
  [[ ${#NODE_IPS[@]} -eq 6 ]] || die "NODE_IPS 必须恰好包含 6 个 IP"
  [[ ${#NODE_NAMES[@]} -eq ${#NODE_IPS[@]} ]] || die "NODE_NAMES 与 NODE_IPS 数量不一致"

  for i in "${!NODE_NAMES[@]}"; do
    [[ -n "${NODE_NAMES[$i]}" ]] || die "NODE_NAMES[$i] 不能为空"
    [[ "${NODE_NAMES[$i]}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || die "无效节点主机名：${NODE_NAMES[$i]}"
    [[ -n "${NODE_IPS[$i]}" ]] || die "NODE_IPS[$i] 不能为空"

    IFS='.' read -r -a octets <<< "${NODE_IPS[$i]}"
    [[ ${#octets[@]} -eq 4 ]] || die "无效 IPv4 地址：${NODE_IPS[$i]}"
    for octet in "${octets[@]}"; do
      [[ "$octet" =~ ^[0-9]{1,3}$ ]] || die "无效 IPv4 地址：${NODE_IPS[$i]}"
      (( 10#$octet <= 255 )) || die "无效 IPv4 地址：${NODE_IPS[$i]}"
    done

    for ((j=0; j<i; j++)); do
      [[ "${NODE_NAMES[$i]}" != "${NODE_NAMES[$j]}" ]] || die "节点主机名重复：${NODE_NAMES[$i]}"
      [[ "${NODE_IPS[$i]}" != "${NODE_IPS[$j]}" ]] || die "节点 IP 重复：${NODE_IPS[$i]}"
    done
  done

  for i in 0 1 2; do
    [[ "${NODE_NAMES[$i]}" == master-* ]] || die "NODE_NAMES 前三个节点必须使用 master-* 主机名"
  done
  for i in 3 4 5; do
    [[ "${NODE_NAMES[$i]}" == worker-* ]] || die "NODE_NAMES 后三个节点必须使用 worker-* 主机名"
  done

  MASTER_NAMES=("${NODE_NAMES[@]:0:MASTER_COUNT}")
  MASTER_IPS=("${NODE_IPS[@]:0:MASTER_COUNT}")
  WORKER_NAMES=("${NODE_NAMES[@]:MASTER_COUNT}")
  WORKER_IPS=("${NODE_IPS[@]:MASTER_COUNT}")
  ALL_NAMES=("${NODE_NAMES[@]}")
  ALL_IPS=("${NODE_IPS[@]}")

  # 兼容现有脚本、NGINX 模板及远端 cluster.env 的标量变量引用。
  for i in 0 1 2; do
    n=$((i + 1))
    printf -v "MASTER${n}_IP" '%s' "${MASTER_IPS[$i]}"
    printf -v "WORKER${n}_IP" '%s' "${WORKER_IPS[$i]}"
    export "MASTER${n}_IP" "WORKER${n}_IP"
  done
}
validate_inventory() {
  [[ ${#MASTER_NAMES[@]} -eq 3 && ${#MASTER_IPS[@]} -eq 3 ]] || die "Master 节点清单必须为 3 个名称和 3 个 IP"
  [[ ${#WORKER_NAMES[@]} -eq 3 && ${#WORKER_IPS[@]} -eq 3 ]] || die "Worker 节点清单必须为 3 个名称和 3 个 IP"
  [[ ${#ALL_NAMES[@]} -eq 6 && ${#ALL_IPS[@]} -eq 6 ]] || die "ALL_NAMES/ALL_IPS 必须各包含 6 个节点"
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
