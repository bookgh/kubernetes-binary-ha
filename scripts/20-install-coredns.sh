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
VALUES="$ROOT/offline/helm/coredns-values.yaml"
[[ -s "$CHART" ]] || die "缺少 CoreDNS Helm Chart：$CHART；请先运行 scripts/01-prepare-offline.sh"
[[ -s "$VALUES" ]] || die "缺少与 Chart 默认值合并的 CoreDNS 配置：$VALUES；请重新准备离线资源"
log "使用 CoreDNS Helm Chart 和 CI 生成的默认值配置安装/升级 kube-system/coredns"
"$HELM" upgrade --install coredns "$CHART" \
  --namespace kube-system \
  --values "$VALUES" \
  --set image.repository="$PRIVATE_REGISTRY/coredns/coredns" \
  --take-ownership \
  --wait --timeout 5m

"$KUBECTL" -n kube-system rollout status deployment/coredns --timeout=300s
"$KUBECTL" -n kube-system get deployment coredns
"$KUBECTL" -n kube-system get service kube-dns
SERVICE_IP="$("$KUBECTL" -n kube-system get service kube-dns -o jsonpath='{.spec.clusterIP}')"
[[ "$SERVICE_IP" == "$DNS_SERVICE_IP" ]] ||
  die "CoreDNS Service ClusterIP 不匹配：期望 $DNS_SERVICE_IP，实际 $SERVICE_IP"
"$KUBECTL" -n kube-system get endpoints kube-dns -o json |
  jq -e '[.subsets[]?.addresses[]?] | length > 0' >/dev/null ||
  die "CoreDNS kube-dns Service 没有可用 Endpoints"
ok "CoreDNS Helm Chart 部署完成，Service IP 和后端 Endpoints 均通过检查。"
