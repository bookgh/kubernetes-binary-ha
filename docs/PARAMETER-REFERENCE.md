# 集群参数参考

所有参数集中在 `config/cluster.env`。请从 `config/cluster.env.example` 复制后修改，不要在示例文件中写入生产密码或私钥。

## 集群与网络参数

- `K8S_VERSION`：Kubernetes 精确补丁版本，核心组件版本应保持一致。
- `CLUSTER_NAME`：kubeconfig 中的集群上下文名称。
- `CLUSTER_DOMAIN`：集群内部 DNS 后缀。
- `API_DNS`、`API_PORT`：管理员访问 Kubernetes API 的 DNS 名称和端口。当前无 LB/VIP，DNS 必须解析到一台可达 Master；管理员入口暂不具备 HA。
- `NGINX_VERSION`：由 GitHub Actions 按该版本源码编译并发布到 Kubernetes Release 的 NGINX 版本，启用 stream 模块。
- `POD_CIDR`：必须与 controller-manager `--cluster-cidr` 和 Calico IPPool 一致。
- `SERVICE_CIDR`：必须与 API Server `--service-cluster-ip-range` 一致。
- `DNS_SERVICE_IP`：CoreDNS ClusterIP，必须与 kubelet `clusterDNS` 一致。
- `KUBERNETES_SERVICE_IP`：Kubernetes API Service 的 ClusterIP，必须是 SERVICE_CIDR 中的首个 Service IP，并进入 API Server 证书 SAN。
- `MASTER_COUNT`：Master 数量；当前固定为 `3`，不可调整。
- `NODE_NAMES`：六个节点主机名的唯一清单，前三项必须是 `master-*`，后三项必须是 `worker-*`。
- `NODE_IPS`：与 `NODE_NAMES` 按索引一一对应的六个 IPv4 地址；修改节点时只需同步修改这两个数组。
- `MASTER_NAMES`/`MASTER_IPS`、`WORKER_NAMES`/`WORKER_IPS`、`ALL_NAMES`/`ALL_IPS`：由 `scripts/lib.sh` 根据上述两个数组自动派生，供现有部署脚本使用，不要在 `cluster.env` 中重复定义。
- `MASTER1_IP`～`MASTER3_IP`、`WORKER1_IP`～`WORKER3_IP`：由 `scripts/lib.sh` 自动派生的兼容变量，供现有配置模板、etcd 检查和远端节点配置使用，不要手工维护。
- `PRIVATE_REGISTRY`：隔离环境或内网镜像仓库地址。
- `COREDNS_IMAGE`：CoreDNS 已同步至私有仓库的完整镜像引用。
- `PAUSE_IMAGE`：容器 sandbox/pause 镜像，containerd 和 Docker/cri-dockerd 均需可访问。

## 运行时与 kube-proxy 参数

- `RUNTIME_TYPE`：`containerd` 或 `docker`。Docker 模式由 cri-dockerd 提供 CRI 兼容接口。
- `cluster-signer.key`：独立节点证书签发 CA 私钥，只分发到 Master 控制平面；根 CA 私钥保持离线。
- `CONTAINER_RUNTIME_ENDPOINT`：由 `RUNTIME_TYPE` 在本地配置生成阶段自动派生，不在 `cluster.env` 中单独维护。containerd 为 `unix:///run/containerd/containerd.sock`；Docker/cri-dockerd 为 `unix:///run/cri-dockerd.sock`。
- `DOCKER_VERSION`：Docker 静态二进制版本，Docker 模式必填。
- `CRI_DOCKERD_VERSION`：cri-dockerd 版本，Docker 模式必填。
- `KUBE_PROXY_MODE`：`ipvs` 或 `nftables`，配置文件显式指定，不依赖 kube-proxy 默认值。Kubernetes v1.37 中 IPVS 已弃用，建议新部署选择 nftables。
- `IPVS_STRICT_ARP`：IPVS 模式的 strictARP 设置。
- `NFTABLES_MASQUERADE_BIT`：nftables 模式 masquerade fwmark bit，范围 0–31。
- `scripts/17-install-cli-tools.sh` 从离线 Release 安装 Helm、Calicoctl、crictl、CFSSL 和 cfssljson。
- `scripts/14-render-node-configs.sh` 会根据模式生成 `/etc/modules-load.d/10-kubernetes.conf` 和 `/etc/sysctl.d/95-kubernetes.conf`；`scripts/15-distribute-node-configs.sh` 批量分发，`scripts/06-install-systemd.sh` 在节点加载模块并应用 sysctl。

