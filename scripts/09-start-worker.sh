#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
[[ "$(hostname -s)" == worker-* ]] || die "此脚本只能在 Worker 节点运行"
systemctl daemon-reload
systemctl enable --now nginx-k8s-api
systemctl is-active --quiet nginx-k8s-api || die "本机 Kubernetes API 代理启动失败"
curl --fail --silent --insecure "https://127.0.0.1:${API_PORT}/readyz" >/dev/null || \
  warn "API 代理已启动，但当前没有可用的 Master API；kubelet 将继续重试"
systemctl enable --now kubelet
systemctl enable --now kube-proxy
ok "Worker 节点 kubelet、kube-proxy 已启动。"
