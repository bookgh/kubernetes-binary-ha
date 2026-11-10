#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
install -d -m 0755 /etc/kubernetes /etc/etcd/pki /var/lib/kubelet /var/lib/kube-proxy
NODE_NAME="$(hostname -s)"
NODE_IP="$(node_ip)"
case "${RUNTIME_TYPE:-containerd}" in
  containerd) DEFAULT_CRI_ENDPOINT="unix:///run/containerd/containerd.sock" ;;
  docker) DEFAULT_CRI_ENDPOINT="unix:///run/cri-dockerd.sock" ;;
  *) die "RUNTIME_TYPE 仅支持 containerd 或 docker" ;;
esac
cat >/etc/kubernetes/cluster.env <<EOF
NODE_NAME=${NODE_NAME}
NODE_IP=${NODE_IP}
CLUSTER_NAME=${CLUSTER_NAME}
CLUSTER_DOMAIN=${CLUSTER_DOMAIN}
API_DNS=${API_DNS}
API_PORT=${API_PORT}
POD_CIDR=${POD_CIDR}
SERVICE_CIDR=${SERVICE_CIDR}
ETCD_HEARTBEAT_INTERVAL=${ETCD_HEARTBEAT_INTERVAL}
ETCD_ELECTION_TIMEOUT=${ETCD_ELECTION_TIMEOUT}
ETCD_QUOTA_BACKEND_BYTES=${ETCD_QUOTA_BACKEND_BYTES}
MASTER1_IP=${MASTER1_IP}
MASTER2_IP=${MASTER2_IP}
MASTER3_IP=${MASTER3_IP}
RUNTIME_TYPE=${RUNTIME_TYPE:-containerd}
CONTAINER_RUNTIME_ENDPOINT=${CONTAINER_RUNTIME_ENDPOINT:-$DEFAULT_CRI_ENDPOINT}
PAUSE_IMAGE=${PAUSE_IMAGE}
EOF
chmod 0600 /etc/kubernetes/cluster.env
if [[ "$NODE_NAME" == master-* ]]; then
  id etcd >/dev/null 2>&1 || useradd --system --home-dir /var/lib/etcd --shell /sbin/nologin etcd
  install -d -o etcd -g etcd /var/lib/etcd
  install -m 0644 "$ROOT/systemd/etcd.service" /etc/systemd/system/etcd.service
  install -m 0644 "$ROOT/systemd/kube-apiserver.service" /etc/systemd/system/
  install -m 0644 "$ROOT/systemd/kube-controller-manager.service" /etc/systemd/system/
  install -m 0644 "$ROOT/systemd/kube-scheduler.service" /etc/systemd/system/
fi
install -m 0644 "$ROOT/systemd/nginx-k8s-api.service" /etc/systemd/system/
install -m 0644 "$ROOT/systemd/kubelet.service" /etc/systemd/system/
install -m 0644 "$ROOT/systemd/kube-proxy.service" /etc/systemd/system/
[[ -s /var/lib/kubelet/config.yaml ]] || die "缺少已生成的 kubelet 配置；请先运行 scripts/14-render-node-configs.sh 和 scripts/15-distribute-node-configs.sh"
[[ -s /var/lib/kube-proxy/config.yaml ]] || die "缺少已生成的 kube-proxy 配置；请先运行 scripts/14-render-node-configs.sh 和 scripts/15-distribute-node-configs.sh"
systemctl daemon-reload
log "systemd 单元文件已安装；运行时 endpoint：${CONTAINER_RUNTIME_ENDPOINT:-$DEFAULT_CRI_ENDPOINT}。请先完成证书/kubeconfig/节点配置分发，再启动服务。"
