#!/usr/bin/env bash
# 在部署机执行：只在本地生成配置，不连接远程节点。
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
case "${RUNTIME_TYPE:-containerd}" in
  containerd) RUNTIME_ENDPOINT="unix:///run/containerd/containerd.sock" ;;
  docker)     RUNTIME_ENDPOINT="unix:///var/run/cri-dockerd.sock" ;;
  *) die "RUNTIME_TYPE 仅支持 containerd 或 docker" ;;
esac
case "${KUBE_PROXY_MODE:-ipvs}" in
  ipvs|nftables) ;;
  *) die "KUBE_PROXY_MODE 仅支持 ipvs 或 nftables" ;;
esac
[[ "${IPVS_STRICT_ARP:-false}" == true || "${IPVS_STRICT_ARP:-false}" == false ]] || die "IPVS_STRICT_ARP 必须为 true/false"
[[ "${NFTABLES_MASQUERADE_BIT:-14}" =~ ^([0-9]|[12][0-9]|3[01])$ ]] || die "NFTABLES_MASQUERADE_BIT 必须在 0-31 之间"

OUT="${ROOT}/generated"
rm -rf "$OUT"
mkdir -p "$OUT"
NODES=(master-01 master-02 master-03 worker-01 worker-02 worker-03)
IPS=("$MASTER1_IP" "$MASTER2_IP" "$MASTER3_IP" "$WORKER1_IP" "$WORKER2_IP" "$WORKER3_IP")
for i in "${!NODES[@]}"; do
  node="${NODES[$i]}"; ip="${IPS[$i]}"
  dir="$OUT/$node"
  install -d -m 0700 "$dir/etc/kubernetes" "$dir/var/lib/kubelet" "$dir/var/lib/kube-proxy"
  sed -e "s#clusterDomain: .*#clusterDomain: ${CLUSTER_DOMAIN}#" \
      -e "s#  - 10.96.0.10#  - ${DNS_SERVICE_IP}#" \
      "$ROOT/config/kubelet-config.yaml" > "$dir/var/lib/kubelet/config.yaml"
  sed -e "s#clusterCIDR: .*#clusterCIDR: ${POD_CIDR}#" \
      -e "s#mode: .*#mode: ${KUBE_PROXY_MODE}#" \
      -e "s#strictARP: .*#strictARP: ${IPVS_STRICT_ARP}#" \
      -e "s#masqueradeBit: .*#masqueradeBit: ${NFTABLES_MASQUERADE_BIT}#" \
      -e "s#hostnameOverride: .*#hostnameOverride: ${node}#" \
      "$ROOT/config/kube-proxy-config.yaml" > "$dir/var/lib/kube-proxy/config.yaml"
  cat > "$dir/etc/kubernetes/cluster.env" <<EOF
NODE_NAME=${node}
NODE_IP=${ip}
CLUSTER_NAME=${CLUSTER_NAME}
CLUSTER_DOMAIN=${CLUSTER_DOMAIN}
API_DNS=${API_DNS}
API_PORT=${API_PORT}
POD_CIDR=${POD_CIDR}
SERVICE_CIDR=${SERVICE_CIDR}
MASTER1_IP=${MASTER1_IP}
MASTER2_IP=${MASTER2_IP}
MASTER3_IP=${MASTER3_IP}
ETCD_INITIAL_CLUSTER=master-01=https://${MASTER1_IP}:2380,master-02=https://${MASTER2_IP}:2380,master-03=https://${MASTER3_IP}:2380
ETCD_HEARTBEAT_INTERVAL=${ETCD_HEARTBEAT_INTERVAL}
ETCD_ELECTION_TIMEOUT=${ETCD_ELECTION_TIMEOUT}
ETCD_QUOTA_BACKEND_BYTES=${ETCD_QUOTA_BACKEND_BYTES}
RUNTIME_TYPE=${RUNTIME_TYPE:-containerd}
CONTAINER_RUNTIME_ENDPOINT=${RUNTIME_ENDPOINT}
PAUSE_IMAGE=${PAUSE_IMAGE}
KUBE_PROXY_MODE=${KUBE_PROXY_MODE:-nftables}
EOF
  cat > "$dir/etc/kubernetes/runtime.env" <<EOF
CONTAINER_RUNTIME_ENDPOINT=${RUNTIME_ENDPOINT}
RUNTIME_TYPE=${RUNTIME_TYPE:-containerd}
PAUSE_IMAGE=${PAUSE_IMAGE}
EOF
  chmod 0600 "$dir/etc/kubernetes/cluster.env" "$dir/etc/kubernetes/runtime.env"
  log "已生成 ${node}（${ip}）的 kubelet/kube-proxy/运行时配置"
done
ok "本地配置生成完成：$OUT；下一步运行 scripts/15-distribute-node-configs.sh。"
