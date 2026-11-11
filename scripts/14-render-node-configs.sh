#!/usr/bin/env bash
# 在部署机执行：只在本地生成配置，不连接远程节点。
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
: "${NODE_LOCAL_DNS_IP:?请在 config/cluster.env 设置 NODE_LOCAL_DNS_IP}"
: "${DNS_SERVICE_IP:?请在 config/cluster.env 设置 DNS_SERVICE_IP}"
[[ "$NODE_LOCAL_DNS_IP" == 169.254.* ]] || die "NODE_LOCAL_DNS_IP 必须使用 169.254.0.0/16 链路本地地址"
case "${RUNTIME_TYPE:-containerd}" in
  containerd) RUNTIME_ENDPOINT="unix:///run/containerd/containerd.sock" ;;
  docker)
    : "${DOCKER_VERSION:?Docker 模式必须在 config/cluster.env 中设置 DOCKER_VERSION}"
    : "${CRI_DOCKERD_VERSION:?Docker 模式必须设置 CRI_DOCKERD_VERSION}"
    RUNTIME_ENDPOINT="unix:///run/cri-dockerd.sock"
    ;;
  *) die "RUNTIME_TYPE 仅支持 containerd 或 docker" ;;
esac
case "${KUBE_PROXY_MODE:-nftables}" in
  ipvs|nftables) ;;
  *) die "KUBE_PROXY_MODE 仅支持 ipvs 或 nftables" ;;
esac
[[ "${IPVS_STRICT_ARP:-false}" == true || "${IPVS_STRICT_ARP:-false}" == false ]] || die "IPVS_STRICT_ARP 必须为 true/false"
[[ "${NFTABLES_MASQUERADE_BIT:-14}" =~ ^([0-9]|[12][0-9]|3[01])$ ]] || die "NFTABLES_MASQUERADE_BIT 必须在 0-31 之间"

OUT_STAGE="$(mktemp -d "$ROOT/.generated-stage.XXXXXX")"
cleanup() { [[ -z "$OUT_STAGE" ]] || rm -rf "$OUT_STAGE"; }
trap cleanup EXIT
OUT="$OUT_STAGE"
COMMON="$OUT/common"
mkdir -p "$COMMON/etc"
cat > "$COMMON/etc/crictl.yaml" <<EOF
runtime-endpoint: ${RUNTIME_ENDPOINT}
image-endpoint: ${RUNTIME_ENDPOINT}
timeout: 10
debug: false
EOF
if [[ "${RUNTIME_TYPE:-containerd}" == containerd ]]; then
  [[ -s "$ROOT/offline/src/containerd.tar.gz" ]] || die "缺少 Release 中的 containerd.tar.gz；请先运行 scripts/01-prepare-offline.sh"
  TMP_CONTAINERD="$(mktemp -d)"
  tar -xzf "$ROOT/offline/src/containerd.tar.gz" -C "$TMP_CONTAINERD" bin/containerd
  CONTAINERD_BIN="$TMP_CONTAINERD/bin/containerd"
  install -d -m 0755 "$COMMON/etc/containerd"
  "$CONTAINERD_BIN" config default > "$COMMON/etc/containerd/config.toml"
  if grep -q "SystemdCgroup = false" "$COMMON/etc/containerd/config.toml"; then
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' "$COMMON/etc/containerd/config.toml"
  elif ! grep -q "SystemdCgroup = true" "$COMMON/etc/containerd/config.toml"; then
    OPTIONS_TABLE="[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]"
    grep -Fq "$OPTIONS_TABLE" "$COMMON/etc/containerd/config.toml" || die "containerd 默认配置缺少 runc options 表"
    sed -i "/^\\[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options\\]/a SystemdCgroup = true" "$COMMON/etc/containerd/config.toml"
  fi
  if grep -qE "^[[:space:]]*sandbox[[:space:]]*=" "$COMMON/etc/containerd/config.toml"; then
    sed -i -E "s#^([[:space:]]*sandbox[[:space:]]*=[[:space:]]*).*$#\\1'${PAUSE_IMAGE}'#" "$COMMON/etc/containerd/config.toml"
  else
    die "containerd 2.x 默认配置中未找到 pinned_images.sandbox 字段"
  fi
  if grep -qE "^[[:space:]]*config_path[[:space:]]*=" "$COMMON/etc/containerd/config.toml"; then
    sed -i -E 's#^[[:space:]]*config_path[[:space:]]*=.*#  config_path = "/etc/containerd/certs.d"#' "$COMMON/etc/containerd/config.toml"
  elif grep -Fq "[plugins.'io.containerd.cri.v1.images'.registry]" "$COMMON/etc/containerd/config.toml"; then
    sed -i "/^\\[plugins.'io.containerd.cri.v1.images'.registry\\]/a\\  config_path = \"/etc/containerd/certs.d\"" "$COMMON/etc/containerd/config.toml"
  else
    cat >> "$COMMON/etc/containerd/config.toml" <<'EOF'

