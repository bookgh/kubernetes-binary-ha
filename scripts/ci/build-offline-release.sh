#!/usr/bin/env bash
# GitHub Actions 唯一构建入口：下载、校验、源码构建 NGINX、打包二进制与 OCI 镜像。
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION_FILE="${ROOT}/config/release-versions.env"
CLUSTER_CONFIG="${ROOT}/config/cluster.env.example"
[[ -f "$VERSION_FILE" && -f "$CLUSTER_CONFIG" ]] || {
  printf '[错误] 缺少版本配置：%s 或 %s\n' "$VERSION_FILE" "$CLUSTER_CONFIG" >&2
  exit 1
}

# shellcheck disable=SC1090
source "$VERSION_FILE"
# Calico/CoreDNS app and chart versions live with cluster configuration.
# shellcheck disable=SC1090
source "$CLUSTER_CONFIG"
: "${CALICO_CHART_VERSION:?请在 config/cluster.env.example 定义 CALICO_CHART_VERSION}"
: "${COREDNS_CHART_VERSION:?请在 config/cluster.env.example 定义 COREDNS_CHART_VERSION}"

log() {
  printf '[信息] %s\n' "$*"
}

die() {
  printf '[错误] %s\n' "$*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

for cmd in curl sha256sum tar docker gh find sort xargs; do
  need "$cmd"
done

if [[ "${GITHUB_EVENT_NAME:-}" == "workflow_dispatch" ]]; then
  raw="${INPUT_VERSION:-}"
else
  raw="$(printf '%s\n%s\n' "${ISSUE_TITLE:-}" "${ISSUE_BODY:-}" |
    grep -Eo 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
fi

[[ "$raw" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  die "未找到有效版本号，格式应为 vX.Y.Z。"

K8S_VERSION="${raw#v}"
TAG="k8s-v${K8S_VERSION}-r${RELEASE_REVISION}"
: "${GH_TOKEN:?缺少 GH_TOKEN；请检查 Workflow 权限配置。}"

WORK="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT

OUT="${WORK}/offline-kubernetes-v${K8S_VERSION}-rocky9-amd64"
mkdir -p "$OUT"/{bin,src,manifests,checksums,tools,docker,rpms,harbor,images}

download() {
  local url="$1"
  local dest="$2"

  log "下载：$(basename "$dest")"
  curl --fail --location --retry 4 --retry-all-errors \
    --silent --show-error "$url" -o "$dest"
}

verify_k8s_binary() {
  local name="$1"
  local url="https://dl.k8s.io/v${K8S_VERSION}/bin/linux/amd64/$1"
  local expected

  download "$url" "$OUT/bin/$name"
  download "${url}.sha256" "$OUT/checksums/$name.sha256"

  expected="$(tr -d '[:space:]' < "$OUT/checksums/$name.sha256")"
  [[ "$expected" =~ ^[a-fA-F0-9]{64}$ ]] ||
    die "$name 的上游 SHA256 格式无效。"

  printf '%s  %s\n' "$expected" "$OUT/bin/$name" |
    sha256sum --check --status ||
    die "$name SHA256 校验失败。"

  chmod 0755 "$OUT/bin/$name"
}

for binary in kube-apiserver kube-controller-manager kube-scheduler kubelet kube-proxy kubectl; do
  verify_k8s_binary "$binary"
done

download "https://github.com/etcd-io/etcd/releases/download/v${ETCD_VERSION}/etcd-v${ETCD_VERSION}-linux-amd64.tar.gz" "$OUT/src/etcd.tar.gz"
download "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz" "$OUT/src/containerd.tar.gz"
download "https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.amd64" "$OUT/bin/runc"
chmod 0755 "$OUT/bin/runc"
download "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-amd64-${CNI_VERSION}.tgz" "$OUT/src/cni-plugins.tgz"
download "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz" "$OUT/src/crictl.tar.gz"

download "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" "$OUT/src/helm.tar.gz"
tar -xzf "$OUT/src/helm.tar.gz" -C "$WORK"
install -m 0755 "$WORK/linux-amd64/helm" "$OUT/bin/helm"

# Download the exact upstream Helm charts used by the offline installers.
mkdir -p "$OUT/helm" "$OUT/manifests/helm-rendered"
"$OUT/bin/helm" pull projectcalico.org.v3 \
  --repo https://docs.tigera.io/calico/charts \
  --version "$CALICO_CHART_VERSION" --destination "$OUT/helm"
"$OUT/bin/helm" pull tigera-operator \
  --repo https://docs.tigera.io/calico/charts \
  --version "$CALICO_CHART_VERSION" --destination "$OUT/helm"
"$OUT/bin/helm" pull coredns \
  --repo https://coredns.github.io/helm \
  --version "$COREDNS_CHART_VERSION" --destination "$OUT/helm"

CALICO_CRD_CHART="$OUT/helm/projectcalico.org.v3-${CALICO_CHART_VERSION}.tgz"
CALICO_OPERATOR_CHART="$OUT/helm/tigera-operator-${CALICO_CHART_VERSION}.tgz"
COREDNS_CHART="$OUT/helm/coredns-${COREDNS_CHART_VERSION}.tgz"
for chart in "$CALICO_CRD_CHART" "$CALICO_OPERATOR_CHART" "$COREDNS_CHART"; do
  [[ -s "$chart" ]] || die "缺少已下载的 Helm Chart：$chart"
done

# Kubernetes 1.36+ uses Calico's native v3 CRD chart.
"$OUT/bin/helm" template calico-crds "$CALICO_CRD_CHART" \
  --api-versions admissionregistration.k8s.io/v1/MutatingAdmissionPolicy \
  > "$OUT/manifests/helm-rendered/calico-crds.yaml"
"$OUT/bin/helm" template calico "$CALICO_OPERATOR_CHART" \
  --namespace tigera-operator \
  > "$OUT/manifests/helm-rendered/calico-operator.yaml"
"$OUT/bin/helm" template coredns "$COREDNS_CHART" \
  --namespace kube-system \
  --set image.repository=registry.k8s.io/coredns/coredns \
  --set-string "service.clusterIP=${DNS_SERVICE_IP}" \
  --set service.name=kube-dns \
  --set k8sAppLabelOverride=kube-dns \
  --set replicaCount=2 \
  --set priorityClassName=system-cluster-critical \
  --set 'tolerations[0].key=CriticalAddonsOnly' \
  --set 'tolerations[0].operator=Exists' \
  --set 'tolerations[1].key=node-role.kubernetes.io/control-plane' \
  --set 'tolerations[1].effect=NoSchedule' \
  --set-string "servers[0].plugins[3].parameters=${CLUSTER_DOMAIN} in-addr.arpa ip6.arpa" \
  > "$OUT/manifests/helm-rendered/coredns.yaml"

for rendered in "$OUT"/manifests/helm-rendered/*.yaml; do
  [[ -s "$rendered" ]] || die "Helm Chart 渲染结果为空：$rendered"
done

# Runtime-only images are declared for discovery; Calico workload images come from the operator.
{
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: offline-image-inventory
spec:
  containers:
EOF
  index=0
  for image_ref in "${OFFLINE_EXTRA_IMAGE_REFS[@]}"; do
    printf '  - name: image-%03d\n    image: "%s"\n' "$index" "$image_ref"
    index=$((index + 1))
  done
} > "$OUT/manifests/image-inventory.yaml"

# Harbor 官方离线安装器已包含 Harbor 自身所需的 OCI 镜像。
HARBOR_ASSET="harbor-offline-installer-v${HARBOR_VERSION}-amd64.tgz"
HARBOR_URL="https://github.com/goharbor/harbor/releases/download/v${HARBOR_VERSION}/${HARBOR_ASSET}"
download "$HARBOR_URL" "$OUT/harbor/$HARBOR_ASSET"
printf '%s  %s\n' "$HARBOR_SHA256" "$OUT/harbor/$HARBOR_ASSET" |
  sha256sum --check --status ||
  die "Harbor ${HARBOR_VERSION} 离线安装器 SHA256 校验失败。"


# Resolve Calico's dynamically generated workload images from the exact operator image
# rendered by the downloaded chart. This avoids stale hard-coded refs such as calico/cni.
log "从 Helm 渲染结果提取初始镜像引用。"
python3 "$ROOT/scripts/ci/extract-image-refs.py" --root "$OUT/manifests" --output "$WORK/initial-image-refs.txt"
OPERATOR_IMAGE="$(grep -E '/(tigera|calico)/operator:' "$WORK/initial-image-refs.txt" | head -n1 || true)"
[[ -n "$OPERATOR_IMAGE" ]] || die "Calico Helm Chart 渲染结果中未找到 Tigera Operator 镜像"
log "使用 Chart 实际引用的 Operator 获取 Calico 工作负载镜像清单：$OPERATOR_IMAGE"
docker pull --platform linux/amd64 "$OPERATOR_IMAGE" ||
  die "无法拉取 Calico Operator 镜像：$OPERATOR_IMAGE"
docker run --rm --platform linux/amd64 "$OPERATOR_IMAGE" --print-images=list \
  > "$WORK/calico-operator-images.txt" ||
  die "Calico Operator 无法输出 --print-images=list 镜像清单"

{
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: calico-dynamic-image-inventory
spec:
  containers:
EOF
  index=0
  while IFS= read -r image_ref; do
    [[ "$image_ref" =~ ^[A-Za-z0-9][A-Za-z0-9._:/@+-]*$ ]] || continue
    case "$image_ref" in
      calico/*)
        [[ "$image_ref" == *:* || "$image_ref" == *@* ]] || image_ref="${image_ref}:${CALICO_VERSION}"
        image_ref="quay.io/$image_ref"
        ;;
      tigera/operator)
        image_ref="quay.io/$image_ref:${TIGERA_OPERATOR_VERSION}"
        ;;
      tigera/*)
        [[ "$image_ref" == *:* || "$image_ref" == *@* ]] || image_ref="${image_ref}:${CALICO_VERSION}"
        image_ref="quay.io/$image_ref"
        ;;
      quay.io/calico/*)
        [[ "$image_ref" == *:* || "$image_ref" == *@* ]] || image_ref="${image_ref}:${CALICO_VERSION}"
        ;;
      quay.io/tigera/operator)
        image_ref="${image_ref}:${TIGERA_OPERATOR_VERSION}"
        ;;
      quay.io/tigera/*)
        [[ "$image_ref" == *:* || "$image_ref" == *@* ]] || image_ref="${image_ref}:${CALICO_VERSION}"
        ;;
    esac
    [[ "$image_ref" == */* && ( "$image_ref" == *:* || "$image_ref" == *@* ) ]] || continue
    printf '  - name: calico-image-%03d\n    image: "%s"\n' "$index" "$image_ref"
    index=$((index + 1))
  done < "$WORK/calico-operator-images.txt"
} > "$OUT/manifests/calico-dynamic-image-inventory.yaml"

