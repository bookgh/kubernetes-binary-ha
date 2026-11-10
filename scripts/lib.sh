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
node_ip() {
  local current
  current="$(hostname -s)"
  for i in "${!ALL_NAMES[@]}"; do
    if [[ "${ALL_NAMES[$i]}" == "$current" ]]; then
      printf '%s\\n' "${ALL_IPS[$i]}"
      return 0
    fi
  done
  die "无法识别当前主机名：$current，请检查 config/cluster.env 中的节点清单。"
}
