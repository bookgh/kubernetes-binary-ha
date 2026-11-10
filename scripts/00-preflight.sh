#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
[[ -f /etc/rocky-release ]] || die "当前基线要求 Rocky Linux 9"
[[ "$(uname -m)" == x86_64 ]] || die "当前项目基线仅支持 amd64/x86_64"
KERNEL="$(uname -r | sed 's/-.*//')"
if [[ "${KUBE_PROXY_MODE:-ipvs}" == nftables ]]; then
  [[ "$(printf '%s\n' 5.13 "$KERNEL" | sort -V | head -n1)" == 5.13 ]] || die "nftables 模式要求 Linux kernel >= 5.13，当前为 $(uname -r)"
elif [[ "${KUBE_PROXY_MODE:-ipvs}" == ipvs ]]; then
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
