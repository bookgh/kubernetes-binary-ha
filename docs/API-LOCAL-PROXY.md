# Kubernetes API 本机入口与 NGINX 代理设计

## 一、设计目标

当前阶段不部署独立负载均衡节点，不配置 HAProxy、Keepalived 或 VIP。Master 节点上的 Kubernetes 组件访问本机 API；Worker 节点通过本机 NGINX TCP Stream 代理访问三台 Master。未来如需外部 LB，可单独扩展管理员入口，不改变 Worker 本地 `127.0.0.1:6443` 的访问约定。

## 二、请求链路

```text
Master 本机 kubelet / controller-manager / scheduler
  -> https://127.0.0.1:6443
  -> 本机 kube-apiserver（监听 0.0.0.0:6443）

Worker 本机 kubelet / kube-proxy
  -> https://127.0.0.1:6443
  -> 本机 NGINX stream 监听器
  -> master-01/02/03 节点 IP:6443
  -> 被选中的 kube-apiserver
```

NGINX 只安装在 Worker。GitHub Actions 通过 `nginx/Dockerfile` 编译 NGINX，并将二进制及 SHA256 发布到 Kubernetes 对应版本的 Release；Worker 安装脚本下载并验证该资产。集群节点不运行 NGINX 容器，也不要求安装 Docker/Podman。

## 三、kube-apiserver 监听要求

每台 Master 的 kube-apiserver 必须使用 `--bind-address=0.0.0.0`，并通过 `--advertise-address=${NODE_IP}` 发布本机可路由地址。不能将 API Server 仅绑定到 `127.0.0.1`，否则 Worker 无法通过 Master 节点 IP 连接。Master 本机客户端使用 loopback，不会绕行到其他 Master。

## 四、NGINX Stream 行为

- 监听地址：`127.0.0.1:6443`（实际端口由 `API_PORT` 控制）。
- 上游节点：`MASTER1_IP`、`MASTER2_IP`、`MASTER3_IP` 的 TCP `${API_PORT}`。
- 负载策略：`least_conn`；上游节点设置失败次数和故障判定时间。
- TLS：四层 TCP 透传，NGINX 不持有 Kubernetes API TLS 私钥，不终止 TLS。
- 服务：`nginx-k8s-api.service`，仅 Worker 主机启动。

## 五、证书 SAN

因为 TLS 握手由最终选中的 kube-apiserver 完成，其服务端证书 SAN 至少应包含：

- `IP:127.0.0.1`；
- 三台 Master 的节点 IP；
- `DNS:${API_DNS}`；
- `kubernetes`、`kubernetes.default`、`kubernetes.default.svc`、`kubernetes.default.svc.${CLUSTER_DOMAIN}`；
- Kubernetes Service IP（示例 `10.96.0.1`）。

不要将该配置改成 NGINX `http {}` 反向代理或 TLS 终止，除非重新设计证书、身份认证和审计链路。

## 六、管理员访问限制

管理员 kubeconfig 使用 `https://${API_DNS}:${API_PORT}`。当前没有 VIP/LB，因此 `API_DNS` 应解析到一台可达 Master；该入口不是 HA。Master 故障时需要临时修改 DNS 或 kubeconfig 指向其他健康 Master。未来增加外部 LB 时，需将 LB 地址加入 API Server 证书 SAN，并更新管理员 kubeconfig。

## 七、部署和验证

GitHub Actions 完成 Release 构建后，每台 Worker：

```bash
sudo bash scripts/13-install-nginx-proxy.sh
/usr/local/sbin/nginx -t -c /etc/nginx/nginx.conf
systemctl status nginx-k8s-api
curl --cacert /etc/kubernetes/pki/k8s-ca.crt https://127.0.0.1:6443/readyz
```

每台 Master：

```bash
curl --cacert /etc/kubernetes/pki/k8s-ca.crt https://127.0.0.1:6443/readyz
ss -lntp | grep ':6443'
```

如果本地 NGINX 进程和监听端口正常，但 `/readyz` 失败，应检查三台 Master 的 API Server 健康状态、证书 SAN、Worker 到 Master 的 TCP/6443 路由以及 NGINX 错误日志。
