#!/usr/bin/env bash
# 在部署机/暂存机执行：下载并校验包含 Rocky Linux 9 RPM 的完整 GitHub Release 离线包。
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
# shellcheck disable=SC1090
source "$ROOT/config/release-versions.env"

: "${CALICO_CHART_VERSION:?请先将 config/cluster.env.example 中的 Calico Chart 版本同步到 config/cluster.env}"
: "${COREDNS_CHART_VERSION:?请先将 config/cluster.env.example 中的 CoreDNS Chart 版本同步到 config/cluster.env}"
[[ -f /etc/rocky-release ]] || die "请在 Rocky Linux 9 暂存机运行"
[[ "$(uname -m)" == x86_64 ]] || die "暂存机 CPU 架构必须为 x86_64"
for cmd in curl tar sha256sum; do command -v "$cmd" >/dev/null 2>&1 || { printf "missing required command: %s\n" "$cmd" >&2; exit 1; }; done

VERSION="${K8S_VERSION#v}"
TAG="k8s-v${VERSION}-r${RELEASE_REVISION}"
ARCHIVE_NAME="offline-kubernetes-v${VERSION}-rocky9-amd64.tar.gz"
ASSET_BASE="${GITHUB_RELEASE_BASE_URL:?请在 config/cluster.env 设置 GITHUB_RELEASE_BASE_URL}/${TAG}"

# 缓存键只依赖离线制品版本配置和实际影响资源包内容/布局的参数；
# SSH、节点 IP 等集群运行参数变化不应导致重新下载 2GB 离线包。
CACHE_KEY="$(
  {
    printf '%s\n' "$TAG" "${RUNTIME_TYPE:-containerd}" "${KUBE_PROXY_MODE:-nftables}" \
      "$CALICO_CHART_VERSION" "$COREDNS_CHART_VERSION"
    sha256sum "$ROOT/config/release-versions.env"
  } | sha256sum | awk '{print $1}'
)"
PREPARED_MARKER="$ROOT/offline/.PREPARED"
CURRENT_SUMS_SHA=""
if [[ -s "$ROOT/offline/SHA256SUMS" ]]; then
  CURRENT_SUMS_SHA="$(sha256sum "$ROOT/offline/SHA256SUMS" | awk '{print $1}')"
fi

validate_offline_dir() {
  local dir="$1"
  [[ -s "$dir/SHA256SUMS" && -s "$dir/ARTIFACTS.txt" ]] || return 1
  grep -Fxq "Kubernetes=$K8S_VERSION" "$dir/ARTIFACTS.txt" || return 1
  grep -Fxq "Harbor=$HARBOR_VERSION" "$dir/ARTIFACTS.txt" || return 1
  grep -Fxq "CalicoChart=$CALICO_CHART_VERSION" "$dir/ARTIFACTS.txt" || return 1
  grep -Fxq "CoreDNSChart=$COREDNS_CHART_VERSION" "$dir/ARTIFACTS.txt" || return 1
  grep -Fxq "Runtime=${RUNTIME_TYPE:-containerd}" "$dir/ARTIFACTS.txt" || return 1
  grep -Fxq "KubeProxyMode=${KUBE_PROXY_MODE:-nftables}" "$dir/ARTIFACTS.txt" || return 1
  [[ -s "$dir/harbor/harbor-offline-installer-v${HARBOR_VERSION}-amd64.tgz" ]] || return 1
  [[ -s "$dir/bin/nginx" && -s "$dir/checksums/nginx.sha256" ]] || return 1
  [[ -s "$dir/images/kubernetes-images-linux-amd64.tar" ]] || return 1
  [[ -d "$dir/rpms" ]] && compgen -G "$dir/rpms/*.rpm" >/dev/null || return 1
  for chart in \
    "$dir/helm/projectcalico.org.v3-${CALICO_CHART_VERSION}.tgz" \
    "$dir/helm/tigera-operator-${CALICO_CHART_VERSION}.tgz" \
    "$dir/helm/coredns-${COREDNS_CHART_VERSION}.tgz" \
    "$dir/helm/coredns-values.yaml"; do
    [[ -s "$chart" ]] || return 1
  done
  (cd "$dir" && sha256sum -c SHA256SUMS >/dev/null 2>&1) || return 1
}

