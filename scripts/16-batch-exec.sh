#!/usr/bin/env bash
# 在部署机执行：将本地脚本及运行依赖复制到远程临时目录后执行。
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
require_cmd ssh
require_cmd scp
[[ $# -ge 2 ]] || die "用法：$0 <all|masters|workers> <scripts/script-name.sh> [--parallel]"

GROUP="$1"
SCRIPT_ARG="$2"
shift 2
PARALLEL=""
for arg in "$@"; do
  case "$arg" in
    --parallel) [[ -z "$PARALLEL" ]] || die "--parallel 不能重复"; PARALLEL=1 ;;
    *) die "不支持的参数：$arg（仅支持 --parallel）" ;;
  esac
done

# 只允许仓库 scripts/ 目录中的脚本，避免路径穿越。
[[ "$SCRIPT_ARG" == scripts/*.sh && "$SCRIPT_ARG" != *"/../"* && "$SCRIPT_ARG" != ../* ]] \
  || die "脚本参数必须是仓库根目录下 scripts/ 目录中的相对 .sh 路径，例如 scripts/02-install-runtime.sh"
SCRIPT_REL="$SCRIPT_ARG"
LOCAL_SCRIPT="$ROOT/$SCRIPT_REL"
LOCAL_LIB="$ROOT/scripts/lib.sh"
LOCAL_CONFIG="$ROOT/config/cluster.env"
[[ -f "$LOCAL_SCRIPT" ]] || die "本地不存在脚本：$LOCAL_SCRIPT"
[[ -f "$LOCAL_LIB" ]] || die "本地缺少脚本依赖：$LOCAL_LIB"
[[ -f "$LOCAL_CONFIG" ]] || die "本地缺少配置文件：$LOCAL_CONFIG"

case "$GROUP" in
  all)
    NODES=("${ALL_NAMES[@]}")
    IPS=("${ALL_IPS[@]}")
    ;;
  masters)
    NODES=("${MASTER_NAMES[@]}")
    IPS=("${MASTER_IPS[@]}")
    ;;
  workers)
    NODES=("${WORKER_NAMES[@]}")
    IPS=("${WORKER_IPS[@]}")
    ;;
  *) die "节点组仅支持 all、masters、workers" ;;
esac

# 按脚本职责准备资源，不再整目录复制 offline/generated/pki/kubeconfigs。
# 02-install-runtime 仅传输其执行所需的二进制归档、运行时配置和 systemd 单元。
BATCH_STAGE="$(mktemp -d)"
trap 'rm -rf "$BATCH_STAGE"' EXIT

if [[ "$SCRIPT_REL" == "scripts/02-install-runtime.sh" ]]; then
  require_cmd sha256sum
  [[ -s "$ROOT/offline/SHA256SUMS" ]] || die "部署机缺少 offline/SHA256SUMS；请先准备离线资源"
  (cd "$ROOT/offline" && sha256sum -c SHA256SUMS >/dev/null) || die "部署机离线资源校验失败"
  [[ -s "$ROOT/generated/common/etc/crictl.yaml" ]] || die "缺少运行时配置，请先运行 scripts/14-render-node-configs.sh"
  [[ -s "$ROOT/config/release-versions.env" ]] || die "缺少 config/release-versions.env"
  source "$ROOT/config/release-versions.env"
  for binary in kube-apiserver kube-controller-manager kube-scheduler kubelet kube-proxy kubectl runc; do
    [[ -s "$ROOT/offline/bin/$binary" ]] || die "缺少离线二进制：offline/bin/$binary"
  done
  for artifact in etcd.tar.gz cni-plugins.tgz crictl.tar.gz; do
    [[ -s "$ROOT/offline/src/$artifact" ]] || die "缺少离线资源：offline/src/$artifact"
  done
  case "$RUNTIME_TYPE" in
    containerd)
      [[ -s "$ROOT/offline/src/containerd.tar.gz" && -s "$ROOT/offline/bin/runc" ]] || die "缺少 containerd/runc 二进制资源"
      [[ -s "$ROOT/generated/common/etc/containerd/config.toml" ]] || die "缺少 generated/common/etc/containerd/config.toml；请先运行 scripts/14-render-node-configs.sh"
      [[ -s "$ROOT/generated/common/etc/containerd/certs.d/$HARBOR_HOST/hosts.toml" ]] || die "缺少 containerd Harbor hosts.toml"
      [[ -s "$ROOT/systemd/containerd.service" ]] || die "缺少 systemd/containerd.service"
      ;;
    docker)
      [[ -s "$ROOT/offline/docker/docker.tgz" && -s "$ROOT/offline/docker/cri-dockerd" && -s "$ROOT/offline/docker/docker-compose" ]] || die "缺少 Docker/cri-dockerd 离线二进制资源"
      [[ -s "$ROOT/generated/common/etc/docker/daemon.json" ]] || die "缺少 generated/common/etc/docker/daemon.json；请先运行 scripts/14-render-node-configs.sh"
      for unit in docker.service cri-docker.socket cri-docker.service; do [[ -s "$ROOT/systemd/$unit" ]] || die "缺少 systemd/$unit"; done
      ;;
    *) die "RUNTIME_TYPE 仅支持 containerd 或 docker" ;;
  esac
  for node in "${NODES[@]}"; do
    [[ -s "$ROOT/generated/$node/etc/kubernetes/runtime.env" ]] || die "缺少节点运行时配置 generated/$node/etc/kubernetes/runtime.env；请先运行 scripts/14-render-node-configs.sh"
  done
fi
REMOTE_TMP="/tmp/kubernetes-binary-ha-$(basename "$SCRIPT_REL" .sh)-$$"

run_node() {
  local node="$1" ip="$2" remote_cmd
  log "创建远程临时目录并复制脚本、lib.sh 和 cluster.env -> $node ($ip)"
  # 非 root SSH 用户需要能够写入临时目录，执行阶段仍通过 ssh_remote 提权。
  ssh_remote "$ip" "mkdir -p '$REMOTE_TMP/scripts' '$REMOTE_TMP/config' && chown -R '$SSH_USER' '$REMOTE_TMP'"
  scp -P "$SSH_PORT" -o BatchMode=yes \
    "$LOCAL_SCRIPT" "$LOCAL_LIB" "$SSH_USER@$ip:$REMOTE_TMP/scripts/"
  scp -P "$SSH_PORT" -o BatchMode=yes \
    "$LOCAL_CONFIG" "$SSH_USER@$ip:$REMOTE_TMP/config/cluster.env"

  if [[ "$SCRIPT_REL" == "scripts/02-install-runtime.sh" ]]; then
    local stage="$BATCH_STAGE/$node"
    mkdir -p "$stage/offline/src" "$stage/offline/bin" "$stage/offline/docker" "$stage/systemd" "$stage/runtime-config"
    # 02 当前还负责安装 etcd/Kubernetes/CNI/crictl 二进制，因此只挑选该脚本实际使用的文件。
    for binary in kube-apiserver kube-controller-manager kube-scheduler kubelet kube-proxy kubectl runc; do
      install -m 0755 "$ROOT/offline/bin/$binary" "$stage/offline/bin/$binary"
    done
    for artifact in etcd.tar.gz cni-plugins.tgz crictl.tar.gz; do
      install -m 0644 "$ROOT/offline/src/$artifact" "$stage/offline/src/$artifact"
    done
    install -m 0600 "$ROOT/generated/$node/etc/kubernetes/runtime.env" "$stage/runtime-config/runtime.env"
    install -m 0644 "$ROOT/generated/common/etc/crictl.yaml" "$stage/runtime-config/crictl.yaml"
    if [[ "$RUNTIME_TYPE" == containerd ]]; then
      install -m 0644 "$ROOT/offline/src/containerd.tar.gz" "$stage/offline/src/containerd.tar.gz"
      install -m 0755 "$ROOT/systemd/containerd.service" "$stage/systemd/containerd.service"
      install -m 0644 "$ROOT/generated/common/etc/containerd/config.toml" "$stage/runtime-config/config.toml"
      mkdir -p "$stage/runtime-config/certs.d/$HARBOR_HOST"
      install -m 0644 "$ROOT/generated/common/etc/containerd/certs.d/$HARBOR_HOST/hosts.toml" "$stage/runtime-config/certs.d/$HARBOR_HOST/hosts.toml"
    else
      for artifact in docker.tgz cri-dockerd docker-compose; do
        install -m 0644 "$ROOT/offline/docker/$artifact" "$stage/offline/docker/$artifact"
      done
      for unit in docker.service cri-docker.socket cri-docker.service; do
        install -m 0644 "$ROOT/systemd/$unit" "$stage/systemd/$unit"
      done
      install -m 0644 "$ROOT/generated/common/etc/docker/daemon.json" "$stage/runtime-config/daemon.json"
    fi
    (cd "$stage/offline" && find bin src docker -type f -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
    log "仅复制 $RUNTIME_TYPE 安装所需资源及其依赖二进制 -> $node ($ip)"
    scp -r -P "$SSH_PORT" -o BatchMode=yes \
      "$stage/offline" "$stage/systemd" "$stage/runtime-config" "$SSH_USER@$ip:$REMOTE_TMP/"
    remote_cmd="install -D -m 0600 '$REMOTE_TMP/runtime-config/runtime.env' /etc/kubernetes/runtime.env && install -D -m 0644 '$REMOTE_TMP/runtime-config/crictl.yaml' /etc/crictl.yaml"
    if [[ "$RUNTIME_TYPE" == containerd ]]; then
      remote_cmd+=" && install -D -m 0644 '$REMOTE_TMP/runtime-config/config.toml' /etc/containerd/config.toml && install -D -m 0644 '$REMOTE_TMP/runtime-config/certs.d/$HARBOR_HOST/hosts.toml' '/etc/containerd/certs.d/$HARBOR_HOST/hosts.toml'"
    else
      remote_cmd+=" && install -D -m 0644 '$REMOTE_TMP/runtime-config/daemon.json' /etc/docker/daemon.json"
    fi
    ssh_remote "$ip" "$remote_cmd"
  fi

  # 通过临时目录中的脚本执行；无论成功或失败都清理临时目录，并保留脚本退出码。
  remote_cmd="set +e; bash '$REMOTE_TMP/$SCRIPT_REL'; rc=\$?; rm -rf '$REMOTE_TMP'; exit \$rc"
  ssh_remote "$ip" "$remote_cmd"
}

if [[ -n "$PARALLEL" ]]; then
  PIDS=()
  FAILED=0
  for i in "${!NODES[@]}"; do
    node="${NODES[$i]}"; ip="${IPS[$i]}"
    log "并行执行 $SCRIPT_REL -> $node ($ip)"
    run_node "$node" "$ip" &
    PIDS+=("$!")
  done
  for i in "${!PIDS[@]}"; do
    if wait "${PIDS[$i]}"; then ok "${NODES[$i]} 执行完成"; else warn "${NODES[$i]} 执行失败"; FAILED=1; fi
  done
  [[ "$FAILED" -eq 0 ]] || die "批量执行存在失败节点，请检查对应节点日志。"
else
  for i in "${!NODES[@]}"; do
    node="${NODES[$i]}"; ip="${IPS[$i]}"
    log "执行 $SCRIPT_REL -> $node ($ip)"
    run_node "$node" "$ip"
    ok "$node 执行完成"
  done
fi
