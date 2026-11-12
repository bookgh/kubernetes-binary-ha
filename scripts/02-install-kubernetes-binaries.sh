#!/usr/bin/env bash
# 在 Kubernetes 节点安装 etcd、Kubernetes、CNI 与 crictl 二进制；不安装容器运行时。
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root

OFF="${ROOT}/offline"
[[ -s "$OFF/SHA256SUMS" ]] || die "缺少 Kubernetes/etcd 离线二进制资源校验清单"
(cd "$OFF" && sha256sum -c SHA256SUMS) || die "Kubernetes/etcd 离线资源校验失败"

assert_active_version() {
  local service="$1" binary="$2" expected="$3" actual
  expected="${expected#v}"
  if systemctl is-active --quiet "$service"; then
    [[ -x "$binary" ]] || die "$service 正在运行，但找不到当前二进制 $binary；拒绝覆盖"
    actual="$("$binary" --version 2>&1 | grep -Eo 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -n1 | sed 's/^v//')" || actual=""
    [[ -n "$actual" && "$actual" == "$expected" ]] ||
      die "$service 当前版本为 ${actual:-unknown}，目标版本为 $expected；拒绝覆盖"
  fi
}

for binary in kube-apiserver kube-controller-manager kube-scheduler kubelet kube-proxy kubectl; do
  [[ -x "$OFF/bin/$binary" ]] || die "缺少 Kubernetes 二进制：offline/bin/$binary"
done
[[ -s "$OFF/src/etcd.tar.gz" ]] || die "缺少 offline/src/etcd.tar.gz"
[[ -s "$OFF/src/cni-plugins.tgz" ]] || die "缺少 offline/src/cni-plugins.tgz"
[[ -s "$OFF/src/crictl.tar.gz" ]] || die "缺少 offline/src/crictl.tar.gz"

if [[ "$KUBE_PROXY_MODE" == nftables ]]; then
  command -v nft >/dev/null 2>&1 || die "缺少 nft 命令；请预装 nftables"
else
  command -v ipvsadm >/dev/null 2>&1 || die "缺少 ipvsadm 命令；请预装 ipvsadm"
fi

assert_active_version etcd /usr/local/bin/etcd "$ETCD_VERSION"
for service in kube-apiserver kube-controller-manager kube-scheduler kubelet kube-proxy; do
  assert_active_version "$service" "/usr/local/bin/$service" "$K8S_VERSION"
done

install -d -m 0755 /usr/local/bin /opt/cni/bin
ETCD_VERSION_NORMALIZED="${ETCD_VERSION#v}"
[[ "$ETCD_VERSION_NORMALIZED" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "ETCD_VERSION 格式无效：$ETCD_VERSION"
ETCD_TMP="$(mktemp -d)"
trap 'rm -rf "$ETCD_TMP"' EXIT
tar -xzf "$OFF/src/etcd.tar.gz" -C "$ETCD_TMP"
ETCD_DIR="$ETCD_TMP/etcd-v${ETCD_VERSION_NORMALIZED}-linux-amd64"
[[ -x "$ETCD_DIR/etcd" && -x "$ETCD_DIR/etcdctl" && -x "$ETCD_DIR/etcdutl" ]] ||
  die "etcd ${ETCD_VERSION_NORMALIZED} 离线归档缺少 etcd/etcdctl/etcdutl"
install -m 0755 "$ETCD_DIR/etcd" "$ETCD_DIR/etcdctl" "$ETCD_DIR/etcdutl" /usr/local/bin/
install -m 0755 "$OFF"/bin/{kube-apiserver,kube-controller-manager,kube-scheduler,kubelet,kube-proxy,kubectl} /usr/local/bin/
tar -xzf "$OFF/src/cni-plugins.tgz" -C /opt/cni/bin
tar -xzf "$OFF/src/crictl.tar.gz" -C /usr/local/bin crictl
ok "etcd、Kubernetes、CNI 与 crictl 二进制安装完成。"