# 仅当完成标记、版本配置、关键资产和全部 SHA256 均匹配时才跳过网络下载。
if [[ -s "$PREPARED_MARKER" && -d "$ROOT/offline" ]] &&
  grep -Fxq "TAG=$TAG" "$PREPARED_MARKER" &&
  grep -Fxq "CACHE_KEY=$CACHE_KEY" "$PREPARED_MARKER" &&
  grep -Fxq "SHA256SUMS_SHA256=$CURRENT_SUMS_SHA" "$PREPARED_MARKER" &&
  validate_offline_dir "$ROOT/offline"; then
  ok "离线资源已准备且校验通过，跳过重复下载和解压：$ROOT/offline"
  exit 0
fi

WORK="$(mktemp -d)"
OUT_STAGE="$(mktemp -d "$ROOT/.offline-stage.XXXXXX")"
cleanup() { rm -rf "$WORK"; [[ -z "$OUT_STAGE" ]] || rm -rf "$OUT_STAGE"; }
trap cleanup EXIT

log "从 Release 获取 Kubernetes ${K8S_VERSION} 离线资源包：${TAG}"
curl -fL --retry 4 --retry-all-errors "${ASSET_BASE}/${ARCHIVE_NAME}" -o "$WORK/$ARCHIVE_NAME"
curl -fL --retry 4 --retry-all-errors "${ASSET_BASE}/${ARCHIVE_NAME}.sha256" -o "$WORK/$ARCHIVE_NAME.sha256"
(cd "$WORK" && sha256sum --check "$ARCHIVE_NAME.sha256") || die "Release 离线包 SHA256 校验失败"

tar -xzf "$WORK/$ARCHIVE_NAME" -C "$WORK"
PACKAGE_DIR="$WORK/offline-kubernetes-v${VERSION}-rocky9-amd64"
[[ -d "$PACKAGE_DIR" ]] || die "Release 归档目录结构不符合预期"
(cd "$PACKAGE_DIR" && sha256sum -c SHA256SUMS) || die "Release 归档内部 SHA256 校验失败"

OUT="$OUT_STAGE"
mkdir -p "$OUT/docker"
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
Calicoctl=${CALICOCTL_VERSION}
Docker=${DOCKER_VERSION}
cri-dockerd=${CRI_DOCKERD_VERSION}
DockerCompose=${DOCKER_COMPOSE_VERSION}
Harbor=${HARBOR_VERSION}
CoreDNSChart=${COREDNS_CHART_VERSION}
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
validate_offline_dir "$OUT" || die "离线资源目录完整性或版本校验失败"
log "Release 二进制、RPM、Harbor 安装器及 Kubernetes 镜像归档均已校验。"

# 只有完整下载、解压、校验及必需资产检查全部通过后，才替换现有 offline/。
OLD_OUT="$ROOT/.offline-previous.$"
[[ ! -e "$OLD_OUT" ]] || die "发现未清理的离线资源备份目录：$OLD_OUT"
if [[ -e "$ROOT/offline" ]]; then mv "$ROOT/offline" "$OLD_OUT"; fi
if mv "$OUT_STAGE" "$ROOT/offline"; then
  OUT_STAGE=""
  rm -rf "$OLD_OUT"
else
  [[ ! -e "$OLD_OUT" ]] || mv "$OLD_OUT" "$ROOT/offline"
  die "切换离线资源目录失败；已尝试恢复旧版本"
fi
# 标记独立于 SHA256SUMS，先写临时文件再原子落盘；失败时下次会重新下载校验。
MARKER_TMP="$ROOT/offline/.PREPARED.tmp.$"
{
  printf 'TAG=%s\n' "$TAG"
  printf 'CACHE_KEY=%s\n' "$CACHE_KEY"
  printf 'SHA256SUMS_SHA256=%s\n' "$(sha256sum "$ROOT/offline/SHA256SUMS" | awk '{print $1}')"
} > "$MARKER_TMP"
chmod 0644 "$MARKER_TMP"
mv -f "$MARKER_TMP" "$PREPARED_MARKER"
ok "离线资源已原子切换并写入完成标记：$ROOT/offline。"