[plugins.'io.containerd.cri.v1.images'.registry]
  config_path = "/etc/containerd/certs.d"
EOF
  fi
  install -d -m 0755 "$COMMON/etc/containerd/certs.d/${HARBOR_HOST}"
  cat > "$COMMON/etc/containerd/certs.d/${HARBOR_HOST}/hosts.toml" <<EOF
server = "http://${HARBOR_HOST}"

[host."http://${HARBOR_HOST}"]
  capabilities = ["pull", "resolve", "push"]
EOF
  rm -rf "$TMP_CONTAINERD"
elif [[ "${RUNTIME_TYPE:-containerd}" == docker ]]; then
  install -d -m 0755 "$COMMON/etc/docker"
  cat > "$COMMON/etc/docker/daemon.json" <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "data-root": "${DOCKER_DATA_ROOT}",
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": {"max-size": "100m", "max-file": "5"},
  "insecure-registries": ["${HARBOR_HOST}"]
}
EOF
fi

# 系统内核配置同样在部署机生成，再由分发脚本下发；远程节点不临时拼接文件。
install -d -m 0755 "$COMMON/etc/modules-load.d" "$COMMON/etc/sysctl.d"
cat > "$COMMON/etc/modules-load.d/10-kubernetes.conf" <<'EOF'
overlay
br_netfilter
nf_conntrack
EOF
if [[ "${KUBE_PROXY_MODE:-nftables}" == ipvs ]]; then
  cat >> "$COMMON/etc/modules-load.d/10-kubernetes.conf" <<'EOF'
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
EOF
elif [[ "${KUBE_PROXY_MODE:-nftables}" == nftables ]]; then
  cat >> "$COMMON/etc/modules-load.d/10-kubernetes.conf" <<'EOF'
nf_tables
EOF
fi
cat > "$COMMON/etc/sysctl.d/95-kubernetes.conf" <<'EOF'
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
EOF

ETCD_INITIAL_CLUSTER=""
ETCD_SERVERS=""
MASTER_IP_LIST=""
for i in "${!MASTER_NAMES[@]}"; do
  [[ -n "$ETCD_INITIAL_CLUSTER" ]] && ETCD_INITIAL_CLUSTER+=","
  [[ -n "$ETCD_SERVERS" ]] && ETCD_SERVERS+=","
  [[ -n "$MASTER_IP_LIST" ]] && MASTER_IP_LIST+=","
  ETCD_INITIAL_CLUSTER+="${MASTER_NAMES[$i]}=https://${MASTER_IPS[$i]}:2380"
  ETCD_SERVERS+="https://${MASTER_IPS[$i]}:2379"
  MASTER_IP_LIST+="${MASTER_IPS[$i]}"
done

