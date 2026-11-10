#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
OFF="${ROOT}/offline"
[[ -d "$OFF/rpms" ]] || die "缺少 offline/rpms；请先准备离线资源包"
(cd "$OFF" && sha256sum -c SHA256SUMS)
log "安装离线系统 RPM 依赖包"
dnf install -y --disablerepo="*" "$OFF"/rpms/*.rpm
if [[ "${KUBE_PROXY_MODE:-ipvs}" == nftables ]]; then command -v nft >/dev/null 2>&1 || die "离线 RPM 未安装 nftables/nft"; else command -v ipvsadm >/dev/null 2>&1 || die "离线 RPM 未安装 ipvsadm"; fi

install -d -m 0755 /usr/local/bin /usr/local/sbin /opt/cni/bin /etc/kubernetes
tar -xzf "$OFF/src/etcd.tar.gz" -C /tmp
ETCD_DIR="$(find /tmp -maxdepth 1 -type d -name "etcd-${ETCD_VERSION}-linux-amd64" | head -1)"
[[ -n "$ETCD_DIR" ]] || die "etcd 压缩包解压失败"
install -m 0755 "$ETCD_DIR/etcd" "$ETCD_DIR/etcdctl" "$ETCD_DIR/etcdutl" /usr/local/bin/
install -m 0755 "$OFF"/bin/{kube-apiserver,kube-controller-manager,kube-scheduler,kubelet,kube-proxy,kubectl} /usr/local/bin/
install -m 0755 "$OFF/bin/runc" /usr/local/sbin/runc
tar -xzf "$OFF/src/cni-plugins.tgz" -C /opt/cni/bin
tar -xzf "$OFF/src/crictl.tar.gz" -C /usr/local/bin crictl

case "${RUNTIME_TYPE:-containerd}" in
  containerd)
    tar -xzf "$OFF/src/containerd.tar.gz" -C /usr/local
    install -m 0644 "$ROOT/systemd/containerd.service" /etc/systemd/system/containerd.service
    install -d -m 0755 /etc/containerd
    containerd config default >/etc/containerd/config.toml
    # containerd 2.x：启用 systemd cgroup driver。
    if grep -q "SystemdCgroup = false" /etc/containerd/config.toml; then
      sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    else
      die "未在 containerd 默认配置中找到 SystemdCgroup 字段，请检查当前 containerd 版本配置格式"
    fi
    if grep -qE "^[[:space:]]*sandbox[[:space:]]*=" /etc/containerd/config.toml; then
      # containerd 2.x config v3 使用 pinned_images.sandbox。
      sed -i -E "s#^([[:space:]]*sandbox[[:space:]]*=[[:space:]]*).*$#\\1'$PAUSE_IMAGE'#" /etc/containerd/config.toml
    elif grep -qE "^[[:space:]]*sandbox_image[[:space:]]*=" /etc/containerd/config.toml; then
      # 兼容 containerd 1.x config v2。
      sed -i -E "s#^([[:space:]]*sandbox_image[[:space:]]*=[[:space:]]*).*$#\\1\"$PAUSE_IMAGE\"#" /etc/containerd/config.toml
    else
      die "无法在 containerd 配置中定位 sandbox/pause 镜像字段"
    fi
    CONTAINER_RUNTIME_ENDPOINT="unix:///run/containerd/containerd.sock"
    systemctl daemon-reload
    systemctl enable --now containerd
    ;;
  docker)
    [[ -f "$OFF/docker/docker.tgz" ]] || die "Docker 模式缺少 offline/docker/docker.tgz（Docker 静态二进制包）"
    [[ -f "$OFF/docker/cri-dockerd" ]] || die "Docker 模式缺少 offline/docker/cri-dockerd（cri-dockerd 可执行文件）"
    install -d -m 0755 /tmp/docker-runtime
    tar -xzf "$OFF/docker/docker.tgz" -C /tmp/docker-runtime
    [[ -d /tmp/docker-runtime/docker ]] || die "Docker 静态包目录结构不正确，预期包含 docker/ 子目录"
    install -m 0755 /tmp/docker-runtime/docker/* /usr/local/bin/
    install -m 0755 "$OFF/docker/cri-dockerd" /usr/local/bin/cri-dockerd
    getent group docker >/dev/null 2>&1 || groupadd --system docker
    install -m 0644 "$ROOT/systemd/docker.service" /etc/systemd/system/docker.service
    install -m 0644 "$ROOT/systemd/cri-docker.socket" /etc/systemd/system/cri-docker.socket
    install -m 0644 "$ROOT/systemd/cri-docker.service" /etc/systemd/system/cri-docker.service
    install -d -m 0755 /etc/docker
    cat >/etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "data-root": "$DOCKER_DATA_ROOT",
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": {"max-size": "100m", "max-file": "5"}
}
EOF
    CONTAINER_RUNTIME_ENDPOINT="unix:///run/cri-dockerd.sock"
    systemctl daemon-reload
    systemctl enable --now docker
    systemctl enable --now cri-docker.socket
    ;;
  *)
    die "RUNTIME_TYPE 仅支持 containerd 或 docker"
    ;;
esac

cat >/etc/crictl.yaml <<EOF
runtime-endpoint: ${CONTAINER_RUNTIME_ENDPOINT}
image-endpoint: ${CONTAINER_RUNTIME_ENDPOINT}
timeout: 10
debug: false
EOF
systemctl is-active --quiet "${RUNTIME_TYPE:-containerd}" || die "容器运行时服务未处于 active 状态"
ok "${RUNTIME_TYPE:-containerd} 运行时及 Kubernetes 二进制安装完成。CRI endpoint：${CONTAINER_RUNTIME_ENDPOINT}"
