#!/usr/bin/env bash
# 部署端：检查或配置到六台节点的 SSH 公钥登录。
set -Eeuo pipefail
source "$(dirname "$0")/lib.sh"
require_root
for cmd in ssh ssh-keygen ssh-copy-id; do require_cmd "$cmd"; done
SSH_DIR="${HOME}/.ssh"
SSH_KEY="${K8S_SSH_KEY:-$SSH_DIR/kubernetes-binary-ha_ed25519}"
install -d -m 0700 "$SSH_DIR"
check_access() {
  local ip="$1"
  ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "root@$ip" true >/dev/null 2>&1
}
NEED_KEY=0
for ip in "${ALL_IPS[@]}"; do
  if ! check_access "$ip"; then NEED_KEY=1; fi
done
if [[ "$NEED_KEY" -eq 1 ]]; then
  if [[ ! -s "$SSH_KEY" || ! -s "$SSH_KEY.pub" ]]; then
    log "生成专用 SSH Ed25519 密钥：$SSH_KEY"
    ssh-keygen -q -t ed25519 -N "" -C "kubernetes-binary-ha-deploy" -f "$SSH_KEY"
    chmod 0600 "$SSH_KEY"
  fi
  for ip in "${ALL_IPS[@]}"; do
    if ! check_access "$ip"; then
      warn "需要为 root@$ip 配置公钥；请按提示输入该节点 root 密码。首次连接前请核对 SSH host key 指纹。"
      ssh-copy-id -o StrictHostKeyChecking=accept-new -i "$SSH_KEY.pub" "root@$ip"
    fi
  done
fi
for i in "${!ALL_NAMES[@]}"; do
  ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "root@${ALL_IPS[$i]}" "test -n \"\$(hostname -s)\"" >/dev/null
  ok "${ALL_NAMES[$i]} SSH 免密登录正常"
done
ok "六台节点 SSH 公钥登录配置完成。"
