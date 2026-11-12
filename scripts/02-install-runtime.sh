#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
OFF="${ROOT}/offline"
[[ -s "$OFF/SHA256SUMS" ]] || die "缺少离线二进制资源或 SHA256SUMS；请先准备并分发 offline 资源"
[[ -s /etc/kubernetes/runtime.env ]] || die "缺少部署端分发的 runtime.env；请先运行 scripts/15-distribute-node-configs.sh"
[[ -s /etc/crictl.yaml ]] || die "缺少部署端生成的 /etc/crictl.yaml"
# 运行时配置由部署端生成并分发；节点安装脚本只安装二进制和启动服务。
# shellcheck disable=SC1091
source /etc/kubernetes/runtime.env
(cd "$OFF" && sha256sum -c SHA256SUMS)

# 安装阶段不是升级入口：若已有服务运行，必须确认其当前二进制版本与目标 Release 一致。
assert_active_version() {
  local service="$1" binary="$2" expected="$3" actual
  expected="${expected#v}"
  if systemctl is-active --quiet "$service"; then
    [[ -x "$binary" ]] || die "$service 正在运行，但找不到当前二进制 $binary；拒绝覆盖"
    actual="$("$binary" --version 2>&1 | grep -Eo 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -n1 | sed 's/^v//')" || actual=""
    [[ -n "$actual" && "$actual" == "$expected" ]] ||
      die "$service 当前版本为 ${actual:-unknown}，目标版本为 $expected；禁止通过安装脚本原地升级，请使用经过验证的滚动升级流程"
  fi
}
ETCD_VERSION_NORMALIZED="${ETCD_VERSION#v}"
assert_active_version etcd /usr/local/bin/etcd "$ETCD_VERSION_NORMALIZED"
for service in kube-apiserver kube-controller-manager kube-scheduler kubelet kube-proxy; do
  assert_active_version "$service" "/usr/local/bin/$service" "$K8S_VERSION"
done
if [[ "$RUNTIME_TYPE" == containerd ]]; then
  assert_active_version containerd /usr/local/bin/containerd "$CONTAINERD_VERSION"
else
  assert_active_version docker /usr/local/bin/docker "$DOCKER_VERSION"
  assert_active_version cri-docker /usr/local/bin/cri-dockerd "$CRI_DOCKERD_VERSION"
fi

# 容器运行时和 Kubernetes 组件使用 Release 提供的二进制归档安装；RPM 仅用于可选的系统依赖补齐。
# 节点已具备系统依赖时，不要求部署端额外分发 RPM 仓库。
if [[ -d "$OFF/rpms" ]] && compgen -G "$OFF/rpms/*.rpm" >/dev/null; then
  require_cmd dnf
  log "检测到离线 RPM 仓库，安装系统依赖包"
  dnf install -y --disablerepo="*" "$OFF"/rpms/*.rpm
else
  warn "未发现 offline/rpms，跳过可选的系统 RPM 安装；容器运行时仍从离线二进制归档安装"
fi

if [[ "$KUBE_PROXY_MODE" == nftables ]]; then
  command -v nft >/dev/null 2>&1 || die "缺少 nft 命令；请预装 nftables 或分发 offline/rpms 后重新执行"
else
  command -v ipvsadm >/dev/null 2>&1 || die "缺少 ipvsadm 命令；请预装 ipvsadm 或分发 offline/rpms 后重新执行"
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
