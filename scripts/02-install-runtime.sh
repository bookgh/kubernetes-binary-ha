#!/usr/bin/env bash
# 在 Kubernetes 节点安装容器运行时；只处理 containerd 或 Docker 及其运行配置。
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root

OFF="${ROOT}/offline"
RUNTIME_ENV="/etc/kubernetes/runtime.env"
[[ -s "$RUNTIME_ENV" ]] || die "缺少运行时配置 $RUNTIME_ENV；请通过批量执行脚本分发运行时配置"
[[ -s "$OFF/SHA256SUMS" ]] || die "缺少运行时离线资源校验清单"
# shellcheck disable=SC1091
source "$RUNTIME_ENV"
(cd "$OFF" && sha256sum -c SHA256SUMS) || die "运行时离线资源校验失败"

assert_active_version() {
  local service="$1" binary="$2" expected="$3" actual
  expected="${expected#v}"
  if systemctl is-active --quiet "$service"; then
    [[ -x "$binary" ]] || die "$service 正在运行，但找不到当前二进制 $binary；拒绝覆盖"
    actual="$("$binary" --version 2>&1 | grep -Eo 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -n1 | sed 's/^v//')" || actual=""
    [[ -n "$actual" && "$actual" == "$expected" ]] ||
      die "$service 当前版本为 ${actual:-unknown}，目标版本为 $expected；禁止通过安装脚本原地升级"
  fi
}

install -d -m 0755 /usr/local/bin /usr/local/sbin
install -m 0755 "$OFF/bin/runc" /usr/local/sbin/runc

case "$RUNTIME_TYPE" in
  containerd)
    assert_active_version containerd /usr/local/bin/containerd "$CONTAINERD_VERSION"
    [[ -s "$OFF/src/containerd.tar.gz" ]] || die "containerd 模式缺少 offline/src/containerd.tar.gz"
    [[ -s /etc/containerd/config.toml ]] || die "缺少 containerd 配置 /etc/containerd/config.toml"
    [[ -s "/etc/containerd/certs.d/${HARBOR_HOST}/hosts.toml" ]] ||
      die "缺少 Harbor registry 配置 /etc/containerd/certs.d/${HARBOR_HOST}/hosts.toml"
    grep -Fq 'config_path = "/etc/containerd/certs.d"' /etc/containerd/config.toml ||
      die "containerd 未启用 registry config_path"
    TMP_CONTAINERD="$(mktemp -d)"
    trap 'rm -rf "$TMP_CONTAINERD"' EXIT
    tar -xzf "$OFF/src/containerd.tar.gz" -C "$TMP_CONTAINERD"
    [[ -x "$TMP_CONTAINERD/bin/containerd" ]] || die "containerd 归档中未找到 bin/containerd"
    for binary in "$TMP_CONTAINERD"/bin/*; do
      [[ -f "$binary" && -x "$binary" ]] || continue
      install -m 0755 "$binary" /usr/local/bin/
    done
    install -m 0644 "$ROOT/systemd/containerd.service" /etc/systemd/system/containerd.service
    containerd --version
    containerd config dump >/dev/null || die "containerd 配置校验失败"
    systemctl daemon-reload
    systemctl enable --now containerd
    ;;
  docker)
    assert_active_version docker /usr/local/bin/docker "$DOCKER_VERSION"
    assert_active_version cri-docker /usr/local/bin/cri-dockerd "$CRI_DOCKERD_VERSION"
    [[ -s "$OFF/docker/docker.tgz" ]] || die "Docker 模式缺少 offline/docker/docker.tgz"
    [[ -s "$OFF/docker/cri-dockerd" && -s "$OFF/docker/docker-compose" ]] ||
      die "Docker 模式缺少 cri-dockerd/docker-compose 二进制"
    [[ -s /etc/docker/daemon.json ]] || die "缺少 Docker 配置 /etc/docker/daemon.json"
    require_cmd jq
    jq -e --arg registry "${HARBOR_HOST}" '.["insecure-registries"] | index($registry) != null' /etc/docker/daemon.json >/dev/null ||
      die "Docker daemon.json 未信任 Harbor HTTP registry"
    DOCKER_TMP="$(mktemp -d)"
    trap 'rm -rf "$DOCKER_TMP"' EXIT
    tar -xzf "$OFF/docker/docker.tgz" -C "$DOCKER_TMP"
    [[ -d "$DOCKER_TMP/docker" ]] || die "Docker 静态包目录结构不正确，预期包含 docker/ 子目录"
    install -m 0755 "$DOCKER_TMP"/docker/* /usr/local/bin/
    install -m 0755 "$OFF/docker/cri-dockerd" /usr/local/bin/cri-dockerd
    install -d -m 0755 /usr/local/lib/docker/cli-plugins
    install -m 0755 "$OFF/docker/docker-compose" /usr/local/lib/docker/cli-plugins/docker-compose
    ln -sf /usr/local/lib/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose
    getent group docker >/dev/null 2>&1 || groupadd --system docker
    install -m 0644 "$ROOT/systemd/docker.service" /etc/systemd/system/docker.service
    install -m 0644 "$ROOT/systemd/cri-docker.socket" /etc/systemd/system/cri-docker.socket
    install -m 0644 "$ROOT/systemd/cri-docker.service" /etc/systemd/system/cri-docker.service
    dockerd --validate --config-file=/etc/docker/daemon.json || die "Docker daemon.json 配置校验失败"
    systemctl daemon-reload
    systemctl enable --now docker
    systemctl enable --now cri-docker.socket
    ;;
  *) die "RUNTIME_TYPE 仅支持 containerd 或 docker" ;;
esac

systemctl is-active --quiet "$RUNTIME_TYPE" || die "容器运行时服务未处于 active 状态：$RUNTIME_TYPE"
ok "$RUNTIME_TYPE 容器运行时安装完成；CRI endpoint：${CONTAINER_RUNTIME_ENDPOINT}"
