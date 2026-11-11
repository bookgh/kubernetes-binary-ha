#!/usr/bin/env bash
# 兼容保护入口：当前架构不部署旧版 HAProxy/Keepalived/VIP。
set -Eeuo pipefail
cat >&2 <<'EOF'
当前拓扑不部署外部 HAProxy、Keepalived 或 VIP。
Master 上的 kube-apiserver 监听节点地址；Worker 使用本机 NGINX TCP/TLS 透传代理。
如需管理端 API 高可用入口，必须另行设计并验收外部 LB/VIP。
请阅读 README.md、docs/API-LOCAL-PROXY.md 和 docs/DEPLOYMENT-RUNBOOK.md。
EOF
exit 1
