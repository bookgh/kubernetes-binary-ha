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
export KUBECONFIG
[[ -s "$KUBECONFIG" ]] || die "缺少 kubeconfig：$KUBECONFIG"

log "1/5 检查 etcd endpoint、成员数量和 quorum"
bash "$ROOT/scripts/21-verify-etcd.sh"

log "2/5 检查 API Server /readyz"
"$KUBECTL" --kubeconfig="$KUBECONFIG" get --raw='/readyz?verbose'
log "3/5 检查全部节点 Ready、数量和节点 IP"
"$KUBECTL" --kubeconfig="$KUBECONFIG" wait --for=condition=Ready nodes --all --timeout=300s
NODES_JSON="$("$KUBECTL" --kubeconfig="$KUBECONFIG" get nodes -o json)"
printf '%s\n' "$NODES_JSON" | jq -e --argjson expected "${#ALL_NAMES[@]}" '.items | length == $expected' >/dev/null || die "Kubernetes Node 数量与配置不一致：${#ALL_NAMES[@]}"
for i in "${!ALL_NAMES[@]}"; do
  node="${ALL_NAMES[$i]}"
  ip="${ALL_IPS[$i]}"
  printf '%s\n' "$NODES_JSON" | jq -e --arg name "$node" --arg ip "$ip" '.items | any(.metadata.name == $name and any(.status.addresses[]?; .type == "InternalIP" and .address == $ip))' >/dev/null || die "Node $node 未注册或 InternalIP 不匹配：$ip"
done
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
  DATASTORE_TYPE=kubernetes KUBECONFIG="$KUBECONFIG" calicoctl get ippools -o json |
    jq -e --arg cidr "$POD_CIDR" '[.items[] | select(.spec.cidr == $cidr)] | length == 1' >/dev/null ||
    die "Calico IPPool 未唯一匹配 POD_CIDR=$POD_CIDR"
  DATASTORE_TYPE=kubernetes KUBECONFIG="$KUBECONFIG" calicoctl get bgppeers -o wide || warn "未配置 BGP Peering CRD/对象；VXLAN/IPIP 模式下可为正常情况"
fi
if "$KUBECTL" --kubeconfig="$KUBECONFIG" get tigerastatus >/dev/null 2>&1; then
  "$KUBECTL" --kubeconfig="$KUBECONFIG" get tigerastatus
fi
log "5/6 检查 CoreDNS 与集群工作负载"
"$KUBECTL" --kubeconfig="$KUBECONFIG" -n kube-system rollout status deployment/coredns --timeout=300s
DNS_SERVICE_CLUSTER_IP="$("$KUBECTL" --kubeconfig="$KUBECONFIG" -n kube-system get service kube-dns -o jsonpath='{.spec.clusterIP}')"
[[ "$DNS_SERVICE_CLUSTER_IP" == "$DNS_SERVICE_IP" ]] || die "CoreDNS Service ClusterIP 不匹配：期望 $DNS_SERVICE_IP，实际 $DNS_SERVICE_CLUSTER_IP"
"$KUBECTL" --kubeconfig="$KUBECONFIG" -n kube-system get endpoints kube-dns -o json | jq -e '[.subsets[]?.addresses[]?] | length > 0' >/dev/null || die "CoreDNS kube-dns Service 没有可用 Endpoints"
"$KUBECTL" --kubeconfig="$KUBECONFIG" get pods -A -o wide
log "6/6 检查 NodeLocal DNSCache 覆盖全部节点"
: "${NODE_LOCAL_DNS_IMAGE:?请在 config/cluster.env 设置 NODE_LOCAL_DNS_IMAGE}"
: "${NODE_LOCAL_DNS_IP:?请在 config/cluster.env 设置 NODE_LOCAL_DNS_IP}"
NODE_LOCAL_JSON="$("$KUBECTL" --kubeconfig="$KUBECONFIG" -n kube-system get ds node-local-dns -o json)" ||
  die "未发现 kube-system/node-local-dns DaemonSet"
printf '%s\n' "$NODE_LOCAL_JSON" | jq -e --arg image "$NODE_LOCAL_DNS_IMAGE" --argjson nodes "${#ALL_NAMES[@]}" '
  .spec.template.spec.containers[0].image == $image and
  .status.desiredNumberScheduled == $nodes and
  .status.numberReady == $nodes
' >/dev/null || die "NodeLocal DNSCache 镜像、期望调度数或 Ready 数量不匹配"
"$KUBECTL" --kubeconfig="$KUBECONFIG" -n kube-system get pods -l k8s-app=node-local-dns -o wide
bash "$ROOT/scripts/26-verify-network.sh"
ok "etcd、API Server、Node、Calico、CoreDNS、NodeLocal DNSCache、Harbor 镜像拉取、DNS 与跨节点网络自动验收完成。"
