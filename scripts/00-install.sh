#!/usr/bin/env bash
# 统一部署入口：prepare 显式预处理；组件安装阶段只检查前置条件，不隐式安装依赖。
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
    find "$ROOT/scripts" -maxdepth 1 -type f -name "*.sh" -print0 | sort -z | xargs -0 -r sha256sum
    find "$ROOT/config" "$ROOT/manifests" "$ROOT/systemd" -type f -print0 2>/dev/null | sort -z | xargs -0 -r sha256sum
  } | sha256sum | awk '{print $1}'
}
local_healthy() {
  local id="$1"
  case "$id" in
    download) [[ -s "$ROOT/offline/SHA256SUMS" && -x "$ROOT/offline/bin/kubectl" && -x "$ROOT/offline/bin/cfssl" ]] && (cd "$ROOT/offline" && sha256sum -c SHA256SUMS >/dev/null 2>&1) ;;
    cli-tools) command -v helm >/dev/null && command -v calicoctl >/dev/null && command -v crictl >/dev/null && command -v cfssl >/dev/null ;;
    ssh-key)
      for ip in "${ALL_IPS[@]}"; do ssh -o BatchMode=yes -o ConnectTimeout=5 "root@$ip" true >/dev/null 2>&1 || return 1; done
      ;;
    pki) [[ -s "$ROOT/pki/k8s-ca.crt" && -s "$ROOT/pki/k8s-ca.key" && -s "$ROOT/pki/apiserver.crt" && -s "$ROOT/pki/sa.key" && -s "$ROOT/pki/sa.pub" ]] ;;
    kubeconfigs) [[ -s "$ROOT/kubeconfigs/admin.conf" && -s "$ROOT/kubeconfigs/kube-proxy.conf" ]] ;;
    render) [[ -s "$ROOT/generated/common/etc/modules-load.d/10-kubernetes.conf" && -s "$ROOT/generated/common/etc/sysctl.d/95-kubernetes.conf" && -s "$ROOT/generated/${MASTER_NAMES[0]}/etc/kubernetes/cluster.env" ]] ;;
    distribute)
      for ip in "${ALL_IPS[@]}"; do ssh -o BatchMode=yes -o ConnectTimeout=5 "root@$ip" "test -s /etc/kubernetes/cluster.env && test -s /opt/kubernetes-binary-ha/scripts/22-node-step.sh" >/dev/null 2>&1 || return 1; done
      ;;
    etcd-health) return 1 ;;
    calico) "$ROOT/offline/bin/kubectl" -n calico-system get ds calico-node >/dev/null 2>&1 && "$ROOT/offline/bin/kubectl" -n calico-system rollout status ds/calico-node --timeout=10s >/dev/null 2>&1 ;;
    coredns) "$ROOT/offline/bin/kubectl" -n kube-system rollout status deployment/coredns --timeout=10s >/dev/null 2>&1 ;;
    verify) return 1 ;;
    *) return 0 ;;
  esac
}
local_step() {
  local id="$1" script="$2" fp marker step_log
  fp="$(fingerprint "$script")"; marker="$STATE/steps/$id.done"; step_log="$LOGDIR/$id.log"
  if [[ -s "$marker" && "$(cat "$marker")" == "$fp" ]] && local_healthy "$id"; then
    ok "跳过本地阶段 $id（标记、指纹和健康状态均匹配）"; return 0
  fi
  log "开始本地阶段 $id：$script"
  run_local_script() {
    if [[ "$script" == "05-configure-ssh.sh" ]]; then
      bash "$ROOT/scripts/$script" 2>&1 | tee -a "$step_log"
    else
      bash "$ROOT/scripts/$script" >>"$step_log" 2>&1
    fi
  }
  if run_local_script; then
    printf '%s\n' "$fp" > "$marker"; chmod 0600 "$marker"
    rm -f "$STATE/steps/$id.failed"
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
validate_image_config() {
  [[ -n "$PRIVATE_REGISTRY" && "$PRIVATE_REGISTRY" != *example* ]] || die "请在 config/cluster.env 设置真实 PRIVATE_REGISTRY"
  [[ "$PAUSE_IMAGE" == "${PRIVATE_REGISTRY}/"* ]] || die "PAUSE_IMAGE 必须先镜像到 PRIVATE_REGISTRY：当前为 $PAUSE_IMAGE"
  [[ "$COREDNS_IMAGE" == "${PRIVATE_REGISTRY}/"* ]] || die "COREDNS_IMAGE 必须先镜像到 PRIVATE_REGISTRY：当前为 $COREDNS_IMAGE"
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
require_certificates() {
  local missing=0 file
  for file in \
    "$ROOT/pki/k8s-ca.crt" \
    "$ROOT/pki/apiserver.crt" \
    "$ROOT/pki/etcd-ca.crt" \
    "$ROOT/pki/sa.key" \
    "$ROOT/pki/sa.pub" \
    "$ROOT/kubeconfigs/admin.conf" \
    "$ROOT/kubeconfigs/kube-proxy.conf"; do
    if [[ ! -s "$file" ]]; then
      printf '  - %s\n' "$file" >&2
      missing=1
    fi
  done
  (( missing == 0 )) || die "缺少必要证书或 kubeconfig。请先执行：sudo bash scripts/00-install.sh prepare（本命令不会自动生成证书或安装前置依赖）"
  for node in "${MASTER_NAMES[@]}"; do
    for suffix in server.crt server.key peer.crt peer.key; do
      file="$ROOT/pki/etcd-$node-$suffix"
      if [[ ! -s "$file" ]]; then printf '  - %s\\n' "$file" >&2; missing=1; fi
    done
  done
  (( missing == 0 )) || die "缺少一个或多个 Master 的 etcd 成员证书/私钥。请先执行：sudo bash scripts/00-install.sh prepare"
  for ip in "${ALL_IPS[@]}"; do
    ssh -o BatchMode=yes -o ConnectTimeout=5 "root@$ip" \
      "test -s /etc/kubernetes/pki/k8s-ca.crt && test -s /etc/kubernetes/cluster.env" \
      >/dev/null 2>&1 || die "节点 $ip 尚未收到 Kubernetes CA 证书或集群配置。请先执行：sudo bash scripts/00-install.sh prepare"
  done
  for i in "${!MASTER_IPS[@]}"; do
    ip="${MASTER_IPS[$i]}"
    node="${MASTER_NAMES[$i]}"
    ssh -o BatchMode=yes -o ConnectTimeout=5 "root@$ip" \
      "test -s /etc/etcd/pki/etcd-ca.crt && test -s /etc/etcd/pki/etcd-$node-server.crt && test -s /etc/etcd/pki/etcd-$node-server.key && test -s /etc/etcd/pki/etcd-$node-peer.crt && test -s /etc/etcd/pki/etcd-$node-peer.key" \
      >/dev/null 2>&1 || die "Master $node ($ip) 尚未收到自己的 etcd server/peer 凭据。请先执行：sudo bash scripts/00-install.sh prepare"
  done
}
prepare_etcd() {
  require_certificates
  remote_step masters 07-bootstrap-etcd.sh
  local_step etcd-health 21-verify-etcd.sh
}
prepare_control_plane() {
  require_certificates
  local_step etcd-health 21-verify-etcd.sh
  remote_step masters 08-start-control-plane.sh
}
prepare_workers() {
  require_certificates
  remote_step workers 13-install-nginx-proxy.sh
  remote_step workers 09-start-worker.sh
}
prepare_calico() {
  validate_image_config
  prepare_workers
  local_step calico 19-install-calico.sh
}
prepare_coredns() {
  validate_image_config
  prepare_calico
  local_step coredns 20-install-coredns.sh
}
verify_cluster() { local_step verify 18-verify-cluster.sh; }
case "$TARGET" in
  prepare) prepare_system ;;
  download) prepare_download ;;
  ssh) prepare_ssh ;;
  certs) prepare_download; prepare_ssh; prepare_certs ;;
  system) prepare_system ;;
  etcd) prepare_etcd ;;
  control-plane) prepare_control_plane ;;
  workers) prepare_workers ;;
  calico) prepare_calico ;;
  coredns) prepare_coredns ;;
  verify) verify_cluster ;;
  status)
    printf '本地阶段标记目录：%s\n' "$STATE/steps"
    find "$STATE/steps" -maxdepth 1 -type f -printf '%f\n' | sort
    printf '远程节点标记位置：/var/lib/kubernetes-binary-ha/steps/（每台节点独立保存）\n'
    ;;
  all) validate_image_config; prepare_system; require_certificates; remote_step masters 07-bootstrap-etcd.sh; local_step etcd-health 21-verify-etcd.sh; remote_step masters 08-start-control-plane.sh; remote_step workers 13-install-nginx-proxy.sh; remote_step workers 09-start-worker.sh; local_step calico 19-install-calico.sh; local_step coredns 20-install-coredns.sh; verify_cluster ;;
  *) die "用法：$0 {all|prepare|download|ssh|certs|system|etcd|control-plane|workers|calico|coredns|verify|status}" ;;
esac
ok "目标阶段 $TARGET 执行结束。安装日志：$LOG"
