#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
[[ "$(hostname -s)" == worker-* ]] || die "Run on worker nodes only"
systemctl daemon-reload
systemctl enable --now nginx-k8s-api
systemctl is-active --quiet nginx-k8s-api || die "Local API proxy did not start"
systemctl enable --now kubelet
systemctl enable --now kube-proxy
