# Kubernetes 集群分阶段部署手册

## 统一安装入口

在满足 [从零部署指南](INSTALL-FROM-SCRATCH.md) 中的节点、网络、Release 和私有镜像仓库前置条件后，部署机可直接运行：

~~~bash
sudo bash scripts/00-install.sh all
~~~

入口会按顺序完成离线下载、SSH 公钥配置、CFSSL、配置分发、全部节点运行时与系统参数、Harbor 镜像导入、etcd quorum、全部 Master API `/readyz`、Worker、Calico、CoreDNS、NodeLocal DNSCache 和端到端验收。失败后查看 `/var/log/kubernetes-binary-ha-install/` 与节点 `/var/log/kubernetes-binary-ha/`，修复后重复同一命令即可续装。参数和标记机制见 [统一安装入口说明](UNIFIED-INSTALLER.md)。


本文以 Rocky Linux 9、amd64、示例三 Master + 三 Worker 为基线；Master 数量由 `MASTER_COUNT` 决定。所有集群参数集中在部署机的 `config/cluster.env`。

## 阶段 0：站点准备

- 核对六台主机名、静态 IP、DNS、MTU、路由、NTP、磁盘和时间同步。
- 确认 Pod CIDR/Service CIDR 不与现有网络重叠；`NODE_LOCAL_DNS_IP` 默认 `169.254.20.10`，确保该地址不冲突，并允许节点本机 Pod 到该地址的 UDP/TCP 53。
- 确认 Worker 到所有 Master 的 TCP/6443 可达；Master 间 TCP/2379、2380 可达。
- 在 GitHub Actions 中构建 k8s-vX.Y.Z-rN Release，确认完整离线包、RPM、CFSSL/Helm/Calicoctl/Docker/Compose、离线 NGINX 二进制及 SHA256 已上传。
- 准备 pause、Calico、CoreDNS、NodeLocal DNSCache、BusyBox 网络验收镜像和业务容器镜像。
- 配置部署机到全部 Master、Worker 及独立 Harbor 节点的 SSH 公钥免密登录；明确执行 `sudo bash scripts/05-configure-ssh.sh`，并逐台验证 BatchMode 登录成功。

## 阶段 1：部署机本地生成与批量分发

在部署机配置 `config/cluster.env`，确认节点 IP、`RUNTIME_TYPE` 和 `KUBE_PROXY_MODE`。在 Rocky Linux 9 amd64 暂存机准备离线资源，然后在部署机本地生成 PKI、kubeconfig 和每节点配置：

```bash
sudo bash scripts/01-prepare-offline.sh
# 暂存机与部署机分离时，将 offline/ 目录先复制到部署机项目根目录
# 按 RPM 根包清单安装部署机依赖及 CLI 工具
sudo bash scripts/00-install.sh download
# 先配置 SSH 公钥登录，再进行后续文件分发
sudo bash scripts/05-configure-ssh.sh
sudo bash scripts/03-generate-pki.sh  # CFSSL 按仓库 CSR/profile 签发，-hostname 使用裸 DNS 名和 IP
sudo bash scripts/04-make-kubeconfigs.sh
sudo bash scripts/14-render-node-configs.sh
sudo bash scripts/15-distribute-node-configs.sh
```

- `14` 在本地生成 `generated/<node>/` 下的 kubelet、kube-proxy 和运行时配置，并在 `generated/common/etc/` 生成内核模块清单与 sysctl 文件。
- `15` 通过 rsync/SCP 同步项目文件、离线资源、节点配置和节点专属凭据。
- 根 CA 私钥、etcd CA 私钥和管理员 kubeconfig 不分发到节点；专用 `cluster-signer.key` 仅分发到 Master 控制平面。
- 分发后先检查各节点的 `/opt/kubernetes-binary-ha`、`/etc/kubernetes` 和 `/etc/etcd/pki` 文件权限。

### SSH 公钥登录（必须先于配置分发）

在 `config/cluster.env` 设置 `SSH_USER`、`SSH_PASSWORD`、`SSH_PORT`。密码仅用于首次公钥分发；留空时由 `ssh-copy-id` 交互式询问。配置非空密码需部署机具备 `sshpass`。普通 SSH 用户必须具备免密 sudo。

~~~bash
sudo bash scripts/05-configure-ssh.sh
sudo ssh -p 22 -o BatchMode=yes root@<MASTER_IP> true
sudo ssh -p 22 -o BatchMode=yes root@<WORKER_IP> true
~~~

脚本自动生成/复用部署机专用 Ed25519 密钥，并配置全部集群节点；Harbor 为独立主机时也会加入目标列表。首次连接前应核对 SSH host key 指纹。脚本通过 BatchMode 对所有目标执行登录验证，全部成功后才能继续执行 `15-distribute-node-configs.sh`。不要分发部署机私钥，也不要将密码或密钥提交到仓库。
## 阶段 2：系统预检、运行时与 systemd

在部署机先切换到仓库源码根目录，然后执行。默认推荐方式 1，通过 SSH 直接执行远端已分发的脚本：

