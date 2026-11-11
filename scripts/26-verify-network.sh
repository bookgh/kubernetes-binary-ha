#!/usr/bin/env bash
# 在部署机执行：强制从 Harbor 拉取测试镜像，验证 NodeLocal DNS、Service DNS 和跨节点 Pod 网络。
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
require_cmd jq
: "${NETWORK_TEST_IMAGE:?请在 config/cluster.env 设置 NETWORK_TEST_IMAGE}"
: "${NODE_LOCAL_DNS_IP:?请在 config/cluster.env 设置 NODE_LOCAL_DNS_IP}"
: "${DNS_SERVICE_IP:?请在 config/cluster.env 设置 DNS_SERVICE_IP}"
KUBECTL="$ROOT/offline/bin/kubectl"
[[ -x "$KUBECTL" ]] || KUBECTL="$(command -v kubectl || true)"
[[ -n "$KUBECTL" && -x "$KUBECTL" ]] || die "找不到 kubectl"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export KUBECONFIG
[[ -s "$KUBECONFIG" ]] || die "缺少管理员 kubeconfig"

NODES_JSON="$("$KUBECTL" get nodes -o json)"
NODE_COUNT="$(printf '%s\n' "$NODES_JSON" | jq '.items | length')"
(( NODE_COUNT >= 2 )) || die "自动跨节点网络验收至少需要两个 Ready 节点"
mapfile -t TEST_NODES < <(printf '%s\n' "$NODES_JSON" | jq -r '.items[].metadata.name' | head -n 2)
NODE_A="${TEST_NODES[0]}"
NODE_B="${TEST_NODES[1]}"
[[ "$NODE_A" != "$NODE_B" ]] || die "无法选择两个不同节点执行跨节点验收"

DS_JSON="$("$KUBECTL" -n kube-system get ds node-local-dns -o json)"
DESIRED="$(printf '%s\n' "$DS_JSON" | jq -r '.status.desiredNumberScheduled')"
READY="$(printf '%s\n' "$DS_JSON" | jq -r '.status.numberReady')"
[[ "$DESIRED" == "$NODE_COUNT" && "$READY" == "$NODE_COUNT" ]] ||
  die "NodeLocal DNSCache 未覆盖全部节点：desired=$DESIRED ready=$READY nodes=$NODE_COUNT"

NAMESPACE="k8s-ha-verify"
MANIFEST="$(mktemp)"
cleanup() {
  rm -f "$MANIFEST"
  "$KUBECTL" delete namespace "$NAMESPACE" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

"$KUBECTL" create namespace "$NAMESPACE" --dry-run=client -o yaml | "$KUBECTL" apply -f -
cat > "$MANIFEST" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: network-server
  namespace: ${NAMESPACE}
  labels:
    app: network-server
spec:
  nodeName: ${NODE_A}
  tolerations:
    - operator: Exists
  containers:
    - name: server
      image: ${NETWORK_TEST_IMAGE}
      imagePullPolicy: Always
      command: ["/bin/sh", "-c"]
      args:
        - mkdir -p /www && printf 'cross-node-network-ok\\n' > /www/index.html && exec httpd -f -p 8080 -h /www
      ports:
        - name: http
          containerPort: 8080
---
apiVersion: v1
kind: Service
metadata:
  name: network-test
  namespace: ${NAMESPACE}
spec:
  selector:
    app: network-server
  ports:
    - name: http
      port: 8080
      targetPort: 8080
---
apiVersion: v1
kind: Pod
metadata:
  name: network-client
  namespace: ${NAMESPACE}
spec:
  nodeName: ${NODE_B}
  tolerations:
    - operator: Exists
  containers:
    - name: client
      image: ${NETWORK_TEST_IMAGE}
      imagePullPolicy: Always
      command: ["/bin/sh", "-c"]
      args: ["sleep 3600"]
EOF

log "创建固定调度到不同节点的 Harbor 测试 Pod：server=$NODE_A client=$NODE_B image=$NETWORK_TEST_IMAGE"
"$KUBECTL" apply -f "$MANIFEST"
"$KUBECTL" -n "$NAMESPACE" wait --for=condition=Ready pod/network-server pod/network-client --timeout=300s
SERVER_JSON="$("$KUBECTL" -n "$NAMESPACE" get pod network-server -o json)"
CLIENT_JSON="$("$KUBECTL" -n "$NAMESPACE" get pod network-client -o json)"
SERVER_NODE="$(printf '%s\n' "$SERVER_JSON" | jq -r '.spec.nodeName')"
CLIENT_NODE="$(printf '%s\n' "$CLIENT_JSON" | jq -r '.spec.nodeName')"
[[ "$SERVER_NODE" != "$CLIENT_NODE" ]] || die "测试 Pod 未跨节点调度：server=$SERVER_NODE client=$CLIENT_NODE"
for pod_json in "$SERVER_JSON" "$CLIENT_JSON"; do
  printf '%s\n' "$pod_json" | jq -e --arg image "$NETWORK_TEST_IMAGE" '
    .spec.containers[0].image == $image and
    .spec.containers[0].imagePullPolicy == "Always" and
    (.status.containerStatuses[0].imageID // "" | length > 0)
  ' >/dev/null || die "测试 Pod 未能证明从 Harbor 拉取镜像或容器未就绪"
done

RESOLV_CONF="$("$KUBECTL" -n "$NAMESPACE" exec network-client -- cat /etc/resolv.conf)"
printf '%s\n' "$RESOLV_CONF" | grep -Fq "nameserver $NODE_LOCAL_DNS_IP" ||
  die "测试 Pod resolv.conf 未使用 NodeLocal DNS IP $NODE_LOCAL_DNS_IP：$RESOLV_CONF"
"$KUBECTL" -n "$NAMESPACE" exec network-client -- nslookup kubernetes.default.svc.cluster.local "$NODE_LOCAL_DNS_IP" >/dev/null ||
  die "经 NodeLocal DNS 查询 kubernetes.default.svc.cluster.local 失败"
"$KUBECTL" -n "$NAMESPACE" exec network-client -- nslookup "network-test.$NAMESPACE.svc.cluster.local" >/dev/null ||
  die "经 Pod 默认 DNS 查询跨节点测试 Service 名称失败"

SERVER_IP="$(printf '%s\n' "$SERVER_JSON" | jq -r '.status.podIP')"
[[ -n "$SERVER_IP" && "$SERVER_IP" != null ]] || die "测试 Server Pod 缺少 Pod IP"
POD_RESPONSE="$("$KUBECTL" -n "$NAMESPACE" exec network-client -- wget -qO- "http://$SERVER_IP:8080/")"
[[ "$POD_RESPONSE" == "cross-node-network-ok" ]] || die "跨节点 Pod IP 网络验收失败：$POD_RESPONSE"
SERVICE_RESPONSE="$("$KUBECTL" -n "$NAMESPACE" exec network-client -- wget -qO- "http://network-test.$NAMESPACE.svc.cluster.local:8080/")"
[[ "$SERVICE_RESPONSE" == "cross-node-network-ok" ]] || die "跨节点 ClusterIP/Service DNS 验收失败：$SERVICE_RESPONSE"

"$KUBECTL" -n "$NAMESPACE" get pods -o wide
ok "自动化验收通过：Harbor 强制拉取、Pod 使用 NodeLocal DNS、集群 DNS、跨节点 Pod IP 和 ClusterIP Service 均正常。"
