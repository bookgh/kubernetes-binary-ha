#!/usr/bin/env bash
# 统一部署入口：prepare 显式预处理；组件安装阶段只检查前置条件，不隐式安装依赖。
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
# 统一加载离线资产版本；快速安装入口本身会使用 Harbor/Release 版本变量。
# shellcheck disable=SC1090
source "$ROOT/config/release-versions.env"
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
    if [[ "$script" == "24-install-harbor.sh" ]]; then
      for artifact in \
        "$ROOT/offline/harbor/harbor-offline-installer-v${HARBOR_VERSION}-amd64.tgz" \
        "$ROOT/offline/harbor/SHA256SUMS" \
        "$ROOT/offline/images/kubernetes-images-linux-amd64.tar" \
        "$ROOT/offline/images/IMAGE-REFERENCES.txt"; do
        [[ ! -s "$artifact" ]] || sha256sum "$artifact"
      done
    fi
    find "$ROOT/scripts" -maxdepth 1 -type f -name "*.sh" -print0 | sort -z | xargs -0 -r sha256sum
    find "$ROOT/config" "$ROOT/manifests" "$ROOT/systemd" -type f -print0 2>/dev/null | sort -z | xargs -0 -r sha256sum
    for artifact in "$ROOT/offline/SHA256SUMS" "$ROOT/offline/ARTIFACTS.txt"; do [[ ! -s "$artifact" ]] || sha256sum "$artifact"; done
  } | sha256sum | awk '{print $1}'
}
stage_fingerprint() {
  local id="$1" script="$2" dir
  {
    fingerprint "$script"
    case "$id" in
      pki) dir="$ROOT/pki";;
      kubeconfigs) dir="$ROOT/kubeconfigs";;
      render) dir="$ROOT/generated";;
      distribute) dir="";;
      *) dir="";;
    esac
    if [[ -n "$dir" && -d "$dir" ]]; then
      find "$dir" -type f -print0 | sort -z | xargs -0 -r sha256sum
    elif [[ "$id" == distribute ]]; then
      for dir in "$ROOT/pki" "$ROOT/kubeconfigs" "$ROOT/generated"; do
        if [[ -d "$dir" ]]; then find "$dir" -type f -print0 | sort -z | xargs -0 -r sha256sum; fi
      done
    fi
  } | sha256sum | awk '{print $1}'
}

