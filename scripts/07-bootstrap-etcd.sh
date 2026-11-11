#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
[[ "$(hostname -s)" == master-* ]] || die "此脚本只能在 Master 节点运行"
# 确认这是首次创建的新集群。严禁通过 initial-cluster-state=new 重建已有集群。
if [[ -d /var/lib/etcd/member ]]; then
  if systemctl is-active --quiet etcd; then
    ok "检测到已有 etcd member 且服务正在运行；跳过重复初始化。"
    exit 0
  fi
  die "检测到已有 etcd 数据但服务未运行；为保护数据拒绝重新初始化，请先检查 etcd 日志和成员状态。"
fi
systemctl enable --now etcd
systemctl is-active --quiet etcd || die "etcd 启动后未处于 active 状态"
ok "etcd 服务已启动；请检查成员健康状态和集群 quorum。"
