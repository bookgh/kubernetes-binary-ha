#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
[[ "$(hostname -s)" == master-* ]] || die "此脚本只能在 Master 节点运行"
# 确认这是首次创建的新集群。严禁通过 initial-cluster-state=new 重建已有集群。
[[ ! -d /var/lib/etcd/member ]] || die "检测到已有 etcd 数据；为避免覆盖现有集群，拒绝初始化"
systemctl enable --now etcd
ok "etcd 服务已启动；请检查成员健康状态和集群 quorum。"
