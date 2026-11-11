#!/usr/bin/env bash
# 在部署机执行：使用 Release 内置 Helm Chart 安装 Calico。
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
: "${CALICO_CHART_VERSION:?请先将 config/cluster.env.example 中的 Calico Chart 版本同步到 config/cluster.env}"
: "${PRIVATE_REGISTRY:?请在 config/cluster.env 设置 PRIVATE_REGISTRY}"
: "${HARBOR_HOST:?请在 config/cluster.env 设置 HARBOR_HOST}"

CRD_CHART="$ROOT/offline/helm/projectcalico.org.v3-${CALICO_CHART_VERSION}.tgz"
OPERATOR_CHART="$ROOT/offline/helm/tigera-operator-${CALICO_CHART_VERSION}.tgz"
for chart in "$CRD_CHART" "$OPERATOR_CHART"; do
  [[ -s "$chart" ]] || die "缺少 Calico Helm Chart：$chart；请先运行 scripts/01-prepare-offline.sh"
done

log "1/3 使用 Calico Helm Chart 安装 Kubernetes 1.36+ 原生 v3 CRD"
"$HELM" template calico-crds "$CRD_CHART" \
  --api-versions admissionregistration.k8s.io/v1/MutatingAdmissionPolicy |
  "$KUBECTL" apply --server-side -f -

log "2/3 安装/升级 Tigera Operator（镜像来自 Harbor）"
"$KUBECTL" create namespace tigera-operator --dry-run=client -o yaml |
  "$KUBECTL" apply -f -
VALUES="$(mktemp)"
trap 'rm -f "$VALUES"' EXIT
cat > "$VALUES" <<EOF
tigeraOperator:
  registry: "$HARBOR_HOST"
  image: "library/tigera/operator"
installation:
  registry: "$HARBOR_HOST/"
  imagePath: "library"
  calicoNetwork:
    bgp: "Disabled"
    ipPools:
      - blockSize: 26
        cidr: "$POD_CIDR"
        encapsulation: "VXLAN"
        natOutgoing: "Enabled"
        nodeSelector: "all()"
EOF
"$HELM" upgrade --install calico "$OPERATOR_CHART" \
  --namespace tigera-operator \
  --values "$VALUES" \
  --take-ownership \
  --wait --timeout 10m

"$KUBECTL" wait --for=condition=Available deployment/tigera-operator \
  -n tigera-operator --timeout=300s

log "3/3 等待 Calico 数据面就绪"
for attempt in {1..60}; do
  "$KUBECTL" -n calico-system get ds calico-node >/dev/null 2>&1 && break
  sleep 5
done
"$KUBECTL" -n calico-system rollout status ds/calico-node --timeout=600s
"$KUBECTL" get pods -n calico-system -o wide
ok "Calico Helm Chart 安装完成；继续运行 scripts/18-verify-cluster.sh 检查 Calico 状态。"
