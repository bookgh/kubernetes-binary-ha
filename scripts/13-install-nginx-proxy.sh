#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
[[ "$(hostname -s)" == worker-* ]] || die "Run only on worker nodes"
BIN="$ROOT/offline/bin/nginx"
[[ -x "$BIN" ]] || die "Missing built NGINX binary: $BIN (build on staging host first)"
id nginx >/dev/null 2>&1 || useradd --system --no-create-home --home-dir /nonexistent --shell /sbin/nologin nginx
install -d -m 0755 /usr/local/sbin /etc/nginx /var/log/nginx-k8s-api
install -m 0755 "$BIN" /usr/local/sbin/nginx
install -m 0644 "$ROOT/systemd/nginx-k8s-api.service" /etc/systemd/system/nginx-k8s-api.service
sed -e "s/__MASTER1_IP__/${MASTER1_IP}/g" \
    -e "s/__MASTER2_IP__/${MASTER2_IP}/g" \
    -e "s/__MASTER3_IP__/${MASTER3_IP}/g" \
    "$ROOT/config/nginx-stream.conf.template" > /etc/nginx/nginx.conf
chmod 0644 /etc/nginx/nginx.conf
/usr/local/sbin/nginx -t -c /etc/nginx/nginx.conf
systemctl daemon-reload
systemctl enable --now nginx-k8s-api
systemctl is-active --quiet nginx-k8s-api || die "nginx-k8s-api failed to start"
log "NGINX local API proxy installed on 127.0.0.1:${API_PORT}"
