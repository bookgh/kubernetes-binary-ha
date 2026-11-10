#!/usr/bin/env bash
# 在部署机执行：批量分发 scripts/14-render-node-configs.sh 生成的配置。
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
require_cmd ssh
require_cmd scp
GEN="${ROOT}/generated"
[[ -d "$GEN" ]] || die "找不到 generated/；请先运行 scripts/14-render-node-configs.sh"
NODES=(master-01 master-02 master-03 worker-01 worker-02 worker-03)
IPS=("$MASTER1_IP" "$MASTER2_IP" "$MASTER3_IP" "$WORKER1_IP" "$WORKER2_IP" "$WORKER3_IP")
for i in "${!NODES[@]}"; do
  node="${NODES[$i]}"; ip="${IPS[$i]}"; src="$GEN/$node"
  [[ -d "$src" ]] || die "缺少节点配置目录：$src"
  log "分发配置到 $node ($ip)"
  ssh -o BatchMode=yes "root@$ip" "install -d -m 0755 /etc/kubernetes /var/lib/kubelet /var/lib/kube-proxy"
  scp "$src/var/lib/kubelet/config.yaml" "root@$ip:/var/lib/kubelet/config.yaml"
  scp "$src/var/lib/kube-proxy/config.yaml" "root@$ip:/var/lib/kube-proxy/config.yaml"
  scp "$src/etc/kubernetes/runtime.env" "root@$ip:/etc/kubernetes/runtime.env"
  ssh -o BatchMode=yes "root@$ip" "chmod 0600 /etc/kubernetes/runtime.env"
  ok "$node 配置分发完成"
done
