#!/usr/bin/env bash
# 安全保护：当前仓库尚未实现经过验证的 Kubernetes/etcd 滚动升级编排。
set -Eeuo pipefail
cat >&2 <<'EOF'
当前版本暂不支持通过 scripts/11-upgrade-node.sh 执行节点二进制升级。

旧脚本会在缺少完整版本兼容性、备份回滚和控制平面逐台协调的情况下替换二进制，
可能造成 API Server / kubelet / kube-proxy 版本不一致或集群不可用。
请勿将新二进制直接复制到 /usr/local/bin，也不要手工删除 etcd 数据目录。

请先制定并验证 Kubernetes 版本偏差策略、etcd 快照与恢复、控制平面逐台升级、
Worker drain/uncordon、失败回滚及最终验收流程，再开放升级入口。
EOF
exit 1
