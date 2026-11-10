# Kubernetes 集群分阶段部署手册

本文以 Rocky Linux 9、amd64、三 Master + 三 Worker 为基线。所有集群参数集中在部署机的 `config/cluster.env`。

## 阶段 0：站点准备

- 核对六台主机名、静态 IP、DNS、MTU、路由、NTP、磁盘和时间同步。
- 确认 Pod CIDR/Service CIDR 不与现有网络重叠。
- 确认 Worker 到所有 Master 的 TCP/6443 可达；Master 间 TCP/2379、2380 可达。
- 在 GitHub Actions 中创建 NGINX Release，确认独立 NGINX 资产及 SHA256 已上传。
- 准备 pause、Calico、CoreDNS 和业务容器镜像。
- 配置部署机到六台节点的 root SSH 免密登录。

## 阶段 1：部署机本地生成与批量分发

在部署机配置 `config/cluster.env`，确认节点 IP、`RUNTIME_TYPE` 和 `KUBE_PROXY_MODE`。在 Rocky Linux 9 amd64 暂存机准备离线资源，然后在部署机本地生成 PKI、kubeconfig 和每节点配置：

```bash
sudo bash scripts/01-prepare-offline.sh
sudo bash scripts/17-install-cli-tools.sh
# 暂存机与部署机分离时，将 offline/ 目录先复制到部署机项目根目录
# 部署机需要 rsync、ssh、scp 客户端
sudo dnf install -y rsync openssh-clients
sudo bash scripts/03-generate-pki.sh  # CFSSL 按仓库 CSR/profile 签发，-hostname 使用裸 DNS 名和 IP
sudo bash scripts/04-make-kubeconfigs.sh
sudo bash scripts/14-render-node-configs.sh
sudo bash scripts/15-distribute-node-configs.sh
```

- `14` 在本地生成 `generated/<node>/` 下的 kubelet、kube-proxy 和运行时配置，并在 `generated/common/etc/` 生成内核模块清单与 sysctl 文件。
- `15` 通过 rsync/SCP 同步项目文件、离线资源、节点配置和节点专属凭据。
- 根 CA 私钥、etcd CA 私钥和管理员 kubeconfig 不分发到节点；专用 `cluster-signer.key` 仅分发到 Master 控制平面。
- 分发后先检查各节点的 `/opt/kubernetes-binary-ha`、`/etc/kubernetes` 和 `/etc/etcd/pki` 文件权限。

## 阶段 2：系统预检、运行时与 systemd

在部署机使用批量执行入口：

```bash
sudo bash scripts/16-batch-exec.sh all 00-preflight.sh --parallel
sudo bash scripts/16-batch-exec.sh all 02-install-runtime.sh --parallel
sudo bash scripts/16-batch-exec.sh all 06-install-systemd.sh --parallel
```

- `RUNTIME_TYPE=containerd`：安装 containerd 并使用 `unix:///run/containerd/containerd.sock`。
- `RUNTIME_TYPE=docker`：安装 Docker Engine + cri-dockerd，kubelet 使用 `unix:///run/cri-dockerd.sock`。Docker Engine socket 不是 CRI socket。
- `KUBE_PROXY_MODE=ipvs`：安装 `ipvsadm` 并加载 IPVS 内核模块；该模式自 Kubernetes v1.35 起已弃用，v1.40 起默认禁用。
- `KUBE_PROXY_MODE=nftables`：推荐新部署使用；要求 Linux kernel >= 5.13、`nft` >= 1.0.1，并安装 `nftables`。
- `02-install-runtime.sh` 会从离线包安装 etcd/Kubernetes/CNI/runc；containerd 模式还会安装 containerd、ctr 和 shim 二进制，Docker 模式安装 Docker Engine + cri-dockerd。
- `06-install-systemd.sh` 应用部署端生成的内核模块和 sysctl 配置，再安装 systemd 单元。
- 检查运行时状态、`crictl info`、CNI 二进制和 pause 镜像配置。

## 阶段 3：etcd 与控制平面

三台 etcd 成员应并发启动：

```bash
sudo bash scripts/16-batch-exec.sh masters 07-bootstrap-etcd.sh --parallel
```

确认 etcd endpoint health、成员列表和 quorum 后，再启动控制平面：

```bash
sudo bash scripts/16-batch-exec.sh masters 08-start-control-plane.sh --parallel
```

分别检查三台 API Server 的 `/livez` 和 `/readyz`。禁止在已有 etcd 数据目录上重复执行首次初始化。

## 阶段 4：Worker NGINX 与 kubelet

先在 Worker 安装 Release 中的 NGINX，再启动 Worker 服务：

```bash
sudo bash scripts/16-batch-exec.sh workers 13-install-nginx-proxy.sh --parallel
sudo bash scripts/16-batch-exec.sh workers 09-start-worker.sh --parallel
```

NGINX 只做 TCP/TLS 透传，不终止 TLS。检查本机 `127.0.0.1:6443` 可访问 API Server，随后确认 Worker 节点注册为 Ready。

## 阶段 5：CNI、DNS 与验收

~~~bash
sudo bash scripts/19-install-calico.sh
sudo bash scripts/20-install-coredns.sh
sudo bash scripts/18-verify-cluster.sh
~~~

1. scripts/19-install-calico.sh 应用 Release 中的 Calico CRD、Operator 和 Installation CR（默认 VXLAN、BGP Disabled）。
2. 确认全部镜像均已导入内网仓库或节点缓存。
3. 检查 Calico VXLAN、跨节点 Pod 通信。
4. scripts/20-install-coredns.sh 部署 CoreDNS 并验证集群域名解析。
5. scripts/18-verify-cluster.sh 检查 etcd endpoint health/member/quorum、API /readyz、Node Ready、Calico DaemonSet/TigeraStatus/IPPools、CoreDNS；然后验证 ClusterIP、NodePort 和跨节点 Service 流量。
6. 逐台停止 API Server，验证 Worker NGINX 能切换到其他健康 Master。
7. 完成 etcd 快照异机保存和恢复演练。

**重要：** `initial-cluster-state=new` 仅用于首次创建 etcd 集群，禁止通过删除现有数据目录重建成员。
