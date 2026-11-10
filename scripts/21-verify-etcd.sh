#!/usr/bin/env bash
# 在部署机执行：控制平面启动前验证 etcd 三成员、endpoint health 和唯一 Leader。
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
ENDPOINTS="https://${MASTER1_IP}:2379,https://${MASTER2_IP}:2379,https://${MASTER3_IP}:2379"
TLS=(--cacert="$PKI/etcd-ca.crt" --cert="$PKI/apiserver-etcd-client.crt" --key="$PKI/apiserver-etcd-client.key")
ETCDCTL_API=3 "$ETCDCTL" --endpoints="$ENDPOINTS" "${TLS[@]}" endpoint health
STATUS="$(ETCDCTL_API=3 "$ETCDCTL" --endpoints="$ENDPOINTS" "${TLS[@]}" endpoint status --write-out=json)"
printf '%s\n' "$STATUS" | jq -e 'length == 3 and ([.[] | select(.Status.leader == .Status.header.member_id)] | length == 1)' >/dev/null || die "etcd 必须有 3 个健康 endpoint 且恰有 1 个 Leader"
MEMBERS="$(ETCDCTL_API=3 "$ETCDCTL" --endpoints="$ENDPOINTS" "${TLS[@]}" member list --write-out=json)"
printf '%s\n' "$MEMBERS" | jq -e '.members | length == 3' >/dev/null || die "etcd member 数量不是 3"
printf '%s\n' "$STATUS" | jq -r '.[] | [.Endpoint, .Status.header.member_id, .Status.leader, .Status.raftTerm, .Status.raftIndex] | @tsv'
printf '%s\n' "$MEMBERS" | jq -r '.members[] | [.name, .ID, .peerURLs[0]] | @tsv'
ok "etcd 三成员健康，quorum 正常且唯一 Leader 已确认；可以继续启动控制平面。"