grep -q 'image:' "$OUT/manifests/calico-dynamic-image-inventory.yaml" ||
  die "Calico Operator 未返回有效的、带 tag 的镜像引用"

log "从离线 Helm Chart 渲染结果和 Operator 动态清单提取全部镜像引用。"
python3 "$ROOT/scripts/ci/extract-image-refs.py" --root "$OUT/manifests" --output "$OUT/images/IMAGE-REFERENCES.txt"
mapfile -t IMAGE_REFS < "$OUT/images/IMAGE-REFERENCES.txt"
(("${#IMAGE_REFS[@]}" > 0)) || die "未从部署制品中提取到任何镜像引用"
if grep -Eq '/calico/(cni|kube-controllers|pod2daemon-flexvol|typha|ctl|apiserver|goldmane|dikastes|csi|node-driver-registrar|key-cert-provisioner|flannel-migration-controller|whisker-backend):' "$OUT/images/IMAGE-REFERENCES.txt"; then
  die "Calico 镜像清单仍包含 v3.33 已移除的旧镜像名，请检查 Operator 镜像版本。"
fi

log "拉取 linux/amd64 离线镜像（${#IMAGE_REFS[@]} 个）。"
for image_ref in "${IMAGE_REFS[@]}"; do
  docker pull --platform linux/amd64 "$image_ref" ||
    die "镜像拉取失败：$image_ref；请检查 Helm Chart、Operator 镜像清单和上游 tag。"
