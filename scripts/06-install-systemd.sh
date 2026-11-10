#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
[[ -s /etc/kubernetes/cluster.env ]] || die "缺少部署端生成的 cluster.env；请先执行 scripts/14-render-node-configs.sh 和 scripts/15-distribute-node-configs.sh"
[[ -s /etc/kubernetes/runtime.env ]] || die "缺少部署端生成的 runtime.env；请先执行 scripts/15-distribute-node-configs.sh"
# 远程只读取部署端生成的配置，不在节点上临时拼接配置文件。
# shellcheck disable=SC1091
source /etc/kubernetes/cluster.env
[[ "$NODE_NAME" == "$(hostname -s)" ]] || die "节点名不匹配：配置为 $NODE_NAME，当前主机为 $(hostname -s)"
chmod 0600 /etc/kubernetes/cluster.env /etc/kubernetes/runtime.env
install -d -m 0755 /etc/kubernetes/pki /etc/etcd/pki /var/lib/kubelet /var/lib/kube-proxy
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
[[ -s /etc/modules-load.d/10-kubernetes.conf ]] || die "缺少已分发的内核模块清单"
[[ -s /etc/sysctl.d/95-kubernetes.conf ]] || die "缺少已分发的 Kubernetes sysctl 配置"
# 按部署端生成的模式加载模块：IPVS 与 nftables 不混装、不混配。
while IFS= read -r module; do
  [[ -n "$module" ]] || continue
  modprobe "$module" || die "内核模块加载失败：$module"
done < /etc/modules-load.d/10-kubernetes.conf
sysctl -p /etc/sysctl.d/95-kubernetes.conf
systemctl daemon-reload
log "systemd 与节点内核配置安装完成：node=$NODE_NAME，runtime=$RUNTIME_TYPE，CRI=$CONTAINER_RUNTIME_ENDPOINT，proxy=$KUBE_PROXY_MODE"
