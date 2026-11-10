#!/usr/bin/env bash
# 在部署机执行：检查 etcd quorum/health、Kubernetes API、Node、Calico 和 CoreDNS。
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
require_cmd curl
require_cmd jq
OFF="$ROOT/offline"
PKI="$ROOT/pki"
KUBECTL="$OFF/bin/kubectl"
[[ -x "$KUBECTL" ]] || KUBECTL="$(command -v kubectl || true)"
[[ -n "$KUBECTL" && -x "$KUBECTL" ]] || die "找不到 kubectl"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
[[ -s "$KUBECONFIG" ]] || die "缺少 kubeconfig：$KUBECONFIG"

log "1/5 检查 etcd 三成员健康与 quorum"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
tar -xzf "$OFF/src/etcd.tar.gz" -C "$TMP"
ETCDCTL="$(find "$TMP" -type f -name etcdctl -print -quit)"
[[ -x "$ETCDCTL" ]] || die "Release etcd 压缩包中缺少 etcdctl"
ETCD_ENDPOINTS="https://${MASTER1_IP}:2379,https://${MASTER2_IP}:2379,https://${MASTER3_IP}:2379"
ETCDCTL_API=3 "$ETCDCTL" --endpoints="$ETCD_ENDPOINTS" \
  --cacert="$PKI/etcd-ca.crt" --cert="$PKI/apiserver-etcd-client.crt" \
  --key="$PKI/apiserver-etcd-client.key" endpoint health
ETCD_STATUS="$(ETCDCTL_API=3 "$ETCDCTL" --endpoints="$ETCD_ENDPOINTS" \
  --cacert="$PKI/etcd-ca.crt" --cert="$PKI/apiserver-etcd-client.crt" \
  --key="$PKI/apiserver-etcd-client.key" endpoint status --write-out=json)"
printf '%s\n' "$ETCD_STATUS" | jq -e 'length == 3 and ([.[] | select(.Status.leader == .Status.header.member_id)] | length == 1)' >/dev/null || die "etcd 必须有 3 个健康 endpoint 且恰有 1 个 Leader"
printf '%s\n' "$ETCD_STATUS" | jq -r '.[] | [.Endpoint, .Status.header.member_id, .Status.leader, .Status.raftTerm, .Status.raftIndex] | @tsv'
ETCD_MEMBERS="$(ETCDCTL_API=3 "$ETCDCTL" --endpoints="$ETCD_ENDPOINTS" \
  --cacert="$PKI/etcd-ca.crt" --cert="$PKI/apiserver-etcd-client.crt" \
  --key="$PKI/apiserver-etcd-client.key" member list --write-out=json)"
printf '%s\n' "$ETCD_MEMBERS" | jq -e '.members | length == 3' >/dev/null || die "etcd member 数量不是 3"
printf '%s\n' "$ETCD_MEMBERS" | jq -r '.members[] | [.name, .ID, .peerURLs[0]] | @tsv'

log "2/5 检查 API Server /readyz"
"$KUBECTL" --kubeconfig="$KUBECONFIG" get --raw='/readyz?verbose'
log "3/5 检查全部节点 Ready"
"$KUBECTL" --kubeconfig="$KUBECONFIG" wait --for=condition=Ready nodes --all --timeout=300s
"$KUBECTL" --kubeconfig="$KUBECONFIG" get nodes -o wide
log "4/5 检查 Calico DaemonSet 与控制器"
if "$KUBECTL" --kubeconfig="$KUBECONFIG" -n calico-system get ds calico-node >/dev/null 2>&1; then
  "$KUBECTL" --kubeconfig="$KUBECONFIG" -n calico-system rollout status ds/calico-node --timeout=300s
  "$KUBECTL" --kubeconfig="$KUBECONFIG" -n calico-system get pods -o wide
elif "$KUBECTL" --kubeconfig="$KUBECONFIG" -n kube-system get ds calico-node >/dev/null 2>&1; then
  "$KUBECTL" --kubeconfig="$KUBECONFIG" -n kube-system rollout status ds/calico-node --timeout=300s
  "$KUBECTL" --kubeconfig="$KUBECONFIG" -n kube-system get pods -o wide
else
  die "未发现 Calico calico-node DaemonSet；请检查 Calico 安装清单和 operator 状态"
fi
if command -v calicoctl >/dev/null 2>&1; then
  DATASTORE_TYPE=kubernetes KUBECONFIG="$KUBECONFIG" calicoctl get nodes -o wide
  DATASTORE_TYPE=kubernetes KUBECONFIG="$KUBECONFIG" calicoctl get ippools -o wide
  DATASTORE_TYPE=kubernetes KUBECONFIG="$KUBECONFIG" calicoctl get bgppeers -o wide || warn "未配置 BGP Peering CRD/对象；VXLAN/IPIP 模式下可为正常情况"
fi
if "$KUBECTL" --kubeconfig="$KUBECONFIG" get tigerastatus >/dev/null 2>&1; then
  "$KUBECTL" --kubeconfig="$KUBECONFIG" get tigerastatus
fi
log "5/5 检查 CoreDNS 与集群工作负载"
"$KUBECTL" --kubeconfig="$KUBECONFIG" -n kube-system rollout status deployment/coredns --timeout=300s
"$KUBECTL" --kubeconfig="$KUBECONFIG" get pods -A -o wide
ok "etcd、API Server、Node、Calico 和 CoreDNS 检查完成。请继续执行 docs/INSTALL-FROM-SCRATCH.md 中的跨节点 Pod、Service、DNS 与 NodePort 验收。"
