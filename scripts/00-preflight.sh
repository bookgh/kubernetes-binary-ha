#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
[[ -f /etc/rocky-release ]] || die "本部署基线仅支持 Rocky Linux 9"
grep -qE 'Rocky Linux release 9' /etc/rocky-release || die "系统版本必须为 Rocky Linux 9"
[[ "$(uname -m)" == "x86_64" ]] || die "CPU 架构必须为 x86_64/amd64"
log "开始应用操作系统基础设置"
OFF="${ROOT}/offline"
[[ -d "$OFF/rpms" ]] || die "缺少离线 RPM 包；请先在暂存机执行离线资源准备脚本"
dnf -y localinstall "$OFF"/rpms/*.rpm
systemctl enable --now chronyd
swapoff -a
sed -ri '/\sswap\s/s/^/#/' /etc/fstab
cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter
cat >/etc/sysctl.d/99-kubernetes.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 1048576
fs.file-max = 2097152
EOF
sysctl --system
timedatectl set-ntp true
ok "系统预检完成。请人工复核 firewalld、SELinux、NetworkManager 和路由策略。"
