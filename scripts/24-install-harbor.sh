#!/usr/bin/env bash
# 仅在 HARBOR_NODE_IP 指定的节点执行：离线安装 Harbor 并导入/推送基础集群镜像。
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"
# shellcheck disable=SC1090
source "$ROOT/config/release-versions.env"

require_root
require_cmd curl
require_cmd openssl
require_cmd tar
require_cmd jq

OFFLINE_DIR="$ROOT/offline"
HARBOR_ASSET="harbor-offline-installer-v${HARBOR_VERSION}-amd64.tgz"
IMAGE_ARCHIVE="$OFFLINE_DIR/images/kubernetes-images-linux-amd64.tar"
HARBOR_PACKAGE="$OFFLINE_DIR/harbor/$HARBOR_ASSET"
HARBOR_HOME="/opt/harbor"
CREDENTIAL_FILE="/root/harbor-credentials"
DOCKER_CONFIG="/etc/docker/daemon.json"

[[ -s "$HARBOR_PACKAGE" ]] || die "缺少 Harbor 离线安装器：$HARBOR_PACKAGE"
[[ -s "$IMAGE_ARCHIVE" ]] || die "缺少 Kubernetes 镜像归档：$IMAGE_ARCHIVE"
[[ "$HARBOR_URL" == "http://${HARBOR_HOST}" ]] ||
  die "当前 Harbor 部署模式仅支持 HTTP/80，HARBOR_URL 必须为 http://${HARBOR_HOST}"
[[ "$HARBOR_HTTP_PORT" == "80" ]] || die "当前 nip.io HTTP 部署仅支持 HARBOR_HTTP_PORT=80"
[[ "$PRIVATE_REGISTRY" == "${HARBOR_HOST}/library" ]] ||
  die "PRIVATE_REGISTRY 必须设置为 ${HARBOR_HOST}/library"

if ! ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$HARBOR_NODE_IP"; then
  die "当前节点未配置 HARBOR_NODE_IP=$HARBOR_NODE_IP；拒绝在错误节点安装 Harbor"
fi