done

IMAGE_ARCHIVE="$OUT/images/kubernetes-images-linux-amd64.tar"
docker save --output "$IMAGE_ARCHIVE" "${IMAGE_REFS[@]}"
{
  while IFS= read -r image_ref; do
    digest="$(docker image inspect --format '{{index .RepoDigests 0}}' "$image_ref")"
    printf '%s\t%s\n' "$image_ref" "$digest"
  done < "$OUT/images/IMAGE-REFERENCES.txt"
} > "$OUT/images/IMAGE-REFERENCES.txt.tmp"
mv "$OUT/images/IMAGE-REFERENCES.txt.tmp" "$OUT/images/IMAGE-REFERENCES.txt"

# CFSSL、Helm、Calicoctl、Docker Engine 与 Compose 均作为 Release 离线资产。
download "https://github.com/cloudflare/cfssl/releases/download/v${CFSSL_VERSION}/cfssl_${CFSSL_VERSION}_linux_amd64" "$OUT/bin/cfssl"
download "https://github.com/cloudflare/cfssl/releases/download/v${CFSSL_VERSION}/cfssljson_${CFSSL_VERSION}_linux_amd64" "$OUT/bin/cfssljson"
chmod 0755 "$OUT/bin/cfssl" "$OUT/bin/cfssljson"
download "https://github.com/projectcalico/calico/releases/download/${CALICOCTL_VERSION}/calicoctl-linux-amd64" "$OUT/bin/calicoctl"
chmod 0755 "$OUT/bin/calicoctl"
download "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_VERSION}.tgz" "$OUT/docker/docker.tgz"
download "https://github.com/Mirantis/cri-dockerd/releases/download/v${CRI_DOCKERD_VERSION}/cri-dockerd-${CRI_DOCKERD_VERSION}.amd64.tgz" "$OUT/docker/cri-dockerd.tgz"
mkdir -p "$WORK/cri-dockerd"
tar -xzf "$OUT/docker/cri-dockerd.tgz" -C "$WORK/cri-dockerd"
CRI_DOCKERD_BIN="$(find "$WORK/cri-dockerd" -type f -name cri-dockerd -print -quit)"
[[ -n "$CRI_DOCKERD_BIN" ]] || die "cri-dockerd 压缩包中未找到可执行文件"
install -m 0755 "$CRI_DOCKERD_BIN" "$OUT/docker/cri-dockerd"
download "https://github.com/docker/compose/releases/download/v${DOCKER_COMPOSE_VERSION}/docker-compose-linux-x86_64" "$OUT/docker/docker-compose"
chmod 0755 "$OUT/docker/docker-compose"

