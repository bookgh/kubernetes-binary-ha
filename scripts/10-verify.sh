#!/usr/bin/env bash
# 兼容旧入口：统一使用部署端完整验收脚本，避免引用未分发的管理员凭据。
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec bash "$ROOT/scripts/18-verify-cluster.sh" "$@"
