#!/usr/bin/env bash
# 在部署机执行：控制平面启动前验证配置清单中的全部 etcd 成员、endpoint health 和唯一 Leader。
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
require_cmd jq
OFF="$ROOT/offline"
PKI="$ROOT/pki"
[[ -s "$OFF/src/etcd.tar.gz" ]] || die "缺少 Release etcd.tar.gz"
for f in "$PKI/etcd-ca.crt" "$PKI/apiserver-etcd-client.crt" "$PKI/apiserver-etcd-client.key"; do
  [[ -s "$f" ]] || die "缺少 etcd 验证凭据：$f"
done
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
tar -xzf "$OFF/src/etcd.tar.gz" -C "$TMP"
ETCDCTL="$(find "$TMP" -type f -name etcdctl -print -quit)"
[[ -x "$ETCDCTL" ]] || die "Release etcd 归档中未找到 etcdctl"
ENDPOINTS=""
for ip in "${MASTER_IPS[@]}"; do
  [[ -n "$ENDPOINTS" ]] && ENDPOINTS+=","
  ENDPOINTS+="https://$ip:2379"
done
TLS=(--cacert="$PKI/etcd-ca.crt" --cert="$PKI/apiserver-etcd-client.crt" --key="$PKI/apiserver-etcd-client.key")
ETCDCTL_API=3 "$ETCDCTL" --endpoints="$ENDPOINTS" "${TLS[@]}" endpoint health
STATUS="$(ETCDCTL_API=3 "$ETCDCTL" --endpoints="$ENDPOINTS" "${TLS[@]}" endpoint status --write-out=json)"
printf '%s\n' "$STATUS" | jq -e --argjson expected "$MASTER_COUNT" 'length == $expected and ([.[] | select(.Status.leader == .Status.header.member_id)] | length == 1)' >/dev/null || die "etcd endpoint 数量必须为 $MASTER_COUNT，且恰有 1 个 Leader"
MEMBERS="$(ETCDCTL_API=3 "$ETCDCTL" --endpoints="$ENDPOINTS" "${TLS[@]}" member list --write-out=json)"
printf '%s\n' "$MEMBERS" | jq -e --argjson expected "$MASTER_COUNT" '.members | length == $expected' >/dev/null || die "etcd member 数量必须等于 MASTER_COUNT=$MASTER_COUNT"
for i in "${!MASTER_NAMES[@]}"; do
  node="${MASTER_NAMES[$i]}"
  peer="https://${MASTER_IPS[$i]}:2380"
  printf '%s\n' "$MEMBERS" | jq -e --arg name "$node" --arg peer "$peer" '[.members[] | select(.name == $name and (.peerURLs | index($peer)))] | length == 1' >/dev/null || die "etcd 成员缺失或 peer URL 不匹配：$node ($peer)"
done
printf '%s\n' "$STATUS" | jq -r '.[] | [.Endpoint, .Status.header.member_id, .Status.leader, .Status.raftTerm, .Status.raftIndex] | @tsv'
printf '%s\n' "$MEMBERS" | jq -r '.members[] | [.name, .ID, .peerURLs[0]] | @tsv'
ok "etcd 三成员健康，quorum 正常且唯一 Leader 已确认；可以继续启动控制平面。"
