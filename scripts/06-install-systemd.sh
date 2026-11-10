#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
install -d -m 0755 /etc/kubernetes /etc/etcd/pki /var/lib/kubelet /var/lib/kube-proxy
NODE_NAME="$(hostname -s)"
NODE_IP="$(node_ip)"
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
install -m 0644 "$ROOT/config/kubelet-config.yaml" /var/lib/kubelet/config.yaml
install -m 0644 "$ROOT/config/kube-proxy-config.yaml" /var/lib/kube-proxy/config.yaml
systemctl daemon-reload
log "systemd 单元文件已安装但尚未启动。Worker 节点请先分发节点专属证书和 kubeconfig，再运行 scripts/13-install-nginx-proxy.sh。"
