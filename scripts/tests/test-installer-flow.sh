#!/usr/bin/env bash
# Guard the dependency order and the offline fast-install contract.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="$ROOT/scripts/00-install.sh"
NGINX="$ROOT/scripts/13-install-nginx-proxy.sh"
OFFLINE="$ROOT/scripts/01-prepare-offline.sh"
RENDER="$ROOT/scripts/14-render-node-configs.sh"
VERIFY="$ROOT/scripts/18-verify-cluster.sh"

contains() {
  local file="$1" text="$2"
  grep -Fq -- "$text" "$file" || {
    printf 'FAIL: %s does not contain: %s\n' "$file" "$text" >&2
    exit 1
  }
}

contains "$INSTALL" 'source "$ROOT/config/release-versions.env"'
contains "$INSTALL" 'all) validate_image_config; prepare_system; prepare_harbor; prepare_etcd; prepare_control_plane; prepare_workers; local_step calico 19-install-calico.sh; local_step coredns 20-install-coredns.sh; verify_cluster ;;'
contains "$INSTALL" 'wait_for_all_apis'
contains "$INSTALL" 'IMAGE_ARCHIVE_SHA256=$image_sha'
contains "$NGINX" 'NGINX_BINARY="$ROOT/offline/bin/nginx"'
contains "$NGINX" 'NGINX_CHECKSUM="$ROOT/offline/checksums/nginx.sha256"'
if grep -Fq 'curl ' "$NGINX"; then
  echo "FAIL: Worker NGINX installation must not require network access" >&2
  exit 1
fi
contains "$OFFLINE" '.offline-stage.XXXXXX'
contains "$RENDER" '.generated-stage.XXXXXX'
contains "$VERIFY" 'Node 数量与配置不一致'
contains "$VERIFY" 'CoreDNS kube-dns Service 没有可用 Endpoints'
contains "$ROOT/scripts/11-upgrade-node.sh" '当前版本暂不支持'

echo "Installer flow and offline quick-install tests passed."