local_healthy() {
  local id="$1"
  case "$id" in
    download)
      [[ -s "$ROOT/offline/SHA256SUMS" && -s "$ROOT/offline/ARTIFACTS.txt" && -x "$ROOT/offline/bin/kubectl" && -x "$ROOT/offline/bin/cfssl" && -x "$ROOT/offline/bin/nginx" ]] || return 1
      grep -Fxq "Kubernetes=$K8S_VERSION" "$ROOT/offline/ARTIFACTS.txt" || return 1
      grep -Fxq "Harbor=$HARBOR_VERSION" "$ROOT/offline/ARTIFACTS.txt" || return 1
      grep -Fxq "CalicoChart=$CALICO_CHART_VERSION" "$ROOT/offline/ARTIFACTS.txt" || return 1
      grep -Fxq "CoreDNSChart=$COREDNS_CHART_VERSION" "$ROOT/offline/ARTIFACTS.txt" || return 1
      grep -Fxq "Runtime=$RUNTIME_TYPE" "$ROOT/offline/ARTIFACTS.txt" || return 1
      grep -Fxq "NodeLocalDNS=$NODE_LOCAL_DNS_VERSION" "$ROOT/offline/ARTIFACTS.txt" || return 1
      grep -Fq 'docker.io/library/busybox:1.36.1' "$ROOT/offline/images/IMAGE-REFERENCES.txt" || return 1
      [[ -s "$ROOT/offline/helm/projectcalico.org.v3-${CALICO_CHART_VERSION}.tgz" && -s "$ROOT/offline/helm/tigera-operator-${CALICO_CHART_VERSION}.tgz" && -s "$ROOT/offline/helm/coredns-${COREDNS_CHART_VERSION}.tgz" && -s "$ROOT/offline/helm/coredns-values.yaml" ]] || return 1
      (cd "$ROOT/offline" && sha256sum -c SHA256SUMS >/dev/null 2>&1)
      ;;
    cli-tools) command -v helm >/dev/null && command -v calicoctl >/dev/null && command -v crictl >/dev/null && command -v cfssl >/dev/null ;;
    ssh-key)
      for ip in "${ALL_IPS[@]}"; do
        ssh_remote "$ip" true >/dev/null 2>&1 || return 1
      done
      ssh_remote "$HARBOR_NODE_IP" true >/dev/null 2>&1 || return 1
      ;;
    pki)
      [[ -s "$ROOT/pki/k8s-ca.crt" && -s "$ROOT/pki/k8s-ca.key" && -s "$ROOT/pki/apiserver.crt" && -s "$ROOT/pki/etcd-ca.crt" && -s "$ROOT/pki/sa.key" && -s "$ROOT/pki/sa.pub" ]] || return 1
      for node in "${MASTER_NAMES[@]}"; do
        for suffix in server.crt server.key peer.crt peer.key; do
          [[ -s "$ROOT/pki/etcd-$node-$suffix" ]] || return 1
        done
      done
      ;;
    kubeconfigs)
      [[ -s "$ROOT/kubeconfigs/admin.conf" && -s "$ROOT/kubeconfigs/kube-proxy.conf" && -s "$ROOT/kubeconfigs/controller-manager.conf" && -s "$ROOT/kubeconfigs/scheduler.conf" ]] || return 1
      for node in "${ALL_NAMES[@]}"; do [[ -s "$ROOT/kubeconfigs/kubelet-$node.conf" ]] || return 1; done
      ;;
    render)
      [[ -s "$ROOT/generated/common/etc/modules-load.d/10-kubernetes.conf" && -s "$ROOT/generated/common/etc/sysctl.d/95-kubernetes.conf" && -s "$ROOT/generated/common/etc/crictl.yaml" ]] || return 1
      if [[ "$RUNTIME_TYPE" == containerd ]]; then [[ -s "$ROOT/generated/common/etc/containerd/config.toml" && -s "$ROOT/generated/common/etc/containerd/certs.d/$HARBOR_HOST/hosts.toml" ]] || return 1; fi
      if [[ "$RUNTIME_TYPE" == docker ]]; then [[ -s "$ROOT/generated/common/etc/docker/daemon.json" ]] || return 1; fi
      for node in "${ALL_NAMES[@]}"; do
        [[ -s "$ROOT/generated/$node/etc/kubernetes/cluster.env" && -s "$ROOT/generated/$node/etc/kubernetes/runtime.env" && -s "$ROOT/generated/$node/var/lib/kubelet/config.yaml" && -s "$ROOT/generated/$node/var/lib/kube-proxy/config.yaml" ]] || return 1
        grep -Fq "  - $NODE_LOCAL_DNS_IP" "$ROOT/generated/$node/var/lib/kubelet/config.yaml" || return 1
        if [[ "$node" == worker-* ]]; then [[ -s "$ROOT/generated/$node/etc/nginx/nginx.conf" ]] || return 1; fi
      done
      ;;
    distribute)
      for i in "${!ALL_IPS[@]}"; do
        local ip="${ALL_IPS[$i]}" node="${ALL_NAMES[$i]}"
        ssh_remote "$ip" "test -s /etc/kubernetes/cluster.env && grep -Fxq 'NODE_LOCAL_DNS_IP=$NODE_LOCAL_DNS_IP' /etc/kubernetes/cluster.env && grep -Fq '  - $NODE_LOCAL_DNS_IP' /var/lib/kubelet/config.yaml && test -s /etc/kubernetes/runtime.env && test -s /var/lib/kubelet/config.yaml && test -s /var/lib/kube-proxy/config.yaml && test -s /etc/crictl.yaml && test -s /etc/modules-load.d/10-kubernetes.conf && test -s /etc/sysctl.d/95-kubernetes.conf && test -s /opt/kubernetes-binary-ha/scripts/22-node-step.sh" >/dev/null 2>&1 || return 1
        if [[ "$RUNTIME_TYPE" == containerd ]]; then ssh_remote "$ip" "test -s /etc/containerd/config.toml && test -s /etc/containerd/certs.d/$HARBOR_HOST/hosts.toml" >/dev/null 2>&1 || return 1; fi
        if [[ "$RUNTIME_TYPE" == docker ]]; then ssh_remote "$ip" "test -s /etc/docker/daemon.json" >/dev/null 2>&1 || return 1; fi
        if [[ "$node" == worker-* ]]; then ssh_remote "$ip" "test -s /etc/nginx/nginx.conf" >/dev/null 2>&1 || return 1; fi
      done
      ;;
    harbor)
      local image_sha
      image_sha="$(sha256sum "$ROOT/offline/images/kubernetes-images-linux-amd64.tar" | awk '{print $1}')" || return 1
      ssh_remote "$HARBOR_NODE_IP" "test -s /var/lib/kubernetes-binary-ha-harbor.done && grep -Fxq 'HARBOR_VERSION=$HARBOR_VERSION' /var/lib/kubernetes-binary-ha-harbor.done && grep -Fxq 'HARBOR_URL=$HARBOR_URL' /var/lib/kubernetes-binary-ha-harbor.done && grep -Fxq 'PRIVATE_REGISTRY=$PRIVATE_REGISTRY' /var/lib/kubernetes-binary-ha-harbor.done && grep -Fxq 'IMAGE_ARCHIVE_SHA256=$image_sha' /var/lib/kubernetes-binary-ha-harbor.done && curl --fail --silent '$HARBOR_URL/api/v2.0/ping' >/dev/null" >/dev/null 2>&1
      ;;
    etcd-health) return 1 ;;
    calico)
      "$ROOT/offline/bin/kubectl" -n tigera-operator rollout status deployment/tigera-operator --timeout=10s >/dev/null 2>&1 &&
        "$ROOT/offline/bin/kubectl" -n calico-system rollout status ds/calico-node --timeout=10s >/dev/null 2>&1 &&
        DATASTORE_TYPE=kubernetes KUBECONFIG="$HOME/.kube/config" calicoctl get ippools -o json 2>/dev/null | jq -e --arg cidr "$POD_CIDR" '[.items[] | select(.spec.cidr == $cidr)] | length == 1' >/dev/null
      ;;
    node-local-dns)
      local node_count ready_count
      "$ROOT/offline/bin/kubectl" -n kube-system rollout status ds/node-local-dns --timeout=10s >/dev/null 2>&1 || return 1
      node_count="$("$ROOT/offline/bin/kubectl" get nodes -o json 2>/dev/null | jq '.items | length')" || return 1
      ready_count="$("$ROOT/offline/bin/kubectl" -n kube-system get ds node-local-dns -o json 2>/dev/null | jq -r '.status.numberReady')" || return 1
      [[ "$ready_count" == "$node_count" ]]
      ;;
    coredns)
      local service_ip
      "$ROOT/offline/bin/kubectl" -n kube-system rollout status deployment/coredns --timeout=10s >/dev/null 2>&1 || return 1
      service_ip="$("$ROOT/offline/bin/kubectl" -n kube-system get service kube-dns -o jsonpath='{.spec.clusterIP}' 2>/dev/null)" || return 1
      [[ "$service_ip" == "$DNS_SERVICE_IP" ]] || return 1
      "$ROOT/offline/bin/kubectl" -n kube-system get endpoints kube-dns -o json 2>/dev/null | jq -e '[.subsets[]?.addresses[]?] | length > 0' >/dev/null
      ;;
    verify) return 1 ;;
    *) return 0 ;;
  esac
}
local_step() {
  local id="$1" script="$2" fp marker step_log
  fp="$(stage_fingerprint "$id" "$script")"; marker="$STATE/steps/$id.done"; step_log="$LOGDIR/$id.log"
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
    fp="$(stage_fingerprint "$id" "$script")"
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
  [[ "$NODE_LOCAL_DNS_IMAGE" == "${PRIVATE_REGISTRY}/"* ]] || die "NODE_LOCAL_DNS_IMAGE 必须指向 PRIVATE_REGISTRY：当前为 $NODE_LOCAL_DNS_IMAGE"
  [[ "$NETWORK_TEST_IMAGE" == "${PRIVATE_REGISTRY}/"* ]] || die "NETWORK_TEST_IMAGE 必须指向 PRIVATE_REGISTRY：当前为 $NETWORK_TEST_IMAGE"
  [[ "$PRIVATE_REGISTRY" == "${HARBOR_HOST}/library" ]] || die "PRIVATE_REGISTRY 必须设置为 ${HARBOR_HOST}/library"
}
remote_step() { bash "$ROOT/scripts/23-batch-step.sh" "$1" "$2" --parallel >>"$LOG" 2>&1 || { tail -n 100 "$LOG" >&2; die "远程阶段失败：$2；修复后重新运行 scripts/00-install.sh $TARGET"; }; ok "远程阶段完成：$2"; }
prepare_download() {
  local_step download 01-prepare-offline.sh
  ensure_host_rpms
  local_step cli-tools 17-install-cli-tools.sh
}
prepare_ssh() {
  ensure_host_rpms
  local_step ssh-key 05-configure-ssh.sh
}
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
  local missing=0 file expected_etcd_servers="" expected_initial_cluster="" i ip node suffix env_file nginx_file master_ip
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
      if [[ ! -s "$file" ]]; then printf '  - %s\n' "$file" >&2; missing=1; fi
    done
  done
  (( missing == 0 )) || die "缺少一个或多个 Master 的 etcd 成员证书/私钥。请先执行：sudo bash scripts/00-install.sh prepare"
  require_cmd openssl
  expected_etcd_servers=""
  expected_initial_cluster=""
  for i in "${!MASTER_IPS[@]}"; do
    ip="${MASTER_IPS[$i]}"
    node="${MASTER_NAMES[$i]}"
    [[ -n "$expected_etcd_servers" ]] && expected_etcd_servers+=","
    [[ -n "$expected_initial_cluster" ]] && expected_initial_cluster+=","
    expected_etcd_servers+="https://$ip:2379"
    expected_initial_cluster+="$node=https://$ip:2380"
    openssl x509 -in "$ROOT/pki/apiserver.crt" -noout -checkip "$ip" >/dev/null 2>&1 || die "API Server 证书 SAN 缺少 Master IP：$node ($ip)；请按证书轮换流程重新签发"
    openssl x509 -in "$ROOT/pki/etcd-$node-server.crt" -noout -checkhost "$node" >/dev/null 2>&1 || die "etcd server 证书 SAN 缺少节点名：$node"
    openssl x509 -in "$ROOT/pki/etcd-$node-server.crt" -noout -checkip "$ip" >/dev/null 2>&1 || die "etcd server 证书 SAN 缺少 IP：$node ($ip)"
    openssl x509 -in "$ROOT/pki/etcd-$node-peer.crt" -noout -checkhost "$node" >/dev/null 2>&1 || die "etcd peer 证书 SAN 缺少节点名：$node"
    openssl x509 -in "$ROOT/pki/etcd-$node-peer.crt" -noout -checkip "$ip" >/dev/null 2>&1 || die "etcd peer 证书 SAN 缺少 IP：$node ($ip)"
  done
  for node in "${ALL_NAMES[@]}"; do
    env_file="$ROOT/generated/$node/etc/kubernetes/cluster.env"
    [[ -s "$env_file" ]] || die "缺少节点生成配置：$env_file；请先执行 prepare"
    grep -Fxq "ETCD_SERVERS=$expected_etcd_servers" "$env_file" || die "$node 的 ETCD_SERVERS 与当前 MASTER_COUNT/节点 IP 不一致；请重新执行 prepare"
    grep -Fxq "ETCD_INITIAL_CLUSTER=$expected_initial_cluster" "$env_file" || die "$node 的 ETCD_INITIAL_CLUSTER 与当前 Master 清单不一致；请重新执行 prepare"
    if [[ "$node" == worker-* ]]; then
      nginx_file="$ROOT/generated/$node/etc/nginx/nginx.conf"
      [[ -s "$nginx_file" ]] || die "缺少 Worker NGINX 配置：$nginx_file；请重新执行 prepare"
      for ip in "${MASTER_IPS[@]}"; do
        grep -Fq "server $ip:6443" "$nginx_file" || die "$node 的 NGINX upstream 缺少 Master $ip；请重新执行 prepare"
      done
    fi
  done
  for i in "${!ALL_IPS[@]}"; do
    ip="${ALL_IPS[$i]}"
    node="${ALL_NAMES[$i]}"
    ssh_remote "$ip" \
      "test -s /etc/kubernetes/pki/k8s-ca.crt && grep -Fxq 'ETCD_SERVERS=$expected_etcd_servers' /etc/kubernetes/cluster.env && grep -Fxq 'ETCD_INITIAL_CLUSTER=$expected_initial_cluster' /etc/kubernetes/cluster.env" \
      >/dev/null 2>&1 || die "节点 $node ($ip) 的 Kubernetes CA 或动态 etcd 配置未更新。请先执行：sudo bash scripts/00-install.sh prepare"
    if [[ "$node" == worker-* ]]; then
      for master_ip in "${MASTER_IPS[@]}"; do
        ssh_remote "$ip" "grep -Fq 'server $master_ip:6443' /etc/nginx/nginx.conf" >/dev/null 2>&1 || die "Worker $node 的 NGINX upstream 缺少 Master $master_ip；请先执行 prepare"
      done
    fi
  done
  for i in "${!MASTER_IPS[@]}"; do
    ip="${MASTER_IPS[$i]}"
    node="${MASTER_NAMES[$i]}"
    ssh_remote "$ip" \
      "test -s /etc/etcd/pki/etcd-ca.crt && test -s /etc/etcd/pki/etcd-$node-server.crt && test -s /etc/etcd/pki/etcd-$node-server.key && test -s /etc/etcd/pki/etcd-$node-peer.crt && test -s /etc/etcd/pki/etcd-$node-peer.key" \
      >/dev/null 2>&1 || die "Master $node ($ip) 尚未收到自己的 etcd server/peer 凭据。请先执行：sudo bash scripts/00-install.sh prepare"
  done
}
ensure_harbor_ready() {
  local image_sha
  image_sha="$(sha256sum "$ROOT/offline/images/kubernetes-images-linux-amd64.tar" | awk '{print $1}')" ||
    die "无法读取本地 Harbor 镜像归档 SHA256"
  ssh_remote "$HARBOR_NODE_IP" \
    "test -s /var/lib/kubernetes-binary-ha-harbor.done && grep -Fxq 'HARBOR_VERSION=$HARBOR_VERSION' /var/lib/kubernetes-binary-ha-harbor.done && grep -Fxq 'HARBOR_URL=$HARBOR_URL' /var/lib/kubernetes-binary-ha-harbor.done && grep -Fxq 'PRIVATE_REGISTRY=$PRIVATE_REGISTRY' /var/lib/kubernetes-binary-ha-harbor.done && grep -Fxq 'IMAGE_ARCHIVE_SHA256=$image_sha' /var/lib/kubernetes-binary-ha-harbor.done && curl --fail --silent '$HARBOR_URL/api/v2.0/ping' >/dev/null" \
    >/dev/null 2>&1 ||
    die "Harbor 未部署、健康检查失败或导入的镜像归档与当前 Release 不一致。请先执行：sudo bash scripts/00-install.sh harbor"
}

