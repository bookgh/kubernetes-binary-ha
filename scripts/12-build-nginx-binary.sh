#!/usr/bin/env bash
# 兼容保护入口：NGINX 由 CI 构建并随离线 Release 打包。
set -Eeuo pipefail
cat >&2 <<'EOF'
NGINX 二进制由 GitHub Actions 构建并纳入离线 Release 的 offline/bin/nginx。
部署端会将离线包分发到 Worker；scripts/13-install-nginx-proxy.sh 校验 SHA256 和版本后本地安装。
Worker 不需要访问 GitHub，也不需要安装 Docker/Podman 或自行编译 NGINX。
请使用统一入口：
  sudo bash scripts/00-install.sh all
EOF
exit 1
