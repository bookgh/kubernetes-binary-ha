#!/usr/bin/env bash
# 在部署机执行：通过 Tigera Operator 安装 Calico VXLAN。
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
KUBECTL="$ROOT/offline/bin/kubectl"
[[ -x "$KUBECTL" ]] || KUBECTL="$(command -v kubectl || true)"
[[ -n "$KUBECTL" && -x "$KUBECTL" ]] || die "找不到 kubectl"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export KUBECONFIG
[[ -s "$KUBECONFIG" ]] || die "缺少管理员 kubeconfig"
for f in "$ROOT/offline/manifests/calico-crds.yaml" "$ROOT/offline/manifests/tigera-operator.yaml" "$ROOT/manifests/calico-installation.yaml.template"; do
  [[ -s "$f" ]] || die "缺少 Calico 安装文件：$f"
done
"$KUBECTL" apply -f "$ROOT/offline/manifests/calico-crds.yaml"
mkdir -p "$ROOT/generated"
sed "s#quay.io/tigera#${PRIVATE_REGISTRY}/tigera#g" "$ROOT/offline/manifests/tigera-operator.yaml" > "$ROOT/generated/tigera-operator.yaml"
"$KUBECTL" apply -f "$ROOT/generated/tigera-operator.yaml"
"$KUBECTL" wait --for=condition=Available deployment/tigera-operator -n tigera-operator --timeout=300s
sed -e "s#__POD_CIDR__#${POD_CIDR}#g" -e "s#__PRIVATE_REGISTRY__#${PRIVATE_REGISTRY}#g" "$ROOT/manifests/calico-installation.yaml.template" > "$ROOT/generated/calico-installation.yaml"
"$KUBECTL" apply -f "$ROOT/generated/calico-installation.yaml"
"$KUBECTL" wait --for=condition=Ready nodes --all --timeout=600s
"$KUBECTL" get pods -n calico-system -o wide
ok "Calico Installation CR 已提交；继续运行 scripts/18-verify-cluster.sh 检查 Calico 状态。"