## 组件版本参数

- `ETCD_VERSION`：etcd 发布版本；升级前核对 Kubernetes 与 etcd 兼容性。
- `CFSSL_VERSION`：CFSSL/cfssljson 版本；证书签发模板位于 config/cfssl/。
- `HELM_VERSION`：部署端 Helm CLI 版本。
- `CALICOCTL_VERSION`：Calicoctl CLI 版本，应与 CALICO_VERSION 匹配。
- `DOCKER_COMPOSE_VERSION`：Docker Compose CLI plugin 版本。
- `RELEASE_REVISION`：位于 config/release-versions.env，用于生成不可变 Release tag 后缀。
- `CONTAINERD_VERSION`：containerd 版本；核对 Kubernetes 1.37 所需 CRI 兼容性。
- `RUNC_VERSION`：OCI runtime 版本；应验证上游校验和/签名。
- `CNI_PLUGINS_VERSION`：标准 CNI 辅助二进制版本。
- `CRICTL_VERSION`：CRI 调试命令行工具版本。
- `CALICO_VERSION`：Calico 版本；清单和镜像必须与该版本匹配。
- `COREDNS_VERSION`：CoreDNS 镜像版本；生产环境建议固定 digest。
- `ARCH`：目标架构，本项目基线为 `amd64`。

## etcd 参数

- `ETCD_HEARTBEAT_INTERVAL`：Raft 心跳间隔，单位毫秒；示例 100。
- `ETCD_ELECTION_TIMEOUT`：选举超时，单位毫秒，应大于心跳间隔；根据网络 RTT 调优。
- `ETCD_QUOTA_BACKEND_BYTES`：后端数据库配额，示例 8 GiB；需监控告警并安全执行压缩/碎片整理。
- `--initial-cluster`：三成员 peer 映射必须在所有成员上完全一致。
- `--initial-cluster-state=new`：仅用于首次创建集群，不可用作恢复手段。
- `--listen-client-urls`：客户端监听地址，TCP/2379，仅允许 API Server 和授权运维端访问。
- `--listen-peer-urls`：成员间监听地址，TCP/2380，仅允许 etcd 成员访问。
- `--client-cert-auth`、`--peer-client-cert-auth`：启用双向 TLS 认证。

## kube-apiserver 参数

- `--advertise-address`：当前 Master 的可路由 IP，不是 API DNS。
- `--bind-address`：当前必须为 `0.0.0.0`，以接受 Worker 到 Master 节点 IP 的请求。
- `--secure-port`：HTTPS API 端口，默认 6443。
- `--authorization-mode=Node,RBAC`：Node Authorizer 与 RBAC。
- `--enable-admission-plugins=NodeRestriction`：限制节点身份可执行的操作。
- `--etcd-servers`：三台 etcd TLS 客户端端点。
- `--service-account-issuer` 及签名密钥：ServiceAccount Token 的签发者和签名配置。

## Controller Manager、Scheduler、Kubelet 与 containerd

- `--leader-elect=true`：多个控制器副本中仅一个实例持有主租约。
- `--cluster-cidr`：必须与 Pod CIDR 一致。
- `--allocate-node-cidrs=true`：为节点分配 PodCIDR。
- `--cluster-signing-*`：证书签发配置，必须保护私钥。
- `containerRuntimeEndpoint`：由 `RUNTIME_TYPE` 决定；Docker 模式通过 cri-dockerd socket 接入。
- `cgroupDriver=systemd`：必须与 containerd `SystemdCgroup=true` 一致。
- `authentication.x509.clientCAFile`：kubelet 客户端证书 CA。
- `authorization.mode=Webhook`：将授权请求委托给 API Server。
- `readOnlyPort=0`：关闭未认证的 kubelet 只读端口。
- `clusterDNS`：必须等于 CoreDNS Service ClusterIP。
- `sandbox_image`：pause 镜像必须提前镜像并与运行时配置一致。

## NGINX 本地 API 代理

- NGINX 仅部署在 Worker，监听 `127.0.0.1:6443`。
- 上游为三台 Master 的 TCP/6443。
- NGINX 使用 stream TCP 透传，不终止 TLS。
- API Server 证书 SAN 必须包含 `127.0.0.1` 和所有 Master IP。
- Docker 仅在 GitHub Actions 构建任务中使用；Worker 从对应 Release 下载 NGINX 资产并验证 SHA256。
- Master 本机客户端直接访问本机 API Server 的 `127.0.0.1:6443`。
