#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
[[ "$(uname -m)" == "x86_64" ]] || die "NGINX 构建目标架构必须为 amd64/x86_64"
ENGINE="${CONTAINER_ENGINE:-}"
if [[ -z "$ENGINE" ]]; then
  if command -v docker >/dev/null 2>&1; then ENGINE=docker
  elif command -v podman >/dev/null 2>&1; then ENGINE=podman
  else die "请在可联网的构建机安装 Docker 或 Podman"; fi
fi
command -v "$ENGINE" >/dev/null 2>&1 || die "未找到容器引擎： $ENGINE"
IMAGE="local/k8s-nginx-builder:${NGINX_VERSION}"
"$ENGINE" build --pull -t "$IMAGE" -f "$ROOT/nginx/Dockerfile" "$ROOT/nginx"
CID="$("$ENGINE" create "$IMAGE")"
cleanup(){ "$ENGINE" rm -f "$CID" >/dev/null 2>&1 || true; }
trap cleanup EXIT
mkdir -p "$ROOT/offline/bin"
"$ENGINE" cp "$CID:/nginx" "$ROOT/offline/bin/nginx"
chmod 0755 "$ROOT/offline/bin/nginx"
"$ROOT/offline/bin/nginx" -V 2>&1 | tee "$ROOT/offline/bin/nginx.build-info.txt"
sha256sum "$ROOT/offline/bin/nginx" > "$ROOT/offline/bin/nginx.sha256"
if [[ -f "$ROOT/offline/SHA256SUMS" ]]; then
  grep -v '  bin/nginx$' "$ROOT/offline/SHA256SUMS" > "$ROOT/offline/SHA256SUMS.tmp" || true
  mv "$ROOT/offline/SHA256SUMS.tmp" "$ROOT/offline/SHA256SUMS"
  (cd "$ROOT/offline" && sha256sum bin/nginx >> SHA256SUMS)
fi
if [[ -f "$ROOT/offline/ARTIFACTS.txt" ]]; then
  grep -v '^NGINX=' "$ROOT/offline/ARTIFACTS.txt" > "$ROOT/offline/ARTIFACTS.txt.tmp" || true
  mv "$ROOT/offline/ARTIFACTS.txt.tmp" "$ROOT/offline/ARTIFACTS.txt"
  printf 'NGINX=%s (源码编译并启用 stream 模块)\n' "$NGINX_VERSION" >> "$ROOT/offline/ARTIFACTS.txt"
fi
log "NGINX 二进制文件已导出到： $ROOT/offline/bin/nginx"