~~~bash
cd /path/to/kubernetes-binary-ha
bash scripts/16-batch-exec.sh all scripts/00-preflight.sh --parallel
bash scripts/16-batch-exec.sh all scripts/02-install-runtime.sh --parallel
bash scripts/16-batch-exec.sh all scripts/06-install-systemd.sh --parallel
~~~

- **方式 1（默认，推荐）**：SSH 直接执行远端 `/opt/kubernetes-binary-ha/scripts/` 下的脚本；先完成 `scripts/15-distribute-node-configs.sh`。
- **方式 2（`--copy`）**：先 SCP 本地脚本到远端，再安装并执行。只更新单个脚本时可用：

~~~bash
bash scripts/16-batch-exec.sh all scripts/02-install-runtime.sh --parallel --copy
~~~

脚本参数必须传 `scripts/xxx.sh` 完整相对路径，不再使用单独文件名。两种模式都支持节点组及并行执行。

- `RUNTIME_TYPE=containerd`：安装 containerd 并使用 `unix:///run/containerd/containerd.sock`。
- `RUNTIME_TYPE=docker`：安装 Docker Engine + cri-dockerd，kubelet 使用 `unix:///run/cri-dockerd.sock`。Docker Engine socket 不是 CRI socket。
- `KUBE_PROXY_MODE=ipvs`：安装 `ipvsadm` 并加载 IPVS 内核模块；该模式自 Kubernetes v1.35 起已弃用，v1.40 起默认禁用。
- `KUBE_PROXY_MODE=nftables`：推荐新部署使用；要求 Linux kernel >= 5.13、`nft` >= 1.0.1，并安装 `nftables`。
- `02-install-runtime.sh` 会从离线包安装 etcd/Kubernetes/CNI/runc；containerd 模式还会安装 containerd、ctr 和 shim 二进制，Docker 模式安装 Docker Engine + cri-dockerd。
- `06-install-systemd.sh` 应用部署端生成的内核模块和 sysctl 配置，再安装 systemd 单元。
- 检查运行时状态、`crictl info`、CNI 二进制和 pause 镜像配置。

## 阶段 3：Harbor 离线部署与镜像导入

在 etcd 初始化前执行：

~~~bash
sudo bash scripts/00-install.sh harbor
~~~

确认 Harbor API 健康，且 `IMAGE-REFERENCES.txt` 中的基础镜像全部推送成功。Harbor 可部署在集群节点或独立 Rocky Linux 9 节点。

## 阶段 4：etcd 与控制平面

全部 Master etcd 成员应并发启动：

```bash
sudo bash scripts/16-batch-exec.sh masters 07-bootstrap-etcd.sh --parallel
```

确认 etcd endpoint health、成员列表和 quorum 后，再启动控制平面：

~~~bash
sudo bash scripts/21-verify-etcd.sh
~~~

```bash
sudo bash scripts/16-batch-exec.sh masters 08-start-control-plane.sh --parallel
```

通过 SSH 在每台 Master 本机检查 `https://127.0.0.1:6443/readyz`；统一安装入口会自动等待全部 Master 就绪。禁止在已有 etcd 数据目录上重复执行首次初始化。

## 阶段 5：Worker NGINX 与 kubelet

先在 Worker 使用已分发离线包中的 NGINX（不访问 GitHub），再启动 Worker 服务：

```bash
sudo bash scripts/16-batch-exec.sh workers 13-install-nginx-proxy.sh --parallel
sudo bash scripts/16-batch-exec.sh workers 09-start-worker.sh --parallel
```

NGINX 只做 TCP/TLS 透传，不终止 TLS。检查本机 `127.0.0.1:6443` 可访问 API Server，随后确认 Worker 节点注册为 Ready。

## 阶段 6：CNI、CoreDNS、NodeLocal DNS 与验收

~~~bash
sudo bash scripts/19-install-calico.sh
sudo bash scripts/20-install-coredns.sh
sudo bash scripts/25-install-node-local-dns.sh
sudo bash scripts/18-verify-cluster.sh
~~~

1. scripts/19-install-calico.sh 应用 Release 中的 Calico CRD、Operator 和 Installation CR（默认 VXLAN、BGP Disabled）。
2. 确认全部镜像均已导入内网仓库或节点缓存。
3. 检查 Calico VXLAN、跨节点 Pod 通信。
4. scripts/20-install-coredns.sh 部署 CoreDNS 并验证集群域名解析。
5. scripts/25-install-node-local-dns.sh 部署 NodeLocal DNSCache；全部节点 DaemonSet Ready 后，Pod kubelet DNS 使用 `NODE_LOCAL_DNS_IP`，CoreDNS Service 仍使用 `DNS_SERVICE_IP`。
6. scripts/18-verify-cluster.sh 调用 `scripts/26-verify-network.sh`，强制从 Harbor 拉取 BusyBox 测试镜像，检查 Pod `/etc/resolv.conf`、集群 DNS、跨节点 Pod IP 和 ClusterIP Service DNS/流量，结束后自动清理测试 namespace。
7. 逐台停止 API Server，验证 Worker NGINX 能切换到其他健康 Master。
8. 完成 etcd 快照异机保存和恢复演练。

**重要：** `initial-cluster-state=new` 仅用于首次创建 etcd 集群，禁止通过删除现有数据目录重建成员。
