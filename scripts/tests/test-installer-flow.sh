#!/usr/bin/env bash
# Guard the dependency order and the offline fast-install contract.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="$ROOT/scripts/00-install.sh"
NGINX="$ROOT/scripts/13-install-nginx-proxy.sh"
OFFLINE="$ROOT/scripts/01-prepare-offline.sh"
RENDER="$ROOT/scripts/14-render-node-configs.sh"
VERIFY="$ROOT/scripts/18-verify-cluster.sh"
NODE_LOCAL="$ROOT/scripts/25-install-node-local-dns.sh"
NETWORK_VERIFY="$ROOT/scripts/26-verify-network.sh"
RELEASE="$ROOT/config/release-versions.env"
RENDER="$ROOT/scripts/14-render-node-configs.sh"

contains() {
  local file="$1" text="$2"
  grep -Fq -- "$text" "$file" || {
    printf 'FAIL: %s does not contain: %s\n' "$file" "$text" >&2
    exit 1
  }
}

contains "$INSTALL" 'source "$ROOT/config/release-versions.env"'
contains "$INSTALL" 'all) validate_image_config; prepare_system; prepare_harbor; prepare_etcd; prepare_control_plane; prepare_workers; local_step calico 19-install-calico.sh; local_step coredns 20-install-coredns.sh; local_step node-local-dns 25-install-node-local-dns.sh; verify_cluster ;;'
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

contains "$INSTALL" 'local_step node-local-dns 25-install-node-local-dns.sh'
contains "$INSTALL" 'node-local-dns|nodelocaldns) prepare_node_local_dns ;;'
contains "$NODE_LOCAL" 'image: ${NODE_LOCAL_DNS_IMAGE}'
contains "$NODE_LOCAL" 'forward . ${DNS_SERVICE_IP}'
contains "$NODE_LOCAL" 'rollout status daemonset/node-local-dns'
contains "$RENDER" 'NODE_LOCAL_DNS_IP'
contains "$NETWORK_VERIFY" 'imagePullPolicy: Always'
contains "$NETWORK_VERIFY" 'nslookup kubernetes.default.svc.cluster.local'
contains "$NETWORK_VERIFY" 'cross-node-network-ok'
contains "$VERIFY" 'bash "$ROOT/scripts/26-verify-network.sh"'
contains "$RELEASE" 'docker.io/library/busybox:1.36.1'
echo "Installer flow, NodeLocal DNS, Harbor image-pull and cross-node network tests passed."
