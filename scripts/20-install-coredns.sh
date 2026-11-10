#!/usr/bin/env bash
# 在部署机执行：使用私有镜像仓库部署 CoreDNS。
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
KUBECTL="$ROOT/offline/bin/kubectl"
[[ -x "$KUBECTL" ]] || KUBECTL="$(command -v kubectl || true)"
[[ -n "$KUBECTL" && -x "$KUBECTL" ]] || die "找不到 kubectl"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export KUBECONFIG
[[ -s "$KUBECONFIG" ]] || die "缺少管理员 kubeconfig"
: "${COREDNS_IMAGE:?请在 config/cluster.env 设置已同步到私有仓库的 COREDNS_IMAGE}"
TEMPLATE="$ROOT/manifests/coredns.yaml.template"
[[ -s "$TEMPLATE" ]] || die "缺少 manifests/coredns.yaml.template"
mkdir -p "$ROOT/generated"
sed -e "s#__CLUSTER_DOMAIN__#${CLUSTER_DOMAIN}#g" -e "s#__DNS_SERVICE_IP__#${DNS_SERVICE_IP}#g" -e "s#__COREDNS_IMAGE__#${COREDNS_IMAGE}#g" "$TEMPLATE" > "$ROOT/generated/coredns.yaml"
"$KUBECTL" apply -f "$ROOT/generated/coredns.yaml"
"$KUBECTL" -n kube-system rollout status deployment/coredns --timeout=300s
"$KUBECTL" -n kube-system get deployment coredns
"$KUBECTL" -n kube-system get service kube-dns
"$KUBECTL" -n kube-system get endpoints kube-dns
ok "CoreDNS 已部署。请继续执行 DNS 与 Service 连通性验收。"
