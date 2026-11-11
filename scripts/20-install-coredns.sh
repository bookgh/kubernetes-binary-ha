#!/usr/bin/env bash
# 在部署机执行：使用 Release 内置 CoreDNS Helm Chart 部署集群 DNS。
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root

HELM="$ROOT/offline/bin/helm"
[[ -x "$HELM" ]] || HELM="$(command -v helm || true)"
[[ -n "$HELM" && -x "$HELM" ]] || die "找不到 helm"
KUBECTL="$ROOT/offline/bin/kubectl"
[[ -x "$KUBECTL" ]] || KUBECTL="$(command -v kubectl || true)"
[[ -n "$KUBECTL" && -x "$KUBECTL" ]] || die "找不到 kubectl"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export KUBECONFIG
[[ -s "$KUBECONFIG" ]] || die "缺少管理员 kubeconfig"
: "${COREDNS_CHART_VERSION:?请先将 config/cluster.env.example 中的 CoreDNS Chart 版本同步到 config/cluster.env}"
: "${PRIVATE_REGISTRY:?请在 config/cluster.env 设置 PRIVATE_REGISTRY}"
: "${CLUSTER_DOMAIN:?请在 config/cluster.env 设置 CLUSTER_DOMAIN}"
: "${DNS_SERVICE_IP:?请在 config/cluster.env 设置 DNS_SERVICE_IP}"

CHART="$ROOT/offline/helm/coredns-${COREDNS_CHART_VERSION}.tgz"
[[ -s "$CHART" ]] || die "缺少 CoreDNS Helm Chart：$CHART；请先运行 scripts/01-prepare-offline.sh"
log "使用 CoreDNS Helm Chart 安装/升级 kube-system/coredns"
"$HELM" upgrade --install coredns "$CHART" \
  --namespace kube-system \
  --set image.repository="$PRIVATE_REGISTRY/coredns/coredns" \
  --set-string "service.clusterIP=$DNS_SERVICE_IP" \
  --set service.name=kube-dns \
  --set k8sAppLabelOverride=kube-dns \
  --set isClusterService=true \
  --set replicaCount=2 \
  --set priorityClassName=system-cluster-critical \
  --set 'tolerations[0].key=CriticalAddonsOnly' \
  --set 'tolerations[0].operator=Exists' \
  --set 'tolerations[1].key=node-role.kubernetes.io/control-plane' \
  --set 'tolerations[1].effect=NoSchedule' \
  --set-string "servers[0].plugins[3].parameters=$CLUSTER_DOMAIN in-addr.arpa ip6.arpa" \
  --take-ownership \
  --wait --timeout 5m

"$KUBECTL" -n kube-system rollout status deployment/coredns --timeout=300s
"$KUBECTL" -n kube-system get deployment coredns
"$KUBECTL" -n kube-system get service kube-dns
"$KUBECTL" -n kube-system get endpoints kube-dns
ok "CoreDNS Helm Chart 部署完成。请继续执行 DNS 与 Service 连通性验收。"