prepare_harbor() {
  local fp marker
  validate_image_config
  fp="$(fingerprint 24-install-harbor.sh)"
  marker="$STATE/steps/harbor.done"
  [[ -s "$ROOT/offline/harbor/harbor-offline-installer-v${HARBOR_VERSION}-amd64.tgz" ]] ||
    die "缺少 Harbor 离线安装器；请先执行 download/prepare"
  [[ -s "$ROOT/offline/images/kubernetes-images-linux-amd64.tar" ]] ||
    die "缺少 Kubernetes 镜像归档；请先执行 download/prepare"

  if [[ -s "$marker" && "$(cat "$marker")" == "$fp" ]] && local_healthy harbor; then
    ok "跳过 Harbor 阶段（本地指纹、远程标记和 API 健康检查均匹配）"
    return 0
  fi

  log "在 Harbor 节点 $HARBOR_NODE_IP 部署 Harbor：$HARBOR_URL"
  ssh_remote "$HARBOR_NODE_IP" \
    "bash '/opt/kubernetes-binary-ha/scripts/24-install-harbor.sh'" >>"$LOG" 2>&1 ||
    {
      tail -n 100 "$LOG" >&2
      die "Harbor 部署失败；修复后运行 scripts/00-install.sh harbor 重试"
    }
  ensure_harbor_ready
  printf '%s\\n' "$fp" > "$marker"
  chmod 0600 "$marker"
  ok "Harbor 部署和基础镜像导入完成"
}

