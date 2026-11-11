#!/usr/bin/env bash
# 部署端：分发节点所需资源；Harbor 与集中镜像归档只发送到 Harbor 节点。
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"
require_root

for cmd in ssh scp rsync; do
  require_cmd "$cmd"
done

GEN="$ROOT/generated"
PKI="$ROOT/pki"
KCFG="$ROOT/kubeconfigs"
REMOTE_ROOT="/opt/kubernetes-binary-ha"
NODE_OFFLINE="$(mktemp -d)"
PROJECT_STAGE="$(mktemp -d)"
trap 'rm -rf "$NODE_OFFLINE" "$PROJECT_STAGE"' EXIT

[[ -d "$GEN" ]] || die "缺少 generated/；请先运行 scripts/14-render-node-configs.sh"
[[ -s "$GEN/common/etc/modules-load.d/10-kubernetes.conf" ]] ||
  die "缺少内核模块配置；请重新运行 scripts/14-render-node-configs.sh"
[[ -s "$ROOT/offline/SHA256SUMS" ]] || die "缺少 offline/SHA256SUMS"
[[ -d "$ROOT/offline/rpms" ]] || die "缺少离线 RPM"
[[ -s "$PKI/k8s-ca.crt" && -s "$PKI/k8s-ca-bundle.crt" ]] || die "缺少 PKI"
[[ -s "$KCFG/admin.conf" && -s "$KCFG/kube-proxy.conf" ]] || die "缺少 kubeconfig"

remote_exec() {
  local ip="$1"
  local command="$2"
  local quoted

  if [[ "$SSH_USER" == root ]]; then
    ssh -p "$SSH_PORT" -o BatchMode=yes "$SSH_USER@$ip" "$command"
  else
    printf -v quoted '%q' "$command"
    ssh -p "$SSH_PORT" -o BatchMode=yes "$SSH_USER@$ip" "sudo -n bash -c $quoted"
  fi
}

copy_file() {
  local ip="$1"
  local source_file="$2"
  local destination="$3"
  local mode="${4:-0644}"
  local temporary="/tmp/k8s-ha-$(basename "$source_file")"

  scp -P "$SSH_PORT" "$source_file" "$SSH_USER@$ip:$temporary"
  remote_exec "$ip" "install -m $mode '$temporary' '$destination' && rm -f '$temporary'"
}

prepare_node_offline() {
  rm -rf "$NODE_OFFLINE"
  mkdir -p "$NODE_OFFLINE"
  rsync -a \
    --exclude='/harbor/' \
    --exclude='/images/' \
    --exclude='/helm/' \
    "$ROOT/offline/" "$NODE_OFFLINE/"

  rm -f "$NODE_OFFLINE/SHA256SUMS"
  (
    cd "$NODE_OFFLINE"
    find bin src manifests checksums tools docker rpms -type f -print0 |
      sort -z |
      xargs -0 sha256sum > SHA256SUMS
  )
}

prepare_node_offline

prepare_project_stage() {
  rsync -a \
    --exclude='.git/' \
    --exclude='generated/' \
    --exclude='pki/' \
    --exclude='kubeconfigs/' \
    --exclude='offline/' \
    --exclude='config/cluster.env' \
    "$ROOT/" "$PROJECT_STAGE/"

  install -m 0600 "$ROOT/config/cluster.env" "$PROJECT_STAGE/config/cluster.env"
  sed -i -E 's#^export SSH_PASSWORD=.*#export SSH_PASSWORD=""#' \
    "$PROJECT_STAGE/config/cluster.env"
}

prepare_project_stage

NODES=("${ALL_NAMES[@]}")
IPS=("${ALL_IPS[@]}")

