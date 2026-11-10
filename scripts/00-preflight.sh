#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
[[ -f /etc/rocky-release ]] || die "当前基线要求 Rocky Linux 9"
[[ "$(uname -m)" == x86_64 ]] || die "当前项目基线仅支持 amd64/x86_64"
KERNEL="$(uname -r | sed 's/-.*//')"
if [[ "${KUBE_PROXY_MODE:-ipvs}" == nftables ]]; then
  [[ "$(printf '%s\n' 5.13 "$KERNEL" | sort -V | head -n1)" == 5.13 ]] || die "nftables 模式要求 Linux kernel >= 5.13，当前为 $(uname -r)"
  command -v nft >/dev/null 2>&1 || die "nftables 模式需要 nft 命令；请检查离线 RPM"
  NFT_VERSION="$(nft --version | awk '{print $2}' | sed 's/^v//')"
  [[ "$(printf '%s\n' 1.0.1 "$NFT_VERSION" | sort -V | head -n1)" == 1.0.1 ]] || die "nftables 模式要求 nft >= 1.0.1，当前为 $NFT_VERSION"
elif [[ "${KUBE_PROXY_MODE:-ipvs}" == ipvs ]]; then
  warn "IPVS 模式自 Kubernetes v1.35 起已弃用；v1.40 起默认禁用，新部署建议优先选择 nftables"
  command -v ipvsadm >/dev/null 2>&1 || warn "尚未安装 ipvsadm；请确保离线 RPM 包含 ipvsadm"
  for module in ip_vs ip_vs_rr ip_vs_wrr ip_vs_sh nf_conntrack; do
    modprobe "$module" || die "无法加载 IPVS 内核模块：$module"
  done
else
  die "KUBE_PROXY_MODE 仅支持 ipvs 或 nftables"
fi
case "${RUNTIME_TYPE:-containerd}" in
  containerd|docker) ;;
  *) die "RUNTIME_TYPE 仅支持 containerd 或 docker" ;;
esac
ok "系统预检通过：kernel=$(uname -r)，runtime=${RUNTIME_TYPE:-containerd}，proxy=${KUBE_PROXY_MODE:-ipvs}"
