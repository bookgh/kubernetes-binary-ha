#!/usr/bin/env bash
# 受控的单节点二进制替换辅助脚本。控制平面必须逐台升级。
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
: "${NEW_K8S_VERSION:?请设置 NEW_K8S_VERSION，并将已验证的二进制文件放入 offline/new-bin}"
[[ -d "${ROOT}/offline/new-bin" ]] || die "缺少 offline/new-bin 目录"
case "$NEW_K8S_VERSION" in v*) ;; *) die "版本号必须以 v 开头";; esac
log "目标节点：$(hostname -s)"
log "目标 Kubernetes 版本：${NEW_K8S_VERSION}"
log "升级前提：已完成 etcd 快照、已核对版本偏差策略、二进制文件已验证。"
warn "此脚本不会执行全局集群升级，也不会升级 etcd。"
read -r -p "确认替换本机 Kubernetes 二进制文件？请输入 YES： " ans
[[ "$ans" == YES ]] || exit 1
systemctl stop kubelet || true
for b in kube-apiserver kube-controller-manager kube-scheduler kubelet kube-proxy kubectl; do
  [[ -f "${ROOT}/offline/new-bin/$b" ]] && install -m 0755 "${ROOT}/offline/new-bin/$b" /usr/local/bin/
done
systemctl daemon-reload
systemctl start kubelet
log "请仅启动本节点实际部署的组件，并检查 /readyz 和节点健康状态。"