for i in "${!NODES[@]}"; do
  node="${NODES[$i]}"
  ip="${IPS[$i]}"
  source_dir="$GEN/$node"

  [[ -d "$source_dir" ]] || die "缺少节点配置目录：$source_dir"

  log "准备分发到 $node ($ip)"

  # 先通过 SCP 传输 RPM，安装 rsync 后再同步其余离线资源。
  remote_exec "$ip" "rm -rf /tmp/k8s-ha-rpms && install -d -m 0755 /tmp/k8s-ha-rpms"
  scp -P "$SSH_PORT" "$ROOT"/offline/rpms/*.rpm "$SSH_USER@$ip:/tmp/k8s-ha-rpms/"
  remote_exec "$ip" "dnf install -y --disablerepo='*' /tmp/k8s-ha-rpms/*.rpm && rm -rf /tmp/k8s-ha-rpms"

  rsync -az --delete -e "ssh -p $SSH_PORT" \
    "$NODE_OFFLINE/" "$SSH_USER@$ip:/tmp/k8s-ha-offline/"
  remote_exec "$ip" \
    "install -d -m 0755 '$REMOTE_ROOT/offline' && cp -a /tmp/k8s-ha-offline/. '$REMOTE_ROOT/offline/' && rm -rf /tmp/k8s-ha-offline"

  rsync -az --delete -e "ssh -p $SSH_PORT" \
    "$PROJECT_STAGE/" "$SSH_USER@$ip:/tmp/k8s-ha-project/"
  remote_exec "$ip" \
    "install -d -m 0755 '$REMOTE_ROOT' && cp -a /tmp/k8s-ha-project/. '$REMOTE_ROOT/' && rm -rf /tmp/k8s-ha-project"

  remote_exec "$ip" "install -d -m 0755 /etc/kubernetes/pki /etc/etcd/pki /etc/kubernetes /var/lib/kubelet /var/lib/kube-proxy"

  copy_file "$ip" "$source_dir/var/lib/kubelet/config.yaml" /var/lib/kubelet/config.yaml
  copy_file "$ip" "$source_dir/var/lib/kube-proxy/config.yaml" /var/lib/kube-proxy/config.yaml
  copy_file "$ip" "$source_dir/etc/kubernetes/cluster.env" /etc/kubernetes/cluster.env 0600
  copy_file "$ip" "$source_dir/etc/kubernetes/runtime.env" /etc/kubernetes/runtime.env 0600

  if [[ "$node" == worker-* ]]; then
    remote_exec "$ip" "install -d -m 0755 /etc/nginx"
    copy_file "$ip" "$source_dir/etc/nginx/nginx.conf" /etc/nginx/nginx.conf
  fi

  copy_file "$ip" "$GEN/common/etc/crictl.yaml" /etc/crictl.yaml
  copy_file "$ip" "$GEN/common/etc/modules-load.d/10-kubernetes.conf" /etc/modules-load.d/10-kubernetes.conf
  copy_file "$ip" "$GEN/common/etc/sysctl.d/95-kubernetes.conf" /etc/sysctl.d/95-kubernetes.conf

  if [[ "${RUNTIME_TYPE:-containerd}" == containerd ]]; then
    remote_exec "$ip" "install -d -m 0755 /etc/containerd /etc/containerd/certs.d/$HARBOR_HOST"
    copy_file "$ip" "$GEN/common/etc/containerd/config.toml" /etc/containerd/config.toml
    copy_file "$ip" "$GEN/common/etc/containerd/certs.d/$HARBOR_HOST/hosts.toml" \
      "/etc/containerd/certs.d/$HARBOR_HOST/hosts.toml"
  else
    remote_exec "$ip" "install -d -m 0755 /etc/docker"
    copy_file "$ip" "$GEN/common/etc/docker/daemon.json" /etc/docker/daemon.json
  fi

  copy_file "$ip" "$PKI/k8s-ca.crt" /etc/kubernetes/pki/k8s-ca.crt
  copy_file "$ip" "$PKI/k8s-ca-bundle.crt" /etc/kubernetes/pki/k8s-ca-bundle.crt
  copy_file "$ip" "$KCFG/kubelet-$node.conf" /etc/kubernetes/kubelet.conf 0600
  copy_file "$ip" "$KCFG/kube-proxy.conf" /etc/kubernetes/kube-proxy.conf 0600

  if [[ "$node" == master-* ]]; then
    MASTER_PKI=(
      apiserver.crt
      apiserver.key
      apiserver-kubelet-client.crt
      apiserver-kubelet-client.key
      front-proxy-ca.crt
      front-proxy-client.crt
      front-proxy-client.key
      apiserver-etcd-client.crt
      apiserver-etcd-client.key
      cluster-signer.crt
      cluster-signer.key
      sa.key
      sa.pub
    )

    for file in "${MASTER_PKI[@]}"; do
      [[ -s "$PKI/$file" ]] || die "缺少 Master 凭据：$PKI/$file"
      copy_file "$ip" "$PKI/$file" "/etc/kubernetes/pki/$file" 0600
    done

    copy_file "$ip" "$KCFG/controller-manager.conf" /etc/kubernetes/controller-manager.conf 0600
    copy_file "$ip" "$KCFG/scheduler.conf" /etc/kubernetes/scheduler.conf 0600

    for file in etcd-ca.crt "etcd-$node-server.crt" "etcd-$node-server.key" "etcd-$node-peer.crt" "etcd-$node-peer.key"; do
      [[ -s "$PKI/$file" ]] || die "缺少 etcd 凭据：$PKI/$file"
      copy_file "$ip" "$PKI/$file" "/etc/etcd/pki/$file" 0600
    done

    remote_exec "$ip" \
      "id etcd >/dev/null 2>&1 || useradd --system --home-dir /var/lib/etcd --shell /sbin/nologin etcd"
    remote_exec "$ip" "chown -R etcd:etcd /etc/etcd/pki && chmod 0750 /etc/etcd/pki"
  fi

  remote_exec "$ip" \
    "chmod 0600 /etc/kubernetes/cluster.env /etc/kubernetes/runtime.env /etc/kubernetes/*.conf && find /etc/kubernetes/pki -type f -name '*.key' -exec chmod 0600 {} +"

  ok "$node 项目、离线资源、运行时配置和所需凭据分发完成"
done

# Harbor 可部署在独立 Rocky Linux 9 主机；若不在 NODE_IPS 中，单独分发项目和所需 RPM。
HARBOR_IS_CLUSTER_NODE=0
for ip in "${ALL_IPS[@]}"; do
  [[ "$ip" == "$HARBOR_NODE_IP" ]] && HARBOR_IS_CLUSTER_NODE=1
done

if (( HARBOR_IS_CLUSTER_NODE == 0 )); then
  log "Harbor 使用独立节点 $HARBOR_NODE_IP，准备其基础依赖和安装脚本。"
  remote_exec "$HARBOR_NODE_IP" "rm -rf /tmp/k8s-ha-rpms && install -d -m 0755 /tmp/k8s-ha-rpms"
  scp -P "$SSH_PORT" "$ROOT"/offline/rpms/*.rpm "$SSH_USER@$HARBOR_NODE_IP:/tmp/k8s-ha-rpms/"
  remote_exec "$HARBOR_NODE_IP" \
    "dnf install -y --disablerepo='*' /tmp/k8s-ha-rpms/*.rpm && rm -rf /tmp/k8s-ha-rpms"

  rsync -az --delete -e "ssh -p $SSH_PORT" \
    "$PROJECT_STAGE/" "$SSH_USER@$HARBOR_NODE_IP:/tmp/k8s-ha-project/"
  remote_exec "$HARBOR_NODE_IP" \
    "install -d -m 0755 '$REMOTE_ROOT' && cp -a /tmp/k8s-ha-project/. '$REMOTE_ROOT/' && rm -rf /tmp/k8s-ha-project"
fi

# Harbor 与镜像归档只分发到指定 Harbor 节点，不复制到其他 Kubernetes 节点。
remote_exec "$HARBOR_NODE_IP" \
  "install -d -m 0755 '$REMOTE_ROOT/offline/docker' '$REMOTE_ROOT/offline/harbor' '$REMOTE_ROOT/offline/images'"
copy_file "$HARBOR_NODE_IP" "$ROOT/offline/docker/docker.tgz" "$REMOTE_ROOT/offline/docker/docker.tgz"
copy_file "$HARBOR_NODE_IP" "$ROOT/offline/docker/docker-compose" "$REMOTE_ROOT/offline/docker/docker-compose"
copy_file "$HARBOR_NODE_IP" \
  "$ROOT/offline/harbor/harbor-offline-installer-v${HARBOR_VERSION}-amd64.tgz" \
  "$REMOTE_ROOT/offline/harbor/harbor-offline-installer-v${HARBOR_VERSION}-amd64.tgz"
copy_file "$HARBOR_NODE_IP" "$ROOT/offline/harbor/SHA256SUMS" "$REMOTE_ROOT/offline/harbor/SHA256SUMS"
copy_file "$HARBOR_NODE_IP" \
  "$ROOT/offline/images/kubernetes-images-linux-amd64.tar" \
  "$REMOTE_ROOT/offline/images/kubernetes-images-linux-amd64.tar"
copy_file "$HARBOR_NODE_IP" \
  "$ROOT/offline/images/IMAGE-REFERENCES.txt" \
  "$REMOTE_ROOT/offline/images/IMAGE-REFERENCES.txt"

install -d -m 0700 "$HOME/.kube"
install -m 0600 "$KCFG/admin.conf" "$HOME/.kube/config"

ok "节点离线资源分发完成；Harbor 安装器与镜像归档仅发送到 $HARBOR_NODE_IP。"
ok "管理员 kubeconfig 已安装到部署机 $HOME/.kube/config。"
