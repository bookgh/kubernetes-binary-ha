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
CERT_CONFIG="$ROOT/config/cfssl/ca-config.json"
CLI_TOOLS="$ROOT/scripts/17-install-cli-tools.sh"
RENDER="$ROOT/scripts/14-render-node-configs.sh"

contains() {
  local file="$1" text="$2"
  grep -Fq -- "$text" "$file" || {
    printf 'FAIL: %s does not contain: %s\n' "$file" "$text" >&2
    exit 1
  }
}

contains "$INSTALL" 'source "$ROOT/config/release-versions.env"'
contains "$INSTALL" 'all) validate_image_config; prepare_node_local_dns; verify_cluster ;;'
contains "$INSTALL" 'wait_for_all_apis'
contains "$INSTALL" 'commands_ok=1'
contains "$INSTALL" '--skip-broken'
contains "$INSTALL" 'rpm -q "$package"'
contains "$INSTALL" 'RPM-HOST-ROOTS.txt'
contains "$INSTALL" 'prepare_system'
contains "$INSTALL" 'kubelet-<节点名>.conf'
contains "$INSTALL" 'file#"$ROOT"/'
contains "$ROOT/scripts/16-batch-exec.sh" 'SCRIPT_ARG="$2"'
contains "$ROOT/scripts/16-batch-exec.sh" 'scripts/02-install-runtime.sh'
contains "$ROOT/scripts/16-batch-exec.sh" 'ssh_remote "$ip" "cd'
contains "$ROOT/scripts/16-batch-exec.sh" 'scp -P "$SSH_PORT"'
contains "$ROOT/scripts/16-batch-exec.sh" '--copy'
contains "$INSTALL" 'local_healthy "$id"'
contains "$INSTALL" 'stage_fingerprint'
contains "$INSTALL" 'IMAGE_ARCHIVE_SHA256=$image_sha'
contains "$NGINX" 'NGINX_BINARY="$ROOT/offline/bin/nginx"'
contains "$NGINX" 'NGINX_CHECKSUM="$ROOT/offline/checksums/nginx.sha256"'
if grep -Fq 'curl ' "$NGINX"; then
  echo "FAIL: Worker NGINX installation must not require network access" >&2
  exit 1
fi
contains "$OFFLINE" '.offline-stage.XXXXXX'
contains "$OFFLINE" 'SHA256SUMS_SHA256=$CURRENT_SUMS_SHA'
contains "$OFFLINE" 'validate_offline_dir "$ROOT/offline"'
contains "$OFFLINE" 'rpms/repodata/repomd.xml'
contains "$OFFLINE" 'RPM-HOST-ROOTS.txt'
contains "$OFFLINE" 'MARKER_TMP="$ROOT/offline/.PREPARED.tmp.$$"'
contains "$ROOT/scripts/ci/build-offline-release.sh" 'createrepo_c /rpms'
contains "$ROOT/scripts/ci/build-offline-release.sh" 'RPM_NODE_PACKAGES'
contains "$ROOT/config/offline-rpm-packages.env" 'RPM_HOST_PACKAGES'
contains "$ROOT/config/offline-rpm-packages.env" '  gzip'
contains "$ROOT/config/offline-rpm-packages.env" 'RPM_NODE_PACKAGES'
contains "$ROOT/scripts/15-distribute-node-configs.sh" 'RPM-ROOTS.txt'
contains "$ROOT/scripts/15-distribute-node-configs.sh" '--skip-broken'
contains "$ROOT/scripts/15-distribute-node-configs.sh" 'required RPM missing:'
contains "$ROOT/scripts/15-distribute-node-configs.sh" 'kubelet-$node.conf'
contains "$RENDER" '.generated-stage.XXXXXX'
contains "$RENDER" 'sandbox = .*'
contains "$CLI_TOOLS" 'calicoctl version'
if grep -Fq -- 'calicoctl version --client-only' "$CLI_TOOLS"; then
  echo "FAIL: calicoctl does not support --client-only" >&2
  exit 1
fi
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
contains "$RELEASE" 'RELEASE_REVISION="8"'
contains "$CERT_CONFIG" '"expiry": "876000h"'
[[ "$(grep -Fc '"expiry": "876000h"' "$CERT_CONFIG")" -eq 4 ]] || {
  echo "FAIL: CA default and all three certificate profiles must use 100-year validity" >&2
  exit 1
}
if grep -Fq '"expiry": "8760h"' "$CERT_CONFIG"; then
  echo "FAIL: all certificate profiles must use 100-year validity" >&2
  exit 1
fi
echo "Installer flow, batch execution modes, NodeLocal DNS, Harbor image-pull and cross-node network tests passed."