install_docker_engine() {
  if ! command -v dockerd >/dev/null 2>&1; then
    local docker_tmp
    docker_tmp="$(mktemp -d)"
    tar -xzf "$OFFLINE_DIR/docker/docker.tgz" -C "$docker_tmp"
    [[ -d "$docker_tmp/docker" ]] || die "Docker 静态包结构不正确"
    install -m 0755 "$docker_tmp"/docker/* /usr/local/bin/
    rm -rf "$docker_tmp"
  fi

  install -d -m 0755 /usr/local/lib/docker/cli-plugins /etc/docker
  [[ -s "$OFFLINE_DIR/docker/docker-compose" ]] ||
    die "缺少离线 Docker Compose plugin"
  install -m 0755 "$OFFLINE_DIR/docker/docker-compose" \
    /usr/local/lib/docker/cli-plugins/docker-compose

  if [[ ! -s "$DOCKER_CONFIG" ]]; then
    printf '{}\\n' > "$DOCKER_CONFIG"
  fi
  jq empty "$DOCKER_CONFIG" >/dev/null ||
    die "$DOCKER_CONFIG 不是有效 JSON，拒绝覆盖"
  local tmp_config
  tmp_config="$(mktemp)"
  jq --arg registry "$HARBOR_HOST" '
    .["insecure-registries"] =
      (((.["insecure-registries"] // []) + [$registry]) | unique)
  ' "$DOCKER_CONFIG" > "$tmp_config"
  install -m 0644 "$tmp_config" "$DOCKER_CONFIG"
  rm -f "$tmp_config"

  if [[ ! -s /etc/systemd/system/docker.service ]]; then
    install -m 0644 "$ROOT/systemd/docker.service" \
      /etc/systemd/system/docker.service
  fi
  systemctl daemon-reload
  systemctl enable --now docker
  systemctl is-active --quiet docker ||
    die "Harbor 所需 Docker Engine 未能启动"
  docker compose version >/dev/null
}

create_or_load_credentials() {
  if [[ ! -s "$CREDENTIAL_FILE" ]]; then
    local admin_password database_password
    admin_password="$(openssl rand -hex 24)"
    database_password="$(openssl rand -hex 24)"
    {
      printf 'HARBOR_ADMIN_PASSWORD=%q\\n' "$admin_password"
      printf 'HARBOR_DATABASE_PASSWORD=%q\\n' "$database_password"
    } > "$CREDENTIAL_FILE"
    chmod 0600 "$CREDENTIAL_FILE"
  fi

  # shellcheck disable=SC1090
  source "$CREDENTIAL_FILE"
  : "${HARBOR_ADMIN_PASSWORD:?Harbor admin password is missing}"
  : "${HARBOR_DATABASE_PASSWORD:?Harbor database password is missing}"
}

configure_harbor() {
  if [[ ! -s "$HARBOR_HOME/harbor.yml.tmpl" ]]; then
    install -d -m 0755 "$HARBOR_HOME"
    tar -xzf "$HARBOR_PACKAGE" -C /opt
  fi
  [[ -s "$HARBOR_HOME/harbor.yml.tmpl" ]] ||
    die "Harbor 离线安装器未生成预期目录 /opt/harbor"

  if [[ ! -s "$HARBOR_HOME/harbor.yml" ]]; then
    cat > "$HARBOR_HOME/harbor.yml" <<EOF
hostname: ${HARBOR_HOST}

http:
  port: ${HARBOR_HTTP_PORT}

harbor_admin_password: ${HARBOR_ADMIN_PASSWORD}

database:
  password: ${HARBOR_DATABASE_PASSWORD}

data_volume: /data
EOF
    chmod 0600 "$HARBOR_HOME/harbor.yml"
  fi

  if ! docker ps --format '{{.Names}}' | grep -Fxq harbor-core; then
    log "执行 Harbor 离线安装器：${HARBOR_VERSION}"
    (
      cd "$HARBOR_HOME"
      ./install.sh
    )
  else
    log "检测到 Harbor core 容器已运行，跳过重复安装。"
  fi

  local attempt
  for attempt in {1..60}; do
    if curl --fail --silent "$HARBOR_URL/api/v2.0/ping" >/dev/null; then
      ok "Harbor API 已就绪：$HARBOR_URL"
      return 0
    fi
    sleep 5
  done
  die "Harbor 在 300 秒内未就绪；请检查 docker compose logs。"
}

publish_images() {
  local source_ref destination_ref
  local -a image_map

  image_map=(
    "registry.k8s.io/coredns/coredns:${COREDNS_VERSION}|${COREDNS_IMAGE}"
    "registry.k8s.io/pause:${PAUSE_VERSION}|${PAUSE_IMAGE}"
    "docker.io/calico/node:${CALICO_VERSION}|${CALICO_NODE_IMAGE}"
    "docker.io/calico/cni:${CALICO_VERSION}|${PRIVATE_REGISTRY}/calico/cni:${CALICO_VERSION}"
    "docker.io/calico/kube-controllers:${CALICO_VERSION}|${PRIVATE_REGISTRY}/calico/kube-controllers:${CALICO_VERSION}"
    "docker.io/calico/pod2daemon-flexvol:${CALICO_VERSION}|${PRIVATE_REGISTRY}/calico/pod2daemon-flexvol:${CALICO_VERSION}"
    "quay.io/tigera/operator:${CALICO_VERSION}|${PRIVATE_REGISTRY}/tigera/operator:${CALICO_VERSION}"
    "registry.k8s.io/dns/k8s-dns-node-cache:${NODE_LOCAL_DNS_VERSION}|${NODE_LOCAL_DNS_IMAGE}"
  )

  log "导入统一 Kubernetes 镜像归档。"
  docker load --input "$IMAGE_ARCHIVE"
  printf '%s\\n' "$HARBOR_ADMIN_PASSWORD" |
    docker login "$HARBOR_HOST" --username admin --password-stdin

  for entry in "${image_map[@]}"; do
    source_ref="${entry%%|*}"
    destination_ref="${entry#*|}"
    docker image inspect "$source_ref" >/dev/null ||
      die "镜像归档缺少预期镜像：$source_ref"
    docker tag "$source_ref" "$destination_ref"
    docker push "$destination_ref"
    log "已推送镜像：$destination_ref"
  done

  docker logout "$HARBOR_HOST" >/dev/null 2>&1 || true
}

install_docker_engine
create_or_load_credentials
configure_harbor
publish_images

cat > /var/lib/kubernetes-binary-ha-harbor.done <<EOF
HARBOR_VERSION=${HARBOR_VERSION}
HARBOR_URL=${HARBOR_URL}
PRIVATE_REGISTRY=${PRIVATE_REGISTRY}
IMAGE_ARCHIVE_SHA256=$(sha256sum "$IMAGE_ARCHIVE" | awk '{print $1}')
EOF
chmod 0600 /var/lib/kubernetes-binary-ha-harbor.done

warn "当前 Harbor 按 HTTP 部署，容器运行时配置为信任该 HTTP registry（insecure registry），并非 TLS CA 证书信任。"
ok "Harbor 安装及基础镜像导入完成。凭据保存在 $CREDENTIAL_FILE（权限 0600）。"
