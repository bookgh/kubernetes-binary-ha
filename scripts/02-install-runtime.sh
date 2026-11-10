#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
OFF="${ROOT}/offline"
[[ -d "$OFF/rpms" ]] || die "缺少 offline/rpms；请先在暂存机运行 01-prepare-offline.sh"
(cd "$OFF" && sha256sum -c SHA256SUMS)
install -d -m 0755 /usr/local/bin /usr/local/sbin /opt/cni/bin
tar -xzf "$OFF/src/containerd.tar.gz" -C /usr/local
install -m 0644 "$ROOT/systemd/containerd.service" /etc/systemd/system/containerd.service
tar -xzf "$OFF/src/etcd.tar.gz" -C /tmp
ETCD_DIR="$(find /tmp -maxdepth 1 -type d -name "etcd-${ETCD_VERSION}-linux-amd64" | head -1)"
[[ -n "$ETCD_DIR" ]] || die "etcd 压缩包解压失败"
install -m 0755 "$ETCD_DIR/etcd" "$ETCD_DIR/etcdctl" "$ETCD_DIR/etcdutl" /usr/local/bin/
install -m 0755 "$OFF/bin/runc" /usr/local/sbin/runc
tar -xzf "$OFF/src/cni-plugins.tgz" -C /opt/cni/bin
tar -xzf "$OFF/src/crictl.tar.gz" -C /usr/local/bin crictl
install -m 0755 "$OFF"/bin/{kube-apiserver,kube-controller-manager,kube-scheduler,kubelet,kube-proxy,kubectl} /usr/local/bin/
mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
# containerd 2.x 配置格式；请检查生成的配置并确认 CRI 插件已启用。
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sed -i -E "s#^([[:space:]]*sandbox_image[[:space:]]*=[[:space:]]*).*$#\1\\"${PAUSE_IMAGE}\\"#" /etc/containerd/config.toml
systemctl daemon-reload
systemctl enable --now containerd
crictl config runtime-endpoint unix:///run/containerd/containerd.sock
crictl config image-endpoint unix:///run/containerd/containerd.sock
ok "运行时和 Kubernetes 二进制文件安装完成。请检查 containerd 配置、CRI 插件和 pause 镜像。"
