#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
PKI="${ROOT}/pki"
mkdir -p "$PKI"
chmod 0700 "$PKI"
cd "$PKI"
new_ca() {
  local name="$1" cn="$2"
  openssl genrsa -out "${name}.key" 4096
  openssl req -x509 -new -nodes -key "${name}.key" -sha256 -days 3650 \
    -subj "/CN=${cn}" -out "${name}.crt"
}
issue() {
  local ca="$1" cn="$2" org="$3" san="$4" name="$5" eku="${6:-}"
  openssl genrsa -out "${name}.key" 2048
  cat >"${name}.cnf" <<EOF
[req]
prompt=no
distinguished_name=dn
req_extensions=req_ext
[dn]
CN=${cn}
O=${org}
[req_ext]
subjectAltName=${san}
extendedKeyUsage=${eku}
EOF
  openssl req -new -key "${name}.key" -out "${name}.csr" -config "${name}.cnf"
  openssl x509 -req -in "${name}.csr" -CA "${ca}.crt" -CAkey "${ca}.key" \
    -CAcreateserial -out "${name}.crt" -days 365 -sha256 -extensions req_ext -extfile "${name}.cnf"
  rm -f "${name}.csr" "${name}.cnf"
}
new_ca k8s-ca kubernetes
new_ca etcd-ca etcd
new_ca front-proxy-ca front-proxy-ca
# 专用节点证书签发 CA；其私钥仅分发到 Master 控制平面，不分发根 CA 私钥。
new_ca cluster-signer kubernetes-cluster-signer
# NGINX 使用 TCP 透传。客户端直接验证被选中的 API Server 证书，
# 因此 API 服务端证书必须同时包含回环地址、全部 Master IP 和 API DNS。
issue k8s-ca kube-apiserver "" \
  "DNS:kubernetes,DNS:kubernetes.default,DNS:kubernetes.default.svc,DNS:kubernetes.default.svc.${CLUSTER_DOMAIN},DNS:${API_DNS},IP:10.96.0.1,IP:127.0.0.1,IP:${MASTER1_IP},IP:${MASTER2_IP},IP:${MASTER3_IP}" \
  apiserver "serverAuth,clientAuth"
issue k8s-ca system:kube-apiserver system:masters "IP:127.0.0.1" apiserver-kubelet-client clientAuth
issue k8s-ca front-proxy-client "" "IP:127.0.0.1" front-proxy-client clientAuth
issue k8s-ca kubernetes-admin system:masters "IP:127.0.0.1" admin clientAuth
issue k8s-ca system:kube-controller-manager "" "IP:127.0.0.1" controller-manager clientAuth
issue k8s-ca system:kube-scheduler "" "IP:127.0.0.1" scheduler clientAuth
issue k8s-ca system:kube-proxy "" "IP:127.0.0.1" kube-proxy clientAuth
for spec in "master-01:${MASTER1_IP}" "master-02:${MASTER2_IP}" "master-03:${MASTER3_IP}"; do
  n="${spec%%:*}"; ip="${spec##*:}"
  issue etcd-ca "etcd-${n}" "" "DNS:${n},IP:${ip},IP:127.0.0.1" "etcd-${n}-server" "serverAuth,clientAuth"
  issue etcd-ca "etcd-${n}" "" "DNS:${n},IP:${ip},IP:127.0.0.1" "etcd-${n}-peer" "serverAuth,clientAuth"
done
issue etcd-ca kube-apiserver-etcd-client "" "IP:127.0.0.1" apiserver-etcd-client clientAuth
for spec in "master-01:${MASTER1_IP}" "master-02:${MASTER2_IP}" "master-03:${MASTER3_IP}" \
            "worker-01:${WORKER1_IP}" "worker-02:${WORKER2_IP}" "worker-03:${WORKER3_IP}"; do
  n="${spec%%:*}"; ip="${spec##*:}"
  issue cluster-signer "system:node:${n}" "system:nodes" "DNS:${n},IP:${ip}" "kubelet-${n}" clientAuth
done
cat k8s-ca.crt cluster-signer.crt > k8s-ca-bundle.crt
openssl genrsa -out sa.key 2048
openssl rsa -in sa.key -pubout -out sa.pub
chmod 0600 *.key
log "PKI generated. Keep root CA private keys offline; cluster-signer.key is the only delegated signer key sent to Master nodes."
