# 防火墙与网络端口矩阵

应按来源节点组、目标节点组和业务用途实施最小权限放行，禁止将下列端口无差别向所有网络开放。

| 来源 | 目标 | 协议/端口 | 用途 |
|---|---|---:|---|
| Worker 节点 | Master 节点 | TCP 6443 | NGINX Stream 上游连接 kube-apiserver |
| 运维网络 | Master 节点/API_DNS | TCP 6443 | Kubernetes API（当前无 VIP/LB） |
| Master 节点 | 全部 etcd 成员 | TCP 2379 | etcd 客户端连接 |
| Master 节点 | Master 节点 | TCP 2380 | etcd 成员间通信 |
| 所有节点 | 本机回环地址 | TCP 6443 | 本机 kubelet/控制组件；Worker 由本机 NGINX 接入 |
| API Server | 所有节点 | TCP 10250 | kubelet API |
| Calico 节点 | Calico 节点 | UDP 4789 | VXLAN 数据平面 |
| 所有节点 | DNS 服务 | UDP/TCP 53 | 集群 DNS |
| 节点 | 容器镜像仓库 | TCP 5000（示例） | 私有镜像仓库 |
| 客户端 | Worker 节点 | TCP 30000-32767 | 仅在使用 NodePort 时开放 |

如果 Calico 仅使用 VXLAN，不启用 BGP 时无需开放 TCP/179。监控端口 10249、10257、10259 应仅向监控和授权管理来源开放。当前拓扑不使用 LB peer，因此无需开放 VRRP/IP 协议 112。
