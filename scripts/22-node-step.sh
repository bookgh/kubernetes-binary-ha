#!/usr/bin/env bash
# 节点端幂等执行包装器：成功后写入完成标记，失败保留失败记录。
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }
[[ $# -eq 2 ]] || { echo "usage: $0 <script.sh> <step-id>" >&2; exit 2; }
SCRIPT="$1"; STEP="$2"
[[ "$SCRIPT" == "$(basename "$SCRIPT")" && "$SCRIPT" == *.sh ]] || { echo "invalid script name" >&2; exit 2; }
[[ "$STEP" =~ ^[a-zA-Z0-9_.-]+$ ]] || { echo "invalid step id" >&2; exit 2; }
case "$SCRIPT" in
  00-preflight.sh|02-install-runtime.sh|06-install-systemd.sh|07-bootstrap-etcd.sh|08-start-control-plane.sh|09-start-worker.sh|13-install-nginx-proxy.sh) ;;
  *) echo "script not allowed: $SCRIPT" >&2; exit 2 ;;
esac
[[ -s "$ROOT/scripts/$SCRIPT" ]] || { echo "script not found: $SCRIPT" >&2; exit 1; }
STATE="/var/lib/kubernetes-binary-ha/steps"
LOGDIR="/var/log/kubernetes-binary-ha"
install -d -m 0700 "$STATE"
install -d -m 0750 "$LOGDIR"
exec 9>"/var/lib/kubernetes-binary-ha/step.lock"
flock -n 9 || { echo "another install step is running on this node" >&2; exit 1; }
fingerprint() {
  {
    sha256sum "$ROOT/scripts/$SCRIPT" "$ROOT/scripts/22-node-step.sh" "$ROOT/scripts/23-batch-step.sh" "$ROOT/config/cluster.env" "$ROOT/config/release-versions.env"
    [[ ! -f /etc/kubernetes/cluster.env ]] || sha256sum /etc/kubernetes/cluster.env
    [[ ! -f /etc/kubernetes/runtime.env ]] || sha256sum /etc/kubernetes/runtime.env
    [[ ! -f /etc/kubernetes/pki/k8s-ca.crt ]] || sha256sum /etc/kubernetes/pki/k8s-ca.crt
    [[ ! -f /etc/crictl.yaml ]] || sha256sum /etc/crictl.yaml
    for f in /var/lib/kubelet/config.yaml /var/lib/kube-proxy/config.yaml /etc/nginx/nginx.conf /etc/containerd/config.toml /etc/docker/daemon.json /etc/modules-load.d/10-kubernetes.conf /etc/sysctl.d/95-kubernetes.conf; do [[ ! -f "$f" ]] || sha256sum "$f"; done
    [[ ! -f "$ROOT/offline/SHA256SUMS" ]] || sha256sum "$ROOT/offline/SHA256SUMS"
    [[ ! -d "$ROOT/systemd" ]] || find "$ROOT/systemd" -type f -print0 | sort -z | xargs -0 -r sha256sum
    for d in /etc/kubernetes /etc/etcd/pki /etc/containerd /etc/docker /etc/nginx /var/lib/kubelet /var/lib/kube-proxy /etc/modules-load.d /etc/sysctl.d; do [[ ! -d "$d" ]] || find "$d" -type f -print0 | sort -z | xargs -0 -r sha256sum; done
  } | sha256sum | awk '{print $1}'
}
healthy() {
  case "$SCRIPT" in
    02-install-runtime.sh)
      source /etc/kubernetes/runtime.env 2>/dev/null || return 1
      systemctl is-active --quiet "$RUNTIME_TYPE" && crictl --runtime-endpoint "$CONTAINER_RUNTIME_ENDPOINT" info >/dev/null 2>&1
      ;;
    06-install-systemd.sh)
      [[ -s /etc/systemd/system/kubelet.service && -s /etc/systemd/system/kube-proxy.service && -s /etc/modules-load.d/10-kubernetes.conf ]]
      ;;
    07-bootstrap-etcd.sh) systemctl is-active --quiet etcd ;;
    08-start-control-plane.sh)
      systemctl is-active --quiet kube-apiserver && systemctl is-active --quiet kube-controller-manager && systemctl is-active --quiet kube-scheduler
      ;;
    09-start-worker.sh)
      systemctl is-active --quiet nginx-k8s-api && systemctl is-active --quiet kubelet && systemctl is-active --quiet kube-proxy
      ;;
    13-install-nginx-proxy.sh) systemctl is-active --quiet nginx-k8s-api ;;
    *) return 0 ;;
  esac
}
FP="$(fingerprint)"
DONE="$STATE/$STEP.done"
FAILED="$STATE/$STEP.failed"
LOG="$LOGDIR/$STEP.log"
if [[ -s "$DONE" && "$(cat "$DONE")" == "$FP" ]] && healthy; then
  echo "[SKIP] $STEP already completed with matching configuration on $(hostname -s)"
  exit 0
fi
printf '[START] %s %s %s\n' "$(date -Is)" "$STEP" "$(hostname -s)" | tee -a "$LOG"
if bash "$ROOT/scripts/$SCRIPT" >>"$LOG" 2>&1; then
  printf '%s\n' "$FP" > "$DONE"
  chmod 0600 "$DONE"
  rm -f "$FAILED"
  tail -n 8 "$LOG"
  printf '[DONE] %s on %s\n' "$STEP" "$(hostname -s)"
else
  rc=$?
  printf '%s rc=%s time=%s\n' "$FP" "$rc" "$(date -Is)" > "$FAILED"
  chmod 0600 "$FAILED"
  tail -n 80 "$LOG" >&2
  printf '[FAILED] %s on %s (rc=%s); see %s\n' "$STEP" "$(hostname -s)" "$rc" "$LOG" >&2
  exit "$rc"
fi
