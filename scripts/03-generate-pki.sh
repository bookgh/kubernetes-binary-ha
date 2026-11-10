#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
require_cmd jq
CFSSL_DIR="$ROOT/config/cfssl"
PKI="$ROOT/pki"
mkdir -p "$PKI"
chmod 0700 "$PKI"
CFSSL="$ROOT/offline/bin/cfssl"
CFSSLJSON="$ROOT/offline/bin/cfssljson"
[[ -x "$CFSSL" ]] || CFSSL="$(command -v cfssl || true)"
[[ -x "$CFSSLJSON" ]] || CFSSLJSON="$(command -v cfssljson || true)"
[[ -n "$CFSSL" && -x "$CFSSL" ]] || die "缺少 cfssl；先运行 scripts/01-prepare-offline.sh"
[[ -n "$CFSSLJSON" && -x "$CFSSLJSON" ]] || die "缺少 cfssljson；先运行 scripts/01-prepare-offline.sh"
"$CFSSL" version
create_ca() {
  local name="$1" csr="$2"
  "$CFSSL" gencert -initca "$CFSSL_DIR/$csr" | "$CFSSLJSON" -bare "$PKI/$name"
  mv "$PKI/$name.pem" "$PKI/$name.crt"
  mv "$PKI/$name-key.pem" "$PKI/$name.key"
  chmod 0600 "$PKI/$name.key"
}
issue() {
  local ca="$1" cn="$2" org="$3" hosts="$4" name="$5" profile="$6"
  local csr
  csr="$(mktemp "$PKI/${name}.csr.XXXXXX.json")"
  jq --arg cn "$cn" --arg org "$org" '.CN=$cn | .names[0].O=$org' "$CFSSL_DIR/csr/generic.json" > "$csr"
  "$CFSSL" gencert -ca="$PKI/$ca.crt" -ca-key="$PKI/$ca.key" -config="$CFSSL_DIR/ca-config.json" -profile="$profile" -hostname="$hosts" "$csr" | "$CFSSLJSON" -bare "$PKI/$name"
  rm -f "$csr" "$PKI/$name.csr"
  mv "$PKI/$name.pem" "$PKI/$name.crt"
  mv "$PKI/$name-key.pem" "$PKI/$name.key"
  chmod 0600 "$PKI/$name.key"
}
create_ca k8s-ca k8s-ca-csr.json
create_ca etcd-ca etcd-ca-csr.json
create_ca front-proxy-ca front-proxy-ca-csr.json
create_ca cluster-signer cluster-signer-ca-csr.json
API_HOSTS="DNS:kubernetes,DNS:kubernetes.default,DNS:kubernetes.default.svc,DNS:kubernetes.default.svc.${CLUSTER_DOMAIN},DNS:${API_DNS},IP:10.96.0.1,IP:127.0.0.1"
for ip in "${MASTER_IPS[@]}"; do API_HOSTS+=",IP:$ip"; done
issue k8s-ca kube-apiserver "" "$API_HOSTS" apiserver server
issue k8s-ca system:kube-apiserver system:masters "IP:127.0.0.1" apiserver-kubelet-client client
issue front-proxy-ca front-proxy-client "" "IP:127.0.0.1" front-proxy-client client
issue k8s-ca kubernetes-admin system:masters "DNS:localhost,IP:127.0.0.1" admin client
issue k8s-ca system:kube-controller-manager system:kube-controller-manager "DNS:localhost,IP:127.0.0.1" controller-manager client
issue k8s-ca system:kube-scheduler system:kube-scheduler "DNS:localhost,IP:127.0.0.1" scheduler client
issue k8s-ca system:kube-proxy system:kube-proxy "DNS:localhost,IP:127.0.0.1" kube-proxy client
issue etcd-ca kube-apiserver-etcd-client "" "DNS:localhost,IP:127.0.0.1" apiserver-etcd-client client
for i in "${!MASTER_NAMES[@]}"; do
  n="${MASTER_NAMES[$i]}"; ip="${MASTER_IPS[$i]}"
  hosts="DNS:$n,IP:$ip,IP:127.0.0.1"
  issue etcd-ca "etcd-$n" "" "$hosts" "etcd-$n-server" peer
  issue etcd-ca "etcd-$n" "" "$hosts" "etcd-$n-peer" peer
done
for i in "${!ALL_NAMES[@]}"; do
  n="${ALL_NAMES[$i]}"; ip="${ALL_IPS[$i]}"
  issue cluster-signer "system:node:$n" system:nodes "DNS:$n,IP:$ip" "kubelet-$n" client
done
cat "$PKI/k8s-ca.crt" "$PKI/cluster-signer.crt" > "$PKI/k8s-ca-bundle.crt"
# Service-account JWT signing keys are not X.509 certificates.
openssl genrsa -out "$PKI/sa.key" 2048
openssl rsa -in "$PKI/sa.key" -pubout -out "$PKI/sa.pub"
chmod 0600 "$PKI"/*.key
ok "CFSSL PKI generated; every leaf certificate was signed with explicit -hostname DNS/IP SAN values."
