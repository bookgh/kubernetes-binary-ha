#!/usr/bin/env bash
# 在部署机执行：部署每节点 DNS 缓存，Pod kubelet DNS 指向 NODE_LOCAL_DNS_IP。
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
require_cmd curl
require_cmd jq
: "${PRIVATE_REGISTRY:?请在 config/cluster.env 设置 PRIVATE_REGISTRY}"
: "${HARBOR_URL:?请在 config/cluster.env 设置 HARBOR_URL}"
: "${NODE_LOCAL_DNS_IMAGE:?请在 config/cluster.env 设置 NODE_LOCAL_DNS_IMAGE}"
: "${NODE_LOCAL_DNS_IP:?请在 config/cluster.env 设置 NODE_LOCAL_DNS_IP}"
: "${DNS_SERVICE_IP:?请在 config/cluster.env 设置 DNS_SERVICE_IP}"
: "${CLUSTER_DOMAIN:?请在 config/cluster.env 设置 CLUSTER_DOMAIN}"
[[ "$PRIVATE_REGISTRY" == "${HARBOR_HOST}/library" ]] || die "PRIVATE_REGISTRY 必须设置为 ${HARBOR_HOST}/library"
[[ "$NODE_LOCAL_DNS_IMAGE" == "${PRIVATE_REGISTRY}/"* ]] || die "NODE_LOCAL_DNS_IMAGE 必须从 Harbor 拉取"
[[ "$NODE_LOCAL_DNS_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "NODE_LOCAL_DNS_IP 必须为 IPv4 地址"
[[ "$NODE_LOCAL_DNS_IP" == 169.254.* ]] || die "NODE_LOCAL_DNS_IP 必须使用 169.254.0.0/16 链路本地地址"
curl --fail --silent "$HARBOR_URL/api/v2.0/ping" >/dev/null || die "Harbor API 不可用：$HARBOR_URL"
KUBECTL="$ROOT/offline/bin/kubectl"
[[ -x "$KUBECTL" ]] || KUBECTL="$(command -v kubectl || true)"
[[ -n "$KUBECTL" && -x "$KUBECTL" ]] || die "找不到 kubectl"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export KUBECONFIG
[[ -s "$KUBECONFIG" ]] || die "缺少管理员 kubeconfig"
"$KUBECTL" -n kube-system rollout status deployment/coredns --timeout=300s
"$KUBECTL" -n kube-system get endpoints kube-dns -o json |
  jq -e '[.subsets[]?.addresses[]?] | length > 0' >/dev/null ||
  die "CoreDNS kube-dns Service 没有可用 Endpoints"

MANIFEST="$(mktemp)"
trap 'rm -f "$MANIFEST"' EXIT
cat > "$MANIFEST" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: node-local-dns
  namespace: kube-system
data:
  Corefile: |
    ${CLUSTER_DOMAIN}:53 {
        errors
        cache {
            success 9984 30
            denial 9984 5
        }
        reload
        loop
        bind ${NODE_LOCAL_DNS_IP}
        forward . ${DNS_SERVICE_IP} {
            force_tcp
        }
        prometheus ${NODE_LOCAL_DNS_IP}:9253
        health ${NODE_LOCAL_DNS_IP}:8080
        ready ${NODE_LOCAL_DNS_IP}:8181
    }
    in-addr.arpa:53 {
        errors
        cache 30
        reload
        loop
        bind ${NODE_LOCAL_DNS_IP}
        forward . ${DNS_SERVICE_IP} {
            force_tcp
        }
    }
    ip6.arpa:53 {
        errors
        cache 30
        reload
        loop
        bind ${NODE_LOCAL_DNS_IP}
        forward . ${DNS_SERVICE_IP} {
            force_tcp
        }
    }
    .:53 {
        errors
        cache 30
        reload
        loop
        bind ${NODE_LOCAL_DNS_IP}
        forward . /etc/resolv.conf
    }
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-local-dns
  namespace: kube-system
  labels:
    k8s-app: node-local-dns
spec:
  selector:
    matchLabels:
      k8s-app: node-local-dns
  updateStrategy:
    type: RollingUpdate
  template:
    metadata:
      labels:
        k8s-app: node-local-dns
    spec:
      priorityClassName: system-node-critical
      hostNetwork: true
      dnsPolicy: Default
      tolerations:
        - operator: Exists
      containers:
        - name: node-cache
          image: ${NODE_LOCAL_DNS_IMAGE}
          imagePullPolicy: IfNotPresent
          args:
            - -localip
            - ${NODE_LOCAL_DNS_IP}
            - -conf
            - /etc/Corefile
          ports:
            - name: dns-udp
              containerPort: 53
              hostPort: 53
              protocol: UDP
            - name: dns-tcp
              containerPort: 53
              hostPort: 53
              protocol: TCP
            - name: metrics
              containerPort: 9253
              hostPort: 9253
              protocol: TCP
          livenessProbe:
            httpGet:
              host: ${NODE_LOCAL_DNS_IP}
              path: /health
              port: 8080
            initialDelaySeconds: 30
            timeoutSeconds: 5
          readinessProbe:
            httpGet:
              host: ${NODE_LOCAL_DNS_IP}
              path: /ready
              port: 8181
            initialDelaySeconds: 5
            timeoutSeconds: 2
          resources:
            requests:
              cpu: 25m
              memory: 32Mi
            limits:
              memory: 256Mi
          securityContext:
            privileged: true
          volumeMounts:
            - name: config-volume
              mountPath: /etc/Corefile
              subPath: Corefile
              readOnly: true
            - name: xtables-lock
              mountPath: /run/xtables.lock
      volumes:
        - name: config-volume
          configMap:
            name: node-local-dns
        - name: xtables-lock
          hostPath:
            path: /run/xtables.lock
            type: FileOrCreate
EOF

log "从 Harbor 部署 NodeLocal DNSCache：image=$NODE_LOCAL_DNS_IMAGE，listen=$NODE_LOCAL_DNS_IP"
"$KUBECTL" apply -f "$MANIFEST"
"$KUBECTL" -n kube-system rollout status daemonset/node-local-dns --timeout=600s
NODE_COUNT="$("$KUBECTL" get nodes -o json | jq '.items | length')"
READY_COUNT="$("$KUBECTL" -n kube-system get ds node-local-dns -o json | jq '.status.numberReady')"
[[ "$READY_COUNT" == "$NODE_COUNT" ]] || die "NodeLocal DNSCache Ready 数量不匹配：期望 $NODE_COUNT，实际 $READY_COUNT"
"$KUBECTL" -n kube-system get pods -l k8s-app=node-local-dns -o wide
ok "NodeLocal DNSCache 已在全部 $NODE_COUNT 个节点就绪；kubelet clusterDNS 使用 $NODE_LOCAL_DNS_IP。"
