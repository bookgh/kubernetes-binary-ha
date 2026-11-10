#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
[[ "$(hostname -s)" == master-* ]] || die "此脚本只能在 Master 节点运行"
systemctl enable --now kube-apiserver
systemctl enable --now kube-controller-manager
systemctl enable --now kube-scheduler
systemctl enable --now kubelet
systemctl enable --now kube-proxy
ok "本机控制平面组件已启动；请检查 API Server /readyz 和组件日志。"
