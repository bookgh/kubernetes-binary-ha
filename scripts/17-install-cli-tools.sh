#!/usr/bin/env bash
# 在部署机安装 Helm、Calicoctl、crictl 与 CFSSL 客户端工具。
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
OFF="$ROOT/offline"
for f in "$OFF/bin/helm" "$OFF/bin/calicoctl" "$OFF/bin/cfssl" "$OFF/bin/cfssljson" "$OFF/src/crictl.tar.gz"; do
  [[ -s "$f" ]] || die "离线工具缺失：$f；请先运行 scripts/01-prepare-offline.sh"
done
install -d -m 0755 /usr/local/bin
install -m 0755 "$OFF/bin/helm" "$OFF/bin/calicoctl" "$OFF/bin/cfssl" "$OFF/bin/cfssljson" /usr/local/bin/
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
tar -xzf "$OFF/src/crictl.tar.gz" -C "$TMP" crictl
install -m 0755 "$TMP/crictl" /usr/local/bin/crictl
helm version --short
calicoctl version --client-only
crictl --version
cfssl version
ok "helm、calicoctl、crictl、cfssl 和 cfssljson 已安装到 /usr/local/bin。"