NODES=("${ALL_NAMES[@]}")
IPS=("${ALL_IPS[@]}")
for i in "${!NODES[@]}"; do
  node="${NODES[$i]}"; ip="${IPS[$i]}"
  dir="$OUT/$node"
  install -d -m 0700 "$dir/etc/kubernetes" "$dir/var/lib/kubelet" "$dir/var/lib/kube-proxy"
  sed -e "s#clusterDomain: .*#clusterDomain: ${CLUSTER_DOMAIN}#" \
      -e "s#  - 10.96.0.10#  - ${NODE_LOCAL_DNS_IP}#" \
      "$ROOT/config/kubelet-config.yaml" > "$dir/var/lib/kubelet/config.yaml"
  sed -e "s#clusterCIDR: .*#clusterCIDR: ${POD_CIDR}#" \
      -e "s#mode: .*#mode: ${KUBE_PROXY_MODE}#" \
      -e "s#strictARP: .*#strictARP: ${IPVS_STRICT_ARP}#" \
      -e "s#masqueradeBit: .*#masqueradeBit: ${NFTABLES_MASQUERADE_BIT}#" \
      -e "s#hostnameOverride: .*#hostnameOverride: ${node}#" \
      "$ROOT/config/kube-proxy-config.yaml" > "$dir/var/lib/kube-proxy/config.yaml"
  if [[ "$node" == worker-* ]]; then
    install -d -m 0700 "$dir/etc/nginx"
    awk -v ips="$MASTER_IP_LIST" '
      index($0, "__MASTER_UPSTREAM_SERVERS__") {
        count = split(ips, addresses, ",")
        for (i = 1; i <= count; i++)
          printf "        server %s:6443 max_fails=2 fail_timeout=5s;\n", addresses[i]
        next
      }
      { print }
    ' "$ROOT/config/nginx-stream.conf.template" > "$dir/etc/nginx/nginx.conf"
    grep -q "server .*:6443" "$dir/etc/nginx/nginx.conf" || die "NGINX upstream 未生成任何 Master endpoint：$node"
  fi
  cat > "$dir/etc/kubernetes/cluster.env" <<EOF
NODE_NAME=${node}
NODE_IP=${ip}
CLUSTER_NAME=${CLUSTER_NAME}
CLUSTER_DOMAIN=${CLUSTER_DOMAIN}
DNS_SERVICE_IP=${DNS_SERVICE_IP}
NODE_LOCAL_DNS_IP=${NODE_LOCAL_DNS_IP}
API_DNS=${API_DNS}
API_PORT=${API_PORT}
POD_CIDR=${POD_CIDR}
SERVICE_CIDR=${SERVICE_CIDR}
MASTER_COUNT=${MASTER_COUNT}
ETCD_SERVERS=${ETCD_SERVERS}
ETCD_INITIAL_CLUSTER=${ETCD_INITIAL_CLUSTER}
ETCD_HEARTBEAT_INTERVAL=${ETCD_HEARTBEAT_INTERVAL}
ETCD_ELECTION_TIMEOUT=${ETCD_ELECTION_TIMEOUT}
ETCD_QUOTA_BACKEND_BYTES=${ETCD_QUOTA_BACKEND_BYTES}
RUNTIME_TYPE=${RUNTIME_TYPE:-containerd}
CONTAINER_RUNTIME_ENDPOINT=${RUNTIME_ENDPOINT}
PAUSE_IMAGE=${PAUSE_IMAGE}
KUBE_PROXY_MODE=${KUBE_PROXY_MODE:-nftables}
EOF
  cat > "$dir/etc/kubernetes/runtime.env" <<EOF
CONTAINER_RUNTIME_ENDPOINT=${RUNTIME_ENDPOINT}
RUNTIME_TYPE=${RUNTIME_TYPE:-containerd}
PAUSE_IMAGE=${PAUSE_IMAGE}
EOF
  chmod 0600 "$dir/etc/kubernetes/cluster.env" "$dir/etc/kubernetes/runtime.env"
  log "已生成 ${node}（${ip}）的 kubelet/kube-proxy/运行时配置"
done
OLD_OUT="$ROOT/.generated-previous.$"
[[ ! -e "$OLD_OUT" ]] || die "发现未清理的配置备份目录：$OLD_OUT"
if [[ -e "$ROOT/generated" ]]; then mv "$ROOT/generated" "$OLD_OUT"; fi
if mv "$OUT_STAGE" "$ROOT/generated"; then
  OUT_STAGE=""
  rm -rf "$OLD_OUT"
else
  [[ ! -e "$OLD_OUT" ]] || mv "$OLD_OUT" "$ROOT/generated"
  die "切换 generated/ 配置目录失败；已尝试恢复旧版本"
fi
ok "本地配置生成完成：$ROOT/generated；下一步运行 scripts/15-distribute-node-configs.sh。"
