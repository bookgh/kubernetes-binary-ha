#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
log "检查 Kubernetes API 就绪状态（readyz）"
curl --fail --silent --show-error --cacert /etc/kubernetes/pki/k8s-ca.crt \
  --cert /etc/kubernetes/pki/admin.crt --key /etc/kubernetes/pki/admin.key \
  "https://127.0.0.1:${API_PORT}/readyz?verbose" || true
log "检查集群节点"
kubectl get nodes -o wide
log "检查全部命名空间中的 Pod"
kubectl get pods -A -o wide
log "查看最近事件"
kubectl get events -A --sort-by=.metadata.creationTimestamp | tail -40
log "检查 etcd 集群端点（需在具备 etcd 客户端证书的 Master 上运行）"
ETCDCTL_API=3 etcdctl \
  --endpoints="https://${MASTER1_IP}:2379,https://${MASTER2_IP}:2379,https://${MASTER3_IP}:2379" \
  --cacert=/etc/etcd/pki/etcd-ca.crt \
  --cert=/etc/etcd/pki/etcd-master-01-server.crt \
  --key=/etc/etcd/pki/etcd-master-01-server.key \
  endpoint health || true
