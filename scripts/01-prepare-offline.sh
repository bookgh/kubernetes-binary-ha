#!/usr/bin/env bash
# Run on an Internet-connected Rocky Linux 9 x86_64 staging host.
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
[[ -f /etc/rocky-release ]] || die "Run on Rocky Linux 9 staging host"
[[ "$(uname -m)" == "x86_64" ]] || die "Staging host must be x86_64"
OUT="${ROOT}/offline"
mkdir -p "$OUT"/{bin,src,rpms,manifests,images,checksums}
dnf -y install dnf-plugins-core curl wget tar gzip jq
log "Downloading Kubernetes ${K8S_VERSION}"
for b in kube-apiserver kube-controller-manager kube-scheduler kubelet kube-proxy kubectl; do
  url="https://dl.k8s.io/${K8S_VERSION}/bin/linux/amd64/${b}"
  curl -fL "$url" -o "$OUT/bin/$b"
  curl -fL "${url}.sha256" -o "$OUT/checksums/${b}.sha256"
  expected="$(tr -d '[:space:]' < "$OUT/checksums/${b}.sha256")"
  printf '%s  %s\n' "$expected" "$OUT/bin/$b" | sha256sum -c -
  chmod 0755 "$OUT/bin/$b"
done
log "Downloading containerd ${CONTAINERD_VERSION}"
curl -fL "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz" -o "$OUT/src/containerd.tar.gz"
log "Downloading etcd ${ETCD_VERSION}"
curl -fL "https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-amd64.tar.gz" -o "$OUT/src/etcd.tar.gz"
log "Downloading runc and CNI plugins"
curl -fL "https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.amd64" -o "$OUT/bin/runc"
curl -fL "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-amd64-${CNI_PLUGINS_VERSION}.tgz" -o "$OUT/src/cni-plugins.tgz"
curl -fL "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz" -o "$OUT/src/crictl.tar.gz"
chmod 0755 "$OUT/bin/runc"
log "Downloading Calico manifests"
curl -fL "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml" -o "$OUT/manifests/tigera-operator.yaml"
cp "$ROOT/manifests/calico-custom-resources.yaml" "$OUT/manifests/custom-resources.yaml"
curl -fL "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/v3_projectcalico_org.yaml" -o "$OUT/manifests/calico-crds.yaml"
dnf -y download --resolve --alldeps --destdir "$OUT/rpms" chrony curl wget tar gzip jq openssl socat conntrack-tools ipset ipvsadm ebtables ethtool rsync policycoreutils-python-utils haproxy keepalived
(cd "$OUT" && find bin src rpms manifests -type f -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
cat >"$OUT/ARTIFACTS.txt" <<EOF
Kubernetes=${K8S_VERSION}
etcd=${ETCD_VERSION}
containerd=${CONTAINERD_VERSION}
runc=${RUNC_VERSION}
CNI_PLUGINS=${CNI_PLUGINS_VERSION}
crictl=${CRICTL_VERSION}
Calico=${CALICO_VERSION}
CoreDNS=${COREDNS_VERSION}
Architecture=amd64
EOF
log "Offline artifacts prepared in $OUT"
log "IMPORTANT: container images are a separate required step. See docs/OFFLINE-IMAGES.md."
