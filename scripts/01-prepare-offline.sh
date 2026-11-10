#!/usr/bin/env bash
# 在可联网的 Rocky Linux 9 x86_64 暂存/构建机上运行。
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
[[ -f /etc/rocky-release ]] || die "请在 Rocky Linux 9 暂存机运行"
[[ "$(uname -m)" == "x86_64" ]] || die "暂存机 CPU 架构必须为 x86_64"
OUT="${ROOT}/offline"
mkdir -p "$OUT"/{bin,src,rpms,manifests,images,checksums}
dnf -y install dnf-plugins-core curl wget tar gzip jq
log "正在下载 Kubernetes ${K8S_VERSION}"
for b in kube-apiserver kube-controller-manager kube-scheduler kubelet kube-proxy kubectl; do
  url="https://dl.k8s.io/${K8S_VERSION}/bin/linux/amd64/${b}"
  curl -fL "$url" -o "$OUT/bin/$b"
  curl -fL "${url}.sha256" -o "$OUT/checksums/${b}.sha256"
  expected="$(tr -d '[:space:]' < "$OUT/checksums/${b}.sha256")"
  printf '%s  %s\n' "$expected" "$OUT/bin/$b" | sha256sum -c -
  chmod 0755 "$OUT/bin/$b"
done
if [[ "\${RUNTIME_TYPE:-containerd}" == docker ]]; then
  : "\${DOCKER_VERSION:?Docker 模式必须设置 DOCKER_VERSION}"
  : "\${CRI_DOCKERD_VERSION:?Docker 模式必须设置 CRI_DOCKERD_VERSION}"
  mkdir -p "$OUT/docker"
  log "正在下载 Docker Engine \${DOCKER_VERSION} 与 cri-dockerd \${CRI_DOCKERD_VERSION}"
  curl -fL --retry 4 --retry-all-errors "https://download.docker.com/linux/static/stable/x86_64/docker-\${DOCKER_VERSION}.tgz" -o "$OUT/docker/docker.tgz"
  curl -fL --retry 4 --retry-all-errors "https://github.com/Mirantis/cri-dockerd/releases/download/v\${CRI_DOCKERD_VERSION}/cri-dockerd-\${CRI_DOCKERD_VERSION}.amd64.tgz" -o "$OUT/docker/cri-dockerd.tgz"
  mkdir -p "$OUT/docker/unpack"
  tar -xzf "$OUT/docker/cri-dockerd.tgz" -C "$OUT/docker/unpack"
  CRI_BIN="$(find "$OUT/docker/unpack" -type f -name cri-dockerd -print -quit)"
  [[ -n "$CRI_BIN" ]] || die "cri-dockerd 压缩包中未找到 cri-dockerd 二进制"
  install -m 0755 "$CRI_BIN" "$OUT/docker/cri-dockerd"
  rm -rf "$OUT/docker/unpack"
fi
if [[ "\${RUNTIME_TYPE:-containerd}" == containerd ]]; then
log "正在下载 containerd \${CONTAINERD_VERSION}"
curl -fL "https://github.com/containerd/containerd/releases/download/v\${CONTAINERD_VERSION}/containerd-\${CONTAINERD_VERSION}-linux-amd64.tar.gz" -o "$OUT/src/containerd.tar.gz"
fi
log "正在下载 etcd ${ETCD_VERSION}"
curl -fL "https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-amd64.tar.gz" -o "$OUT/src/etcd.tar.gz"
log "正在下载 runc 和 CNI 插件"
curl -fL "https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.amd64" -o "$OUT/bin/runc"
curl -fL "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-amd64-${CNI_PLUGINS_VERSION}.tgz" -o "$OUT/src/cni-plugins.tgz"
curl -fL "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz" -o "$OUT/src/crictl.tar.gz"
chmod 0755 "$OUT/bin/runc"
log "正在下载 Calico 清单文件"
curl -fL "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml" -o "$OUT/manifests/tigera-operator.yaml"
cp "$ROOT/manifests/calico-custom-resources.yaml" "$OUT/manifests/custom-resources.yaml"
curl -fL "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/v3_projectcalico_org.yaml" -o "$OUT/manifests/calico-crds.yaml"
dnf -y download --resolve --alldeps --destdir "$OUT/rpms" chrony curl wget tar gzip jq openssl socat conntrack-tools ipset ipvsadm ebtables ethtool rsync policycoreutils-python-utils
(cd "$OUT" && find bin src rpms manifests docker -type f -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
cat >"$OUT/ARTIFACTS.txt" <<EOF
Kubernetes=${K8S_VERSION}
etcd=${ETCD_VERSION}
containerd=${CONTAINERD_VERSION}
runc=${RUNC_VERSION}
CNI_PLUGINS=${CNI_PLUGINS_VERSION}
crictl=${CRICTL_VERSION}
Calico=${CALICO_VERSION}
CoreDNS=${COREDNS_VERSION}
Architecture=amd64
EOF
log "离线资源已准备完成，目录： $OUT"
log "Build the NGINX proxy separately with scripts/12-build-nginx-binary.sh; transfer offline/bin/nginx to Workers."\nlog "重要：容器镜像需要单独准备。请阅读 docs/OFFLINE-IMAGES.md。"
