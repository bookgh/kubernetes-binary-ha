#!/usr/bin/env bash
# 统一部署入口：下载、SSH、系统准备、PKI、etcd、控制平面、Worker、CNI/DNS 和验收。
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
require_cmd flock
TARGET="${1:-all}"
STATE="/var/lib/kubernetes-binary-ha-controller"
LOGDIR="/var/log/kubernetes-binary-ha-install"
install -d -m 0700 "$STATE/steps"
install -d -m 0750 "$LOGDIR"
exec 9>"$STATE/install.lock"
flock -n 9 || die "已有安装任务正在运行；请勿并发启动第二个安装入口"
LOG="$LOGDIR/install-$(date +%Y%m%d-%H%M%S).log"
touch "$LOG"
log "统一安装入口启动：target=$TARGET，日志=$LOG"
fingerprint() {
  local script="$1"
  {
    sha256sum "$ROOT/scripts/$script" "$ROOT/config/cluster.env" "$ROOT/config/release-versions.env"
    find "$ROOT/config/cfssl" "$ROOT/manifests" -type f -print0 2>/dev/null | sort -z | xargs -0 -r sha256sum
  } | sha256sum | awk '{print $1}'
}
local_step() {
  local id="$1" script="$2" fp marker step_log
  fp="$(fingerprint "$script")"; marker="$STATE/steps/$id.done"; step_log="$LOGDIR/$id.log"
  if [[ -s "$marker" && "$(cat "$marker")" == "$fp" ]]; then
    ok "跳过本地阶段 $id（配置和脚本指纹未变化）"; return 0
  fi
  log "开始本地阶段 $id：$script"
  if bash "$ROOT/scripts/$script" >>"$step_log" 2>&1; then
    printf '%s\n' "$fp" > "$marker"; chmod 0600 "$marker"
    tail -n 10 "$step_log" | while IFS= read -r line; do printf '  %s\n' "$line"; done
    ok "本地阶段 $id 完成"
  else
    local rc=$?
    printf 'rc=%s time=%s\n' "$rc" "$(date -Is)" > "$STATE/steps/$id.failed"
    tail -n 80 "$step_log" >&2
    die "本地阶段 $id 失败；修复后重试，日志：$step_log"
  fi
}
ensure_host_rpms() {
  local marker="$STATE/steps/host-rpms.done" fp
  fp="$(fingerprint 01-prepare-offline.sh)"
  if [[ -s "$marker" && "$(cat "$marker")" == "$fp" ]]; then ok "跳过部署机 RPM 安装"; return; fi
  [[ -d "$ROOT/offline/rpms" ]] || die "缺少 offline/rpms，请先准备离线资源"
  log "在部署机安装 Release 内的 Rocky Linux 9 RPM"
  dnf install -y --disablerepo="*" "$ROOT"/offline/rpms/*.rpm
  for cmd in ssh scp rsync jq openssl curl tar sha256sum; do require_cmd "$cmd"; done
  printf '%s\n' "$fp" > "$marker"; chmod 0600 "$marker"
}
remote_step() { bash "$ROOT/scripts/23-batch-step.sh" "$1" "$2" --parallel >>"$LOG" 2>&1 || { tail -n 100 "$LOG" >&2; die "远程阶段失败：$2；修复后重新运行 scripts/00-install.sh $TARGET"; }; ok "远程阶段完成：$2"; }
prepare_download() {
  local_step download 01-prepare-offline.sh
  ensure_host_rpms
  local_step cli-tools 17-install-cli-tools.sh
}
prepare_ssh() { local_step ssh-key 05-configure-ssh.sh; }
prepare_certs() {
  local_step pki 03-generate-pki.sh
  local_step kubeconfigs 04-make-kubeconfigs.sh
  local_step render 14-render-node-configs.sh
  local_step distribute 15-distribute-node-configs.sh
}
prepare_system() {
  prepare_download
  prepare_ssh
  prepare_certs
  remote_step all 00-preflight.sh
  remote_step all 02-install-runtime.sh
  remote_step all 06-install-systemd.sh
}
prepare_etcd() {
  prepare_system
  remote_step masters 07-bootstrap-etcd.sh
  local_step etcd-health 21-verify-etcd.sh
}
prepare_control_plane() {
  prepare_etcd
  remote_step masters 08-start-control-plane.sh
}
prepare_workers() {
  prepare_control_plane
  remote_step workers 13-install-nginx-proxy.sh
  remote_step workers 09-start-worker.sh
}
prepare_calico() {
  prepare_workers
  [[ "$PRIVATE_REGISTRY" != *example* && "$PAUSE_IMAGE" != *example* ]] || die "请先在 config/cluster.env 配置真实可访问的 PRIVATE_REGISTRY 和 PAUSE_IMAGE"
  local_step calico 19-install-calico.sh
}
prepare_coredns() {
  prepare_calico
  [[ "$COREDNS_IMAGE" != *example* ]] || die "请先在 config/cluster.env 配置真实可访问的 COREDNS_IMAGE"
  local_step coredns 20-install-coredns.sh
}
verify_cluster() { local_step verify 18-verify-cluster.sh; }
case "$TARGET" in
  download) prepare_download ;;
  ssh) prepare_ssh ;;
  certs) prepare_ssh; prepare_certs ;;
  system) prepare_system ;;
  etcd) prepare_etcd ;;
  control-plane) prepare_control_plane ;;
  workers) prepare_workers ;;
  calico) prepare_calico ;;
  coredns) prepare_coredns ;;
  verify) verify_cluster ;;
  all) prepare_download; prepare_ssh; prepare_certs; remote_step all 00-preflight.sh; remote_step all 02-install-runtime.sh; remote_step all 06-install-systemd.sh; remote_step masters 07-bootstrap-etcd.sh; local_step etcd-health 21-verify-etcd.sh; remote_step masters 08-start-control-plane.sh; remote_step workers 13-install-nginx-proxy.sh; remote_step workers 09-start-worker.sh; [[ "$PRIVATE_REGISTRY" != *example* && "$PAUSE_IMAGE" != *example* && "$COREDNS_IMAGE" != *example* ]] || die "请先配置真实私有镜像仓库和 COREDNS_IMAGE/PAUSE_IMAGE"; local_step calico 19-install-calico.sh; local_step coredns 20-install-coredns.sh; verify_cluster ;;
  *) die "用法：$0 {all|download|ssh|certs|system|etcd|control-plane|workers|calico|coredns|verify}" ;;
esac
ok "目标阶段 $TARGET 执行结束。安装日志：$LOG"
