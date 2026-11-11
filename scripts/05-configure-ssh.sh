#!/usr/bin/env bash
# 部署端：按 cluster.env 中的账号、密码和端口配置全部节点的 SSH 公钥登录。
set -Eeuo pipefail

source "$(dirname "$0")/lib.sh"
require_root

for cmd in ssh ssh-keygen ssh-copy-id; do
  require_cmd "$cmd"
done

if [[ -n "$SSH_PASSWORD" ]]; then
  require_cmd sshpass
fi

SSH_DIR="${HOME}/.ssh"
SSH_KEY="$SSH_DIR/kubernetes-binary-ha_ed25519"
SSH_CONFIG="$SSH_DIR/config"

install -d -m 0700 "$SSH_DIR"

SSH_TARGET_IPS=("${ALL_IPS[@]}")
HARBOR_IS_CLUSTER_NODE=0
for ip in "${SSH_TARGET_IPS[@]}"; do
  [[ "$ip" == "$HARBOR_NODE_IP" ]] && HARBOR_IS_CLUSTER_NODE=1
done
if (( HARBOR_IS_CLUSTER_NODE == 0 )); then
  SSH_TARGET_IPS+=("$HARBOR_NODE_IP")
fi

check_access() {
  local ip="$1"

  ssh -p "$SSH_PORT" \
    -o BatchMode=yes \
    -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=accept-new \
    "$SSH_USER@$ip" true >/dev/null 2>&1
}

NEED_KEY=0
for ip in "${SSH_TARGET_IPS[@]}"; do
  if ! check_access "$ip"; then
    NEED_KEY=1
  fi
done

if [[ "$NEED_KEY" -eq 1 ]]; then
  if [[ ! -s "$SSH_KEY" ]]; then
    log "生成专用 SSH Ed25519 密钥：$SSH_KEY"
    ssh-keygen -q -t ed25519 -N "" \
      -C "kubernetes-binary-ha-deploy" -f "$SSH_KEY"
    chmod 0600 "$SSH_KEY"
  elif [[ ! -s "$SSH_KEY.pub" ]]; then
    ssh-keygen -y -f "$SSH_KEY" > "$SSH_KEY.pub"
    chmod 0644 "$SSH_KEY.pub"
  fi

  chmod 0600 "$SSH_KEY"
  chmod 0644 "$SSH_KEY.pub"

  for ip in "${SSH_TARGET_IPS[@]}"; do
    if check_access "$ip"; then
      continue
    fi

    warn "向 $SSH_USER@$ip:$SSH_PORT 分发部署公钥；首次连接前请核对 SSH host key 指纹。"

    if [[ -n "$SSH_PASSWORD" ]]; then
      SSHPASS="$SSH_PASSWORD" sshpass -e ssh-copy-id \
        -p "$SSH_PORT" \
        -o StrictHostKeyChecking=accept-new \
        -i "$SSH_KEY.pub" "$SSH_USER@$ip"
    else
      ssh-copy-id \
        -p "$SSH_PORT" \
        -o StrictHostKeyChecking=accept-new \
        -i "$SSH_KEY.pub" "$SSH_USER@$ip"
    fi
  done

  touch "$SSH_CONFIG"
  chmod 0600 "$SSH_CONFIG"
  sed -i '/^# BEGIN KUBERNETES-BINARY-HA$/,/^# END KUBERNETES-BINARY-HA$/d' "$SSH_CONFIG"

  {
    printf '%s\n' '# BEGIN KUBERNETES-BINARY-HA'
    for ip in "${SSH_TARGET_IPS[@]}"; do
      printf 'Host %s\n  User %s\n  Port %s\n  IdentityFile %s\n  IdentitiesOnly yes\n  StrictHostKeyChecking accept-new\n\n' \
        "$ip" "$SSH_USER" "$SSH_PORT" "$SSH_KEY"
    done
    printf '%s\n' '# END KUBERNETES-BINARY-HA'
  } >> "$SSH_CONFIG"
fi

for i in "${!ALL_NAMES[@]}"; do
  ssh -p "$SSH_PORT" \
    -o BatchMode=yes \
    -o ConnectTimeout=8 \
    -o StrictHostKeyChecking=accept-new \
    "$SSH_USER@${ALL_IPS[$i]}" \
    'test -n "$(hostname -s)"' >/dev/null

  ok "${ALL_NAMES[$i]} SSH 公钥登录正常"
done

if (( HARBOR_IS_CLUSTER_NODE == 0 )); then
  ssh -p "$SSH_PORT" \
    -o BatchMode=yes \
    -o ConnectTimeout=8 \
    -o StrictHostKeyChecking=accept-new \
    "$SSH_USER@$HARBOR_NODE_IP" \
    'test -n "$(hostname -s)"' >/dev/null
  ok "Harbor 节点 $HARBOR_NODE_IP SSH 公钥登录正常"
fi

ok "全部集群节点及 Harbor 节点 SSH 公钥登录配置完成。"