log "在 Rocky Linux 9 容器中解析并下载离线 RPM 及其依赖。"
docker run --rm -v "$OUT/rpms:/rpms" rockylinux:9 bash -lc '
  dnf -y install dnf-plugins-core epel-release &&
  dnf -y download --resolve --alldeps --destdir=/rpms \
    chrony curl-minimal wget openssh-clients tar gzip jq openssl socat \
    conntrack-tools ipset ipvsadm iptables ebtables ethtool rsync \
    policycoreutils-python-utils container-selinux nftables sshpass sudo
'

log "使用仓库 Dockerfile 构建 NGINX ${NGINX_VERSION}（启用 stream）。"
docker build --pull \
  --build-arg "NGINX_VERSION=${NGINX_VERSION}" \
  --build-arg "NGINX_SHA256=${NGINX_SHA256}" \
  -t "local/k8s-nginx-builder:${NGINX_VERSION}" \
  -f "$ROOT/nginx/Dockerfile" "$ROOT/nginx"

CID="$(docker create "local/k8s-nginx-builder:${NGINX_VERSION}")"
trap 'docker rm -f "$CID" >/dev/null 2>&1 || true; cleanup' EXIT
NGINX_ASSET="nginx-${NGINX_VERSION}-linux-amd64"
docker cp "$CID:/nginx" "$WORK/$NGINX_ASSET"
docker rm "$CID" >/dev/null
trap cleanup EXIT
chmod 0755 "$WORK/$NGINX_ASSET"
"$WORK/$NGINX_ASSET" -V 2>&1 | tee "$OUT/NGINX-BUILD-INFO.txt"
(cd "$WORK" && sha256sum "$NGINX_ASSET" > "$NGINX_ASSET.sha256")
install -m 0755 "$WORK/$NGINX_ASSET" "$OUT/bin/nginx"
install -m 0644 "$WORK/$NGINX_ASSET.sha256" "$OUT/checksums/nginx.sha256"

