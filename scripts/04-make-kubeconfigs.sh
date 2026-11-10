#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
PKI="${ROOT}/pki"
OUT="${ROOT}/kubeconfigs"
mkdir -p "$OUT"
make_cfg() {
  local name="$1" user="$2" cert="$3" key="$4" endpoint="$5"
  kubectl config set-cluster "$CLUSTER_NAME" --server="https://${endpoint}:${API_PORT}" \
    --certificate-authority="$PKI/k8s-ca.crt" --embed-certs=true --kubeconfig="$OUT/${name}.conf"
  kubectl config set-credentials "$user" --client-certificate="$PKI/${cert}.crt" \
    --client-key="$PKI/${key}.key" --embed-certs=true --kubeconfig="$OUT/${name}.conf"
  kubectl config set-context "${user}@${CLUSTER_NAME}" --cluster="$CLUSTER_NAME" \
    --user="$user" --kubeconfig="$OUT/${name}.conf"
  kubectl config use-context "${user}@${CLUSTER_NAME}" --kubeconfig="$OUT/${name}.conf"
  chmod 0600 "$OUT/${name}.conf"
}
# 管理员使用的 DNS 必须解析到可访问的 Master 地址；当前设计不部署 LB/VIP。
make_cfg admin kubernetes-admin admin admin "$API_DNS"
# 集群内组件统一使用回环地址：Master 直连本机 API，Worker 通过本机 NGINX 代理访问 API。
make_cfg controller-manager system:kube-controller-manager controller-manager controller-manager 127.0.0.1
make_cfg scheduler system:kube-scheduler scheduler scheduler 127.0.0.1
make_cfg kube-proxy system:kube-proxy kube-proxy kube-proxy 127.0.0.1
for n in master-01 master-02 master-03 worker-01 worker-02 worker-03; do
  make_cfg "kubelet-${n}" "system:node:${n}" "kubelet-${n}" "kubelet-${n}" 127.0.0.1
done
log "Kubeconfigs created. Distribute only the matching node kubelet config."
