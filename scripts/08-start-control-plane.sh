#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
[[ "$(hostname -s)" == master-* ]] || die "此脚本只能在 Master 节点运行"

PHASE="${1:-all}"
case "$PHASE" in
  etcd-only)
    # 第一阶段只触发本机 etcd 启动，不等待单个成员形成 quorum。
    if systemctl is-active --quiet etcd; then
      ok "本机 etcd 已在运行，跳过启动。"
      exit 0
    fi
    if [[ -d /var/lib/etcd/member ]]; then
      die "检测到已有 etcd member 数据但服务未运行；为保护数据拒绝重新初始化。"
    fi
    systemctl enable etcd
    # 三个成员必须尽快并行启动；单个节点此时可能尚无 quorum，启动失败由后续健康检查判定。
    nohup bash -c 'systemctl start etcd || true' \
      >/var/log/kubernetes-binary-ha-etcd-bootstrap.log 2>&1 </dev/null &
    ok "已在后台触发本机 etcd 启动，等待所有 Master 启动后统一验证集群。"
    ;;
  control-plane-only)
    systemctl enable --now kube-apiserver
    systemctl enable --now kube-controller-manager
    systemctl enable --now kube-scheduler
    systemctl enable --now kubelet
    systemctl enable --now kube-proxy
    ok "本机控制平面组件已启动。"
    ;;
  all)
    die "请通过 scripts/16-batch-exec.sh masters scripts/08-start-control-plane.sh 执行，以确保先并行启动并验证全部 etcd 成员。"
    ;;
  *)
    die "不支持的启动阶段：$PHASE"
    ;;
esac