# Harbor 节点独立校验清单只覆盖其安装所需的大体积资产。
(
  cd "$OUT"
  sha256sum \
    "docker/docker.tgz" \
    "docker/docker-compose" \
    "harbor/$HARBOR_ASSET" \
    "images/kubernetes-images-linux-amd64.tar" \
    "images/IMAGE-REFERENCES.txt" > "harbor/SHA256SUMS"
)

cat > "$OUT/ARTIFACTS.txt" <<EOF
Kubernetes=v${K8S_VERSION}
etcd=v${ETCD_VERSION}
containerd=${CONTAINERD_VERSION}
runc=v${RUNC_VERSION}
CNI_PLUGINS=${CNI_VERSION}
crictl=${CRICTL_VERSION}
CalicoChart=${CALICO_CHART_VERSION}
CoreDNSChart=${COREDNS_CHART_VERSION}
Pause=${PAUSE_VERSION}
NodeLocalDNS=${NODE_LOCAL_DNS_VERSION}
Harbor=${HARBOR_VERSION} (offline installer includes Harbor service images)
KubernetesImages=images/kubernetes-images-linux-amd64.tar
CFSSL=${CFSSL_VERSION}
Helm=${HELM_VERSION}
Calicoctl=${CALICOCTL_VERSION}
Docker=${DOCKER_VERSION}
cri-dockerd=${CRI_DOCKERD_VERSION}
DockerCompose=${DOCKER_COMPOSE_VERSION}
RockyLinux9_RPMs=Included
NGINX=${NGINX_VERSION} (Rocky Linux 9 source build with stream)
Architecture=amd64
OS=Rocky Linux 9
EOF

(cd "$OUT" && find bin src manifests checksums tools docker rpms harbor images helm -type f -print0 |
  sort -z | xargs -0 sha256sum > SHA256SUMS)

ARCHIVE="${WORK}/offline-kubernetes-v${K8S_VERSION}-rocky9-amd64.tar.gz"
tar -C "$WORK" -czf "$ARCHIVE" "$(basename "$OUT")"
(cd "$WORK" && sha256sum "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256")

if gh release view "$TAG" >/dev/null 2>&1; then
  die "Release ${TAG} 已存在；为保证不可变发布，不会覆盖。请提升版本号或人工处理旧 Release。"
fi

log "发布 Release ${TAG}。"
gh release create "$TAG" "$ARCHIVE" "$ARCHIVE.sha256" \
  "$WORK/$NGINX_ASSET" "$WORK/$NGINX_ASSET.sha256" \
  --title "Kubernetes v${K8S_VERSION} 离线资源包（Rocky Linux 9 amd64）" \
  --notes "离线包包含 Harbor ${HARBOR_VERSION} 官方离线安装器、Calico/CoreDNS Helm Charts、pause、Calico 和 NodeLocal DNS 镜像归档，以及 Kubernetes/etcd/containerd/CFSSL/Helm/Docker/NGINX 和 Rocky Linux 9 RPM。使用前请校验 SHA256。"
log "Release 发布完成：${TAG}"
