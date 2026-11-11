#!/usr/bin/env bash
# 在部署机/暂存机执行：下载并校验包含 Rocky Linux 9 RPM 的完整 GitHub Release 离线包。
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
# shellcheck disable=SC1090
source "$ROOT/config/release-versions.env"
[[ -f /etc/rocky-release ]] || die "请在 Rocky Linux 9 暂存机运行"
[[ "$(uname -m)" == x86_64 ]] || die "暂存机 CPU 架构必须为 x86_64"
for cmd in curl tar sha256sum; do command -v "$cmd" >/dev/null 2>&1 || { printf "missing required command: %s\n" "$cmd" >&2; exit 1; }; done

VERSION="${K8S_VERSION#v}"
TAG="k8s-v${VERSION}-r${RELEASE_REVISION}"
ARCHIVE_NAME="offline-kubernetes-v${VERSION}-rocky9-amd64.tar.gz"
ASSET_BASE="${GITHUB_RELEASE_BASE_URL:?请在 config/cluster.env 设置 GITHUB_RELEASE_BASE_URL}/${TAG}"
WORK="$(mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

log "从 Release 获取 Kubernetes ${K8S_VERSION} 离线资源包：${TAG}"
curl -fL --retry 4 --retry-all-errors "${ASSET_BASE}/${ARCHIVE_NAME}" -o "$WORK/$ARCHIVE_NAME"
curl -fL --retry 4 --retry-all-errors "${ASSET_BASE}/${ARCHIVE_NAME}.sha256" -o "$WORK/$ARCHIVE_NAME.sha256"
(cd "$WORK" && sha256sum --check "$ARCHIVE_NAME.sha256") || die "Release 离线包 SHA256 校验失败"

tar -xzf "$WORK/$ARCHIVE_NAME" -C "$WORK"
PACKAGE_DIR="$WORK/offline-kubernetes-v${VERSION}-rocky9-amd64"
[[ -d "$PACKAGE_DIR" ]] || die "Release 归档目录结构不符合预期"
(cd "$PACKAGE_DIR" && sha256sum -c SHA256SUMS) || die "Release 归档内部 SHA256 校验失败"

OUT="${ROOT}/offline"
rm -rf "$OUT"
mkdir -p "$OUT" "$OUT/docker"
cp -a "$PACKAGE_DIR/." "$OUT/"

case "${RUNTIME_TYPE:-containerd}" in
  containerd)
    [[ -s "$OUT/src/containerd.tar.gz" ]] || die "Release 中缺少 containerd.tar.gz"
    ;;
  docker)
    [[ -s "$OUT/docker/docker.tgz" && -s "$OUT/docker/cri-dockerd" ]] || die "Release 中缺少 Docker Engine/cri-dockerd 离线资产"
    ;;
  *) die "RUNTIME_TYPE 仅支持 containerd 或 docker" ;;
esac

[[ -d "$OUT/rpms" ]] && compgen -G "$OUT/rpms/*.rpm" >/dev/null || die "Release 中缺少 Rocky Linux 9 离线 RPM 包"
log "使用 Release 内置 Rocky Linux 9 RPM 依赖包"

rm -f "$OUT/SHA256SUMS"
(cd "$OUT" && find bin src manifests checksums tools docker rpms harbor images helm -type f -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
cat >"$OUT/ARTIFACTS.txt" <<EOF
Kubernetes=${K8S_VERSION}
etcd=${ETCD_VERSION}
containerd=${CONTAINERD_VERSION}
runc=${RUNC_VERSION}
CNI=${CNI_VERSION}
crictl=${CRICTL_VERSION}
CFSSL=${CFSSL_VERSION}
Helm=${HELM_VERSION}
CalicoChart=${CALICO_CHART_VERSION}
Calico=${CALICO_VERSION}
TigeraOperator=${TIGERA_OPERATOR_VERSION}
Calicoctl=${CALICOCTL_VERSION}
Docker=${DOCKER_VERSION}
cri-dockerd=${CRI_DOCKERD_VERSION}
DockerCompose=${DOCKER_COMPOSE_VERSION}
Harbor=${HARBOR_VERSION}
CoreDNSChart=${COREDNS_CHART_VERSION}
CoreDNS=${COREDNS_VERSION}
Pause=${PAUSE_VERSION}
NodeLocalDNS=${NODE_LOCAL_DNS_VERSION}
Runtime=${RUNTIME_TYPE:-containerd}
KubeProxyMode=${KUBE_PROXY_MODE:-nftables}
RockyLinux9_RPMs=Included
Architecture=amd64
OS=Rocky Linux 9
Source=GitHub Release ${TAG}
EOF
log "离线资源准备完成：$OUT"
[[ -s "$OUT/harbor/harbor-offline-installer-v${HARBOR_VERSION}-amd64.tgz" ]] || die "缺少 Harbor 离线安装器"
[[ -s "$OUT/images/kubernetes-images-linux-amd64.tar" ]] || die "缺少 Kubernetes 镜像归档"
for chart in \
  "$OUT/helm/projectcalico.org.v3-${CALICO_CHART_VERSION}.tgz" \
  "$OUT/helm/tigera-operator-${CALICO_CHART_VERSION}.tgz" \
  "$OUT/helm/coredns-${COREDNS_CHART_VERSION}.tgz"; do
  [[ -s "$chart" ]] || die "Release 中缺少 Helm Chart：$chart"
done
log "Release 二进制、RPM、Harbor 安装器及 Kubernetes 镜像归档均已校验。"
