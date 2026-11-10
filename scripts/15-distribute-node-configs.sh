#!/usr/bin/env bash
# 在部署机执行：批量同步项目、离线包、节点配置及按节点授权的凭据。
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
require_cmd ssh
require_cmd scp
require_cmd rsync
GEN="${ROOT}/generated"
PKI="${ROOT}/pki"
KCFG="${ROOT}/kubeconfigs"
[[ -d "$GEN" ]] || die "缺少 generated/；请先运行 scripts/14-render-node-configs.sh"
[[ -d "$ROOT/offline/rpms" && -s "$ROOT/offline/SHA256SUMS" ]] || die "缺少 offline/ 离线资源；请先运行 scripts/01-prepare-offline.sh"
[[ -s "$PKI/k8s-ca.crt" && -s "$PKI/k8s-ca-bundle.crt" ]] || die "缺少 PKI；请先运行 scripts/03-generate-pki.sh"
[[ -s "$KCFG/admin.conf" && -s "$KCFG/kube-proxy.conf" ]] || die "缺少 kubeconfig；请先运行 scripts/04-make-kubeconfigs.sh"

NODES=("${ALL_NAMES[@]}")
IPS=("${ALL_IPS[@]}")
REMOTE_ROOT="/opt/kubernetes-binary-ha"
for i in "${!NODES[@]}"; do
  node="${NODES[$i]}"; ip="${IPS[$i]}"; src="$GEN/$node"
  [[ -d "$src" ]] || die "缺少节点配置目录：$src"
  log "同步项目文件、离线包和节点配置到 $node ($ip)"
  ssh -o BatchMode=yes "root@$ip" "install -d -m 0755 $REMOTE_ROOT /etc/kubernetes/pki /etc/etcd/pki"
  # 先用 SCP 发送离线 RPM，再在目标节点安装 rsync 等传输依赖。
  scp -r "$ROOT/offline" "root@$ip:$REMOTE_ROOT/"
  ssh -o BatchMode=yes "root@$ip" "cd $REMOTE_ROOT/offline && sha256sum -c SHA256SUMS && dnf install -y --disablerepo='*' $REMOTE_ROOT/offline/rpms/*.rpm"
  # 根 CA 私钥、etcd CA 私钥和管理员 kubeconfig 不会分发到节点。
  rsync -az --delete \
    --exclude='.git/' --exclude='generated/' --exclude='pki/' --exclude='kubeconfigs/' --exclude='offline/' \
    "$ROOT/" "root@$ip:$REMOTE_ROOT/"
  ssh -o BatchMode=yes "root@$ip" "install -d -m 0755 /etc/kubernetes /var/lib/kubelet /var/lib/kube-proxy"
  scp "$src/var/lib/kubelet/config.yaml" "root@$ip:/var/lib/kubelet/config.yaml"
  scp "$src/var/lib/kube-proxy/config.yaml" "root@$ip:/var/lib/kube-proxy/config.yaml"
  scp "$src/etc/kubernetes/cluster.env" "root@$ip:/etc/kubernetes/cluster.env"
  scp "$src/etc/kubernetes/runtime.env" "root@$ip:/etc/kubernetes/runtime.env"
  if [[ "$node" == worker-* ]]; then
    ssh -o BatchMode=yes "root@$ip" "install -d -m 0755 /etc/nginx"
    scp "$src/etc/nginx/nginx.conf" "root@$ip:/etc/nginx/nginx.conf"
  fi
  scp "$GEN/common/etc/crictl.yaml" "root@$ip:/etc/crictl.yaml"
  ssh -o BatchMode=yes "root@$ip" "install -d -m 0755 /etc/modules-load.d /etc/sysctl.d"
  scp "$GEN/common/etc/modules-load.d/10-kubernetes.conf" "root@$ip:/etc/modules-load.d/10-kubernetes.conf"
  scp "$GEN/common/etc/sysctl.d/95-kubernetes.conf" "root@$ip:/etc/sysctl.d/95-kubernetes.conf"
  if [[ "${RUNTIME_TYPE:-containerd}" == containerd ]]; then
    ssh -o BatchMode=yes "root@$ip" "install -d -m 0755 /etc/containerd"
    scp "$GEN/common/etc/containerd/config.toml" "root@$ip:/etc/containerd/config.toml"
  else
    ssh -o BatchMode=yes "root@$ip" "install -d -m 0755 /etc/docker"
    scp "$GEN/common/etc/docker/daemon.json" "root@$ip:/etc/docker/daemon.json"
  fi
  scp "$PKI/k8s-ca.crt" "$PKI/k8s-ca-bundle.crt" "root@$ip:/etc/kubernetes/pki/"
  scp "$KCFG/kubelet-$node.conf" "root@$ip:/etc/kubernetes/kubelet.conf"
  scp "$KCFG/kube-proxy.conf" "root@$ip:/etc/kubernetes/kube-proxy.conf"

  if [[ "$node" == master-* ]]; then
    MASTER_PKI=(apiserver.crt apiserver.key apiserver-kubelet-client.crt apiserver-kubelet-client.key front-proxy-ca.crt front-proxy-client.crt front-proxy-client.key apiserver-etcd-client.crt apiserver-etcd-client.key cluster-signer.crt cluster-signer.key sa.key sa.pub)
    for file in "${MASTER_PKI[@]}"; do
      [[ -s "$PKI/$file" ]] || die "缺少 Master 凭据：$PKI/$file"
      scp "$PKI/$file" "root@$ip:/etc/kubernetes/pki/$file"
    done
    scp "$KCFG/controller-manager.conf" "root@$ip:/etc/kubernetes/controller-manager.conf"
    scp "$KCFG/scheduler.conf" "root@$ip:/etc/kubernetes/scheduler.conf"
    for file in etcd-ca.crt "etcd-$node-server.crt" "etcd-$node-server.key" "etcd-$node-peer.crt" "etcd-$node-peer.key"; do
      [[ -s "$PKI/$file" ]] || die "缺少 etcd 凭据：$PKI/$file"
      scp "$PKI/$file" "root@$ip:/etc/etcd/pki/$file"
    done
    ssh -o BatchMode=yes "root@$ip" "id etcd >/dev/null 2>&1 || useradd --system --home-dir /var/lib/etcd --shell /sbin/nologin etcd"
    ssh -o BatchMode=yes "root@$ip" "chown -R etcd:etcd /etc/etcd/pki && chmod 0750 /etc/etcd/pki && chmod 0640 /etc/etcd/pki/*.key"
  fi
  ssh -o BatchMode=yes "root@$ip" "chmod 0600 /etc/kubernetes/cluster.env /etc/kubernetes/runtime.env /etc/kubernetes/*.conf && find /etc/kubernetes/pki -type f -name '*.key' -exec chmod 0600 {} +"
  ok "$node 项目、节点配置和所需凭据分发完成"
done
install -d -m 0700 "$HOME/.kube"
install -m 0600 "$KCFG/admin.conf" "$HOME/.kube/config"
ok "管理员 kubeconfig 已安装到部署机 $HOME/.kube/config；CA 根私钥仍保留在部署机 PKI 目录。"
