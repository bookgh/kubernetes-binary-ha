#!/usr/bin/env bash
set -Eeuo pipefail
cat >&2 <<'EOF'
当前拓扑已停用旧版 HAProxy/Keepalived 安装流程。
当前设计不部署外部负载均衡器或 VIP；Worker 使用本机 NGINX TCP 代理：
  scripts/12-build-nginx-binary.sh   （联网构建机）
  scripts/13-install-nginx-proxy.sh  （每台 Worker）
请阅读 README.md 和 docs/DEPLOYMENT-RUNBOOK.md。
EOF
exit 1
