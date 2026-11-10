#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
[[ "$(hostname -s)" == worker-* ]] || die "此脚本只能在 Worker 节点运行"
systemctl daemon-reload
systemctl enable --now nginx-k8s-api
systemctl is-active --quiet nginx-k8s-api || die "本机 Kubernetes API 代理启动失败"
systemctl enable --now kubelet
systemctl enable --now kube-proxy
