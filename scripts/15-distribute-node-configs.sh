#!/usr/bin/env bash
# 在部署机执行：同步项目运行文件和离线包，再分发已生成的节点配置。
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
require_cmd ssh
require_cmd scp
require_cmd rsync
GEN="${ROOT}/generated"
[[ -d "$GEN" ]] || die "找不到 generated/；请先运行 scripts/14-render-node-configs.sh"
NODES=(master-01 master-02 master-03 worker-01 worker-02 worker-03)
IPS=("$MASTER1_IP" "$MASTER2_IP" "$MASTER3_IP" "$WORKER1_IP" "$WORKER2_IP" "$WORKER3_IP")
REMOTE_ROOT="/opt/kubernetes-binary-ha"
for i in "${!NODES[@]}"; do
  node="${NODES[$i]}"; ip="${IPS[$i]}"; src="$GEN/$node"
  [[ -d "$src" ]] || die "缺少节点配置目录：$src"
  log "同步项目文件和配置到 $node ($ip)"
  ssh -o BatchMode=yes "root@$ip" "install -d -m 0755 $REMOTE_ROOT"
  # 不分发 PKI 私钥或本地 kubeconfig；这些凭据由专门流程按节点最小权限传输。
  rsync -az --delete \
    --exclude='.git/' --exclude='generated/' --exclude='pki/' --exclude='kubeconfigs/' \
    "$ROOT/" "root@$ip:$REMOTE_ROOT/"
  ssh -o BatchMode=yes "root@$ip" "install -d -m 0755 /etc/kubernetes /var/lib/kubelet /var/lib/kube-proxy"
  scp "$src/var/lib/kubelet/config.yaml" "root@$ip:/var/lib/kubelet/config.yaml"
  scp "$src/var/lib/kube-proxy/config.yaml" "root@$ip:/var/lib/kube-proxy/config.yaml"
  scp "$src/etc/kubernetes/runtime.env" "root@$ip:/etc/kubernetes/runtime.env"
  ssh -o BatchMode=yes "root@$ip" "chmod 0600 /etc/kubernetes/runtime.env"
  ok "$node 项目文件和运行配置分发完成"
done
