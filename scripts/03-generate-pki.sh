#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
require_cmd jq
require_cmd openssl
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
  if [[ -s "$PKI/$name.crt" && -s "$PKI/$name.key" ]]; then log "复用已存在 CA：$name"; return 0; fi
  [[ ! -e "$PKI/$name.crt" && ! -e "$PKI/$name.key" ]] || die "CA $name 文件不完整；拒绝覆盖，请先备份并人工恢复。"
  "$CFSSL" gencert -initca "$CFSSL_DIR/$csr" | "$CFSSLJSON" -bare "$PKI/$name"
  mv "$PKI/$name.pem" "$PKI/$name.crt"
  mv "$PKI/$name-key.pem" "$PKI/$name.key"
  chmod 0600 "$PKI/$name.key"
}
issue() {
  local ca="$1" cn="$2" org="$3" hosts="$4" name="$5" profile="$6" template="${7:-generic}"
  local csr
  if [[ -s "$PKI/$name.crt" && -s "$PKI/$name.key" ]]; then log "复用已存在服务证书：$name"; return 0; fi
  [[ ! -e "$PKI/$name.crt" && ! -e "$PKI/$name.key" ]] || die "证书 $name 文件不完整；拒绝覆盖，请先备份并人工恢复。"
  csr="$(mktemp "$PKI/${name}.csr.XXXXXX.json")"
  jq --arg cn "$cn" --arg org "$org" 'if $org == "" then .CN=$cn else (.CN=$cn | .names[0].O=$org) end' "$CFSSL_DIR/csr/$template.json" > "$csr"
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
API_HOSTS="kubernetes,kubernetes.default,kubernetes.default.svc,kubernetes.default.svc.${CLUSTER_DOMAIN},${API_DNS},${KUBERNETES_SERVICE_IP},127.0.0.1"
for ip in "${MASTER_IPS[@]}"; do API_HOSTS+=",$ip"; done
issue k8s-ca kube-apiserver "" "$API_HOSTS" apiserver server apiserver
openssl x509 -in "$PKI/apiserver.crt" -noout -checkhost "$API_DNS" >/dev/null
openssl x509 -in "$PKI/apiserver.crt" -noout -checkip 127.0.0.1 >/dev/null
openssl x509 -in "$PKI/apiserver.crt" -noout -checkip "$KUBERNETES_SERVICE_IP" >/dev/null
openssl x509 -in "$PKI/apiserver.crt" -noout -checkhost "kubernetes.default.svc.${CLUSTER_DOMAIN}" >/dev/null
for ip in "${MASTER_IPS[@]}"; do openssl x509 -in "$PKI/apiserver.crt" -noout -checkip "$ip" >/dev/null; done
issue k8s-ca system:kube-apiserver system:masters "127.0.0.1" apiserver-kubelet-client client apiserver-kubelet-client
issue front-proxy-ca front-proxy-client "" "127.0.0.1" front-proxy-client client front-proxy-client
issue k8s-ca kubernetes-admin system:masters "localhost,127.0.0.1" admin client admin
issue k8s-ca system:kube-controller-manager system:kube-controller-manager "localhost,127.0.0.1" controller-manager client controller-manager
issue k8s-ca system:kube-scheduler system:kube-scheduler "localhost,127.0.0.1" scheduler client scheduler
issue k8s-ca system:kube-proxy system:kube-proxy "localhost,127.0.0.1" kube-proxy client kube-proxy
issue etcd-ca kube-apiserver-etcd-client "" "localhost,127.0.0.1" apiserver-etcd-client client apiserver-etcd-client
for i in "${!MASTER_NAMES[@]}"; do
  n="${MASTER_NAMES[$i]}"; ip="${MASTER_IPS[$i]}"
  hosts="$n,$ip,127.0.0.1"
  issue etcd-ca "etcd-$n" "" "$hosts" "etcd-$n-server" peer etcd-server
  issue etcd-ca "etcd-$n" "" "$hosts" "etcd-$n-peer" peer etcd-peer
  openssl x509 -in "$PKI/etcd-$n-server.crt" -noout -checkhost "$n" >/dev/null
  openssl x509 -in "$PKI/etcd-$n-server.crt" -noout -checkip "$ip" >/dev/null
  openssl x509 -in "$PKI/etcd-$n-peer.crt" -noout -checkhost "$n" >/dev/null
  openssl x509 -in "$PKI/etcd-$n-peer.crt" -noout -checkip "$ip" >/dev/null
done
for i in "${!ALL_NAMES[@]}"; do
  n="${ALL_NAMES[$i]}"; ip="${ALL_IPS[$i]}"
  issue cluster-signer "system:node:$n" system:nodes "$n,$ip" "kubelet-$n" client kubelet-node
  openssl x509 -in "$PKI/kubelet-$n.crt" -noout -checkhost "$n" >/dev/null
  openssl x509 -in "$PKI/kubelet-$n.crt" -noout -checkip "$ip" >/dev/null
done
cat "$PKI/k8s-ca.crt" "$PKI/cluster-signer.crt" > "$PKI/k8s-ca-bundle.crt"
# Service-account JWT signing keys are not X.509 certificates.
if [[ -s "$PKI/sa.key" && -s "$PKI/sa.pub" ]]; then
  log "复用已有 ServiceAccount JWT 密钥对"
else
  [[ ! -e "$PKI/sa.key" && ! -e "$PKI/sa.pub" ]] || die "ServiceAccount 密钥对不完整；拒绝覆盖。"
  openssl genrsa -out "$PKI/sa.key" 2048
  openssl rsa -in "$PKI/sa.key" -pubout -out "$PKI/sa.pub"
fi
chmod 0600 "$PKI"/*.key
ok "CFSSL PKI generated; every leaf certificate was signed with explicit -hostname DNS/IP SAN values."
