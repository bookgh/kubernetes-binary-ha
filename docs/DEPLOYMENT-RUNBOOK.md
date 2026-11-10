# Kubernetes 集群分阶段部署手册

本文以 Rocky Linux 9、amd64、三 Master + 三 Worker 为基线。请先完成网络与安全评审，再按阶段执行；不要跳过证书、镜像和 etcd 验证步骤。

## 阶段 0：站点与网络准备

- 核对六台主机名、静态 IP、DNS、MTU、路由、NTP、磁盘和时间同步。
- 确认 Pod CIDR、Service CIDR 不与 LAN、VPN、数据中心或云网络冲突。
- 确认 Worker 到所有 Master 的 TCP/6443 可达；Master 间 TCP/2379、2380 可达。
- 在联网暂存机配置 Rocky 软件仓库并准备离线资源。
- 将所有容器镜像同步到内网仓库或制作 OCI 归档。
- 与安全团队确认 SELinux、firewalld 和 NetworkManager 策略，不要未经评审直接关闭。

## 阶段 1：操作系统与运行时

1. 六台节点分别运行 `scripts/00-preflight.sh`。
2. 将 `offline/` 目录传输到六台节点。
3. 六台节点分别运行 `scripts/02-install-runtime.sh`。
4. 检查 `containerd`、`runc`、CNI 插件和 `crictl info`。
5. 确认 containerd 配置中 `SystemdCgroup = true`，CRI 插件已启用。
6. 将 `sandbox_image` 配置为已镜像到内网仓库的 pause 镜像，并配置 registry mirror。

## 阶段 2：PKI 与 kubeconfig

1. 在可信任 PKI 工作站运行 `scripts/03-generate-pki.sh`。
2. 检查证书 CN、O、SAN、EKU 和有效期。
3. 在可信任工作站运行 `scripts/04-make-kubeconfigs.sh`。
4. 向节点分发 Kubernetes CA 公钥证书；CA 私钥保持离线。
5. 每台 Master 仅接收本成员的 etcd server/peer 私钥和证书。
6. `apiserver-etcd-client` 凭据仅分发到 Master。
7. 每个 kubelet 只接收与本节点 Node 名称匹配的客户端证书和 kubeconfig。
8. 核对 controller-manager CSR 签名证书和私钥的分发策略。

## 阶段 3：构建 Worker 本机 API 代理

1. 在联网 Rocky Linux 9 amd64 构建机安装 Docker 或 Podman。
2. 运行 `scripts/12-build-nginx-binary.sh`，由 Dockerfile 从源码构建启用 stream 的 NGINX。
3. 检查 `offline/bin/nginx.sha256` 和构建信息文件。
4. 将项目和 `offline/bin/nginx` 传输到每台 Worker；Worker 无需 Docker/Podman。
5. 每台 Worker 配置 `config/cluster.env` 后运行 `scripts/13-install-nginx-proxy.sh`。
6. 验证 NGINX 配置、systemd 状态、本机监听地址和 API `/readyz`。
7. Master 不运行 NGINX；Master 本机组件直接访问 `127.0.0.1:6443`。

NGINX 以 TCP Stream 方式透传 TLS。Worker 到三台 Master 的 TCP/6443 必须放通，API Server 证书 SAN 必须包含 loopback 和所有 Master 地址。

## 阶段 4：三成员 etcd

1. 将 `systemd/etcd.service` 和每台 Master 专属证书分发到三台 Master。
2. 三台 Master 分别运行 `scripts/06-install-systemd.sh`。
3. 在计划好的初始化窗口内启动三成员 etcd，运行 `scripts/07-bootstrap-etcd.sh`。
4. 检查 `etcdctl endpoint health`、`endpoint status -w table` 和 `member list -w table`。
5. 创建初始快照，并在隔离环境演练恢复。

**严重警告：** `initial-cluster-state=new` 仅用于首次创建集群。禁止清空现有成员数据目录后将其作为恢复手段。成员替换和恢复必须遵循 etcd 恢复流程。

## 阶段 5：控制平面

1. 向每台 Master 分发 API Server、controller-manager 和 scheduler 所需证书及配置。
2. 确认 API Server SAN 包含 `127.0.0.1`、`API_DNS` 和每台 Master IP。
3. 三台 Master 分别运行 `scripts/06-install-systemd.sh`，再运行 `scripts/08-start-control-plane.sh`。
4. 分别通过 loopback 检查每台 Master 的 `/livez`、`/readyz`。
5. 从 Worker 本机 NGINX 代理检查 API 可用性。
6. 审核 RBAC 主体和权限范围后再应用清单。

## 阶段 6：Worker 节点

1. 向每台 Worker 分发节点专属 kubelet 证书和 kubeconfig。
2. 安装 kubelet 配置及 systemd 单元。
3. 确认 NGINX 本地 API 代理已启动，再运行 `scripts/09-start-worker.sh`。
4. 检查 Node 注册状态；CNI 正常后节点应变为 Ready。
5. 如使用 kube-proxy 模式，核对 kube-proxy 配置和 kubeconfig。

## 阶段 7：CNI、DNS 和工作负载

1. 应用 Calico CRD、Tigera Operator 和自定义资源清单。
2. 确保清单引用的每个镜像均已导入内网仓库或节点镜像缓存。
3. 检查 Calico Pod 和 `vxlan.calico` 网络接口。
4. 核对 CoreDNS 镜像、Service IP 和集群域后应用 CoreDNS。
5. 验证 `kubernetes.default.svc.cluster.local` 解析到 `10.96.0.1`。
6. 测试同节点/跨节点 Pod 通信、ClusterIP、NodePort 和出口网络。

## 阶段 8：高可用与验收

- 每次仅停止一台 API Server，验证 Worker 本机 NGINX 可切换到其他健康 Master。
- 每次仅停止一个 etcd 成员并验证 quorum；恢复后才能测试下一个成员。
- 严禁同时停止两个 etcd 成员。
- 演练 Worker drain/uncordon 和工作负载重新调度。
- 验证 etcd 备份恢复、证书续期、日志轮转、审计策略、监控和告警。
- 在与生产相同配置的预演集群完成升级演练。
