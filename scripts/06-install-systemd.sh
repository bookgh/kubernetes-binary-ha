#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
install -d -m 0755 /etc/kubernetes /var/lib/kubelet /var/lib/kube-proxy
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
MASTER1_IP=${MASTER1_IP}
MASTER2_IP=${MASTER2_IP}
MASTER3_IP=${MASTER3_IP}
EOF
chmod 0600 /etc/kubernetes/cluster.env
if [[ "$NODE_NAME" == master-* ]]; then
  for unit in kube-apiserver kube-controller-manager kube-scheduler; do
    install -m 0644 "$ROOT/systemd/${unit}.service" "/etc/systemd/system/${unit}.service"
  done
fi
install -m 0644 "$ROOT/systemd/nginx-k8s-api.service" /etc/systemd/system/nginx-k8s-api.service
install -m 0644 "$ROOT/systemd/kubelet.service" /etc/systemd/system/kubelet.service
install -m 0644 "$ROOT/systemd/kube-proxy.service" /etc/systemd/system/kube-proxy.service
systemctl daemon-reload
log "Units installed. Install PKI and kubeconfigs before starting services."
