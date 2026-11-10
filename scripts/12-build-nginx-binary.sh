#!/usr/bin/env bash
set -Eeuo pipefail
cat >&2 <<'EOF'
NGINX 二进制现在统一由 GitHub Actions 自动构建并发布到 Kubernetes 对应版本的 Release。
本地不再执行 Docker/Podman 构建。请先完成 Issue + build-offline 标签触发 Release，
然后在 Worker 上执行：
  sudo bash scripts/13-install-nginx-proxy.sh
EOF
exit 1