prepare_etcd() {
  ensure_harbor_ready
  require_certificates
  remote_step masters 07-bootstrap-etcd.sh
  local_step etcd-health 21-verify-etcd.sh
}
wait_for_all_apis() {
  local attempt ip all_ready
  for attempt in {1..60}; do
    all_ready=1
    for ip in "${MASTER_IPS[@]}"; do
      if ! ssh_remote "$ip" "curl --fail --silent --cacert /etc/kubernetes/pki/k8s-ca.crt --connect-timeout 3 --max-time 5 https://127.0.0.1:6443/readyz" >/dev/null 2>&1; then
        all_ready=0
        break
      fi
    done
    if (( all_ready == 1 )); then
      ok "全部 ${MASTER_COUNT} 个 Master API /readyz 均通过"
      return 0
    fi
    sleep 5
  done
  die "等待全部 Master API /readyz 超时；请检查 kube-apiserver、etcd、证书和本机 6443 监听"
}
prepare_control_plane() {
  require_certificates
  local_step etcd-health 21-verify-etcd.sh
  remote_step masters 08-start-control-plane.sh
  wait_for_all_apis
}
prepare_workers() {
  require_certificates
  wait_for_all_apis
  remote_step workers 13-install-nginx-proxy.sh
  remote_step workers 09-start-worker.sh
}
prepare_calico() {
  validate_image_config
  ensure_harbor_ready
  prepare_workers
  local_step calico 19-install-calico.sh
}
prepare_coredns() {
  validate_image_config
  prepare_calico
  local_step coredns 20-install-coredns.sh
}
prepare_node_local_dns() {
  validate_image_config
  ensure_harbor_ready
  prepare_coredns
  local_step node-local-dns 25-install-node-local-dns.sh
}
verify_cluster() { local_step verify 18-verify-cluster.sh; }
case "$TARGET" in
  prepare) prepare_system ;;
  download) prepare_download ;;
  ssh) prepare_ssh ;;
  certs) prepare_download; prepare_ssh; prepare_certs ;;
  system) prepare_system ;;
  harbor) prepare_harbor ;;
  etcd) prepare_etcd ;;
  control-plane) prepare_control_plane ;;
  workers) prepare_workers ;;
  calico) prepare_calico ;;
  coredns) prepare_coredns ;;
  node-local-dns|nodelocaldns) prepare_node_local_dns ;;
  verify) verify_cluster ;;
  status)
    printf '本地阶段标记目录：%s\n' "$STATE/steps"
    find "$STATE/steps" -maxdepth 1 -type f -printf '%f\n' | sort
    printf '远程节点标记位置：/var/lib/kubernetes-binary-ha/steps/（每台节点独立保存）\n'
    ;;
  all) validate_image_config; prepare_system; prepare_harbor; prepare_etcd; prepare_control_plane; prepare_workers; local_step calico 19-install-calico.sh; local_step coredns 20-install-coredns.sh; local_step node-local-dns 25-install-node-local-dns.sh; verify_cluster ;;
  *) die "用法：$0 {all|prepare|download|ssh|certs|system|harbor|etcd|control-plane|workers|calico|coredns|node-local-dns|verify|status}" ;;
esac
ok "目标阶段 $TARGET 执行结束。安装日志：$LOG"
