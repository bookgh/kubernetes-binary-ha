#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
OFF="${ROOT}/offline"
[[ -d "$OFF/rpms" ]] || die "缺少 offline/rpms；请先运行 scripts/01-prepare-offline.sh"
[[ -s /etc/kubernetes/runtime.env ]] || die "缺少部署端分发的 runtime.env；请先运行 scripts/15-distribute-node-configs.sh"
[[ -s /etc/crictl.yaml ]] || die "缺少部署端生成的 /etc/crictl.yaml"
# 运行时配置由部署端生成并分发；节点安装脚本只安装二进制和启动服务。
# shellcheck disable=SC1091
source /etc/kubernetes/runtime.env
(cd "$OFF" && sha256sum -c SHA256SUMS)
log "安装离线系统 RPM 依赖包"
dnf install -y --disablerepo="*" "$OFF"/rpms/*.rpm
if [[ "$KUBE_PROXY_MODE" == nftables ]]; then
  command -v nft >/dev/null 2>&1 || die "离线 RPM 未安装 nftables/nft"
else
  command -v ipvsadm >/dev/null 2>&1 || die "离线 RPM 未安装 ipvsadm"
fi

install -d -m 0755 /usr/local/bin /usr/local/sbin /opt/cni/bin /etc/kubernetes
ETCD_VERSION_NORMALIZED="${ETCD_VERSION#v}"
[[ "$ETCD_VERSION_NORMALIZED" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  die "ETCD_VERSION 格式无效：$ETCD_VERSION"
ETCD_TMP="$(mktemp -d)"
trap 'rm -rf "$ETCD_TMP"' EXIT
tar -xzf "$OFF/src/etcd.tar.gz" -C "$ETCD_TMP"
ETCD_DIR="$ETCD_TMP/etcd-${ETCD_VERSION_NORMALIZED}-linux-amd64"
[[ -x "$ETCD_DIR/etcd" && -x "$ETCD_DIR/etcdctl" && -x "$ETCD_DIR/etcdutl" ]] ||
  die "etcd ${ETCD_VERSION_NORMALIZED} 离线归档缺少 etcd/etcdctl/etcdutl"
install -m 0755 "$ETCD_DIR/etcd" "$ETCD_DIR/etcdctl" "$ETCD_DIR/etcdutl" /usr/local/bin/
install -m 0755 "$OFF"/bin/{kube-apiserver,kube-controller-manager,kube-scheduler,kubelet,kube-proxy,kubectl} /usr/local/bin/
install -m 0755 "$OFF/bin/runc" /usr/local/sbin/runc
tar -xzf "$OFF/src/cni-plugins.tgz" -C /opt/cni/bin
tar -xzf "$OFF/src/crictl.tar.gz" -C /usr/local/bin crictl

case "$RUNTIME_TYPE" in
  containerd)
    [[ -s "$OFF/src/containerd.tar.gz" ]] || die "containerd 模式缺少 offline/src/containerd.tar.gz"
    [[ -s /etc/containerd/config.toml ]] || die "缺少部署端生成的 /etc/containerd/config.toml"
    [[ -s "/etc/containerd/certs.d/${HARBOR_HOST}/hosts.toml" ]] ||
      die "缺少 Harbor HTTP registry 配置；请重新执行 prepare 并分发配置"
    grep -Fq 'config_path = "/etc/containerd/certs.d"' /etc/containerd/config.toml ||
      die "containerd 未启用 registry config_path"
    TMP_CONTAINERD="$(mktemp -d)"
    tar -xzf "$OFF/src/containerd.tar.gz" -C "$TMP_CONTAINERD"
    [[ -x "$TMP_CONTAINERD/bin/containerd" ]] || die "containerd 归档中未找到 bin/containerd"
    # 安装 containerd、ctr 和 containerd-shim-runc-v2 等配套二进制。
    for binary in "$TMP_CONTAINERD"/bin/*; do
      [[ -f "$binary" && -x "$binary" ]] || continue
      install -m 0755 "$binary" /usr/local/bin/
    done
    rm -rf "$TMP_CONTAINERD"
    install -m 0644 "$ROOT/systemd/containerd.service" /etc/systemd/system/containerd.service
    containerd --version
    containerd config dump >/dev/null || die "containerd 配置校验失败"
    systemctl daemon-reload
    systemctl enable --now containerd
    ;;
  docker)
    [[ -f "$OFF/docker/docker.tgz" ]] || die "Docker 模式缺少 offline/docker/docker.tgz"
    [[ -f "$OFF/docker/cri-dockerd" ]] || die "Docker 模式缺少 offline/docker/cri-dockerd"
    [[ -s /etc/docker/daemon.json ]] || die "缺少部署端生成的 /etc/docker/daemon.json"
    jq -e --arg registry "${HARBOR_HOST}" '.["insecure-registries"] | index($registry) != null' /etc/docker/daemon.json >/dev/null ||
      die "Docker daemon.json 未信任 Harbor HTTP registry"
    install -d -m 0755 /tmp/docker-runtime
    tar -xzf "$OFF/docker/docker.tgz" -C /tmp/docker-runtime
    [[ -d /tmp/docker-runtime/docker ]] || die "Docker 静态包目录结构不正确，预期包含 docker/ 子目录"
    install -m 0755 /tmp/docker-runtime/docker/* /usr/local/bin/
    install -m 0755 "$OFF/docker/cri-dockerd" /usr/local/bin/cri-dockerd
    install -d -m 0755 /usr/local/lib/docker/cli-plugins
    [[ -s "$OFF/docker/docker-compose" ]] || die "Release 中缺少 docker-compose 插件"
    install -m 0755 "$OFF/docker/docker-compose" /usr/local/lib/docker/cli-plugins/docker-compose
    ln -sf /usr/local/lib/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose
    getent group docker >/dev/null 2>&1 || groupadd --system docker
    install -m 0644 "$ROOT/systemd/docker.service" /etc/systemd/system/docker.service
    install -m 0644 "$ROOT/systemd/cri-docker.socket" /etc/systemd/system/cri-docker.socket
    install -m 0644 "$ROOT/systemd/cri-docker.service" /etc/systemd/system/cri-docker.service
    dockerd --validate --config-file=/etc/docker/daemon.json || die "Docker daemon.json 配置校验失败"
    systemctl daemon-reload
    systemctl enable --now docker
    systemctl enable --now cri-docker.socket
    ;;
  *) die "RUNTIME_TYPE 仅支持 containerd 或 docker" ;;
esac

systemctl is-active --quiet "$RUNTIME_TYPE" || die "容器运行时服务未处于 active 状态：$RUNTIME_TYPE"
crictl --runtime-endpoint "$CONTAINER_RUNTIME_ENDPOINT" info >/dev/null || die "CRI endpoint 无法连接：$CONTAINER_RUNTIME_ENDPOINT"
ok "$RUNTIME_TYPE 运行时及 Kubernetes 二进制安装完成。CRI endpoint：$CONTAINER_RUNTIME_ENDPOINT"
