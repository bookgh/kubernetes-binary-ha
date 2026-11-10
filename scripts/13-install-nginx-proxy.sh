#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
[[ "$(hostname -s)" == worker-* ]] || die "此脚本只能在 Worker 节点运行"
require_cmd curl
require_cmd sha256sum
: "${K8S_VERSION:?请在 config/cluster.env 中设置 K8S_VERSION}"
: "${NGINX_VERSION:?请在 config/cluster.env 中设置 NGINX_VERSION}"
K8S_VERSION="${K8S_VERSION#v}"
TAG="k8s-v${K8S_VERSION}-r${RELEASE_REVISION}"
ASSET="nginx-${NGINX_VERSION}-linux-amd64"
RELEASE_URL="https://github.com/bookgh/kubernetes-binary-ha/releases/download/${TAG}"
TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

log "从 GitHub Release ${TAG} 下载 NGINX ${NGINX_VERSION}。"
curl --fail --location --retry 4 --retry-all-errors --silent --show-error \
  "${RELEASE_URL}/${ASSET}" -o "$TMP/$ASSET"
curl --fail --location --retry 4 --retry-all-errors --silent --show-error \
  "${RELEASE_URL}/${ASSET}.sha256" -o "$TMP/$ASSET.sha256"
(
  cd "$TMP"
  sha256sum --check "$ASSET.sha256"
) || die "NGINX SHA256 校验失败，拒绝安装。"
chmod 0755 "$TMP/$ASSET"

id nginx >/dev/null 2>&1 || useradd --system --no-create-home --home-dir /nonexistent --shell /sbin/nologin nginx
install -d -m 0755 /usr/local/sbin /etc/nginx /var/log/nginx-k8s-api
install -m 0755 "$TMP/$ASSET" /usr/local/sbin/nginx
install -m 0644 "$ROOT/systemd/nginx-k8s-api.service" /etc/systemd/system/nginx-k8s-api.service
[[ -s /etc/nginx/nginx.conf ]] || die "缺少部署端生成的 NGINX 配置；请先运行 scripts/14-render-node-configs.sh 和 scripts/15-distribute-node-configs.sh"
chmod 0644 /etc/nginx/nginx.conf
/usr/local/sbin/nginx -t -c /etc/nginx/nginx.conf
systemctl daemon-reload
systemctl enable --now nginx-k8s-api
systemctl is-active --quiet nginx-k8s-api || die "nginx-k8s-api 服务启动失败"
ok "NGINX 已通过 Release 下载、校验并安装，监听 127.0.0.1:${API_PORT}。"
