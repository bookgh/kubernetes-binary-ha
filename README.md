# Kubernetes v1.37.2 二进制高可用集群部署项目

基于 **Rocky Linux 9 / x86_64（amd64）**，使用 Kubernetes 官方二进制文件部署 Master 数量可配置的集群（示例默认三 Master、三 Worker），不使用 kubeadm。当前 API 入口采用 **Master 本机回环访问 + Worker 本机 NGINX TCP 代理**，暂不部署外部负载均衡器、Keepalived 或 VIP。

> **生产提示：** 本仓库仍在持续完善。生产部署前必须在 Rocky Linux 9 目标拓扑预演环境完成证书、镜像、网络、故障切换、备份恢复和升级验证。

## 一、架构与访问路径

| 节点 | 组件 | API 访问方式 |
|---|---|---|
| 全部 Master（示例 master-01～03） | kube-apiserver、controller-manager、scheduler、etcd | 本机组件访问 `https://127.0.0.1:6443` |
| 全部 Worker（示例 worker-01～03） | kubelet、kube-proxy、NGINX stream | 本机访问 `https://127.0.0.1:6443`，由 NGINX 转发到全部 Master |
| 运维终端 | kubectl、管理员 kubeconfig | `https://${API_DNS}:6443`；当前无 LB，DNS 应指向可达 Master |

Worker 本机 NGINX 只做 TCP 转发，不解密 TLS。Master 上的 kube-apiserver 必须监听 `0.0.0.0:6443`，以便 Worker 通过 Master 节点 IP 访问。

## 二、目录说明

- `config/`：集群参数、组件版本、kubelet/kube-proxy 和 NGINX 配置模板。
- `scripts/`：系统预检、离线资源准备、安装、证书、启动、验证和升级脚本。
- `scripts/ci/`：GitHub Actions 调用的构建与发布脚本，是离线资源构建流程的唯一实现入口。
- `systemd/`：containerd、etcd、Kubernetes 组件及 Worker NGINX 服务单元。
- `helm/`：CI 下载并随 Release 打包的 Calico CRD、Tigera Operator 和 CoreDNS Helm Charts。
- `nginx/Dockerfile`：从源码编译带 `stream` 模块的 NGINX。
- `docs/`：部署手册、参数、网络端口、离线镜像和生产验收文档。

## 三、部署前准备

1. 准备至少两台 Rocky Linux 9 x86_64 主机；先列出全部 Master（`master-*`），再列出至少一台 Worker（`worker-*`）。示例默认 3+3。
2. 配置固定 IP、DNS、NTP、路由、MTU、磁盘和防火墙策略。
3. 确认 `POD_CIDR`、`SERVICE_CIDR` 与现有网络无重叠。
4. 将 `config/cluster.env.example` 复制为 `config/cluster.env`，按顺序填写 `NODE_NAMES`、`NODE_IPS` 两个节点数组，并设置 `MASTER_COUNT`；前 `MASTER_COUNT` 项为 Master，其余自动成为 Worker。示例默认 `MASTER_COUNT=3`，生产环境建议采用奇数 etcd 成员。
5. 对照 `docs/PARAMETER-REFERENCE.md` 复核参数。

## 四、通过 GitHub Actions 构建离线 Release

NGINX 不再由运维人员在暂存机手动构建。所有二进制资源（包括 NGINX）由 GitHub Actions 统一构建、校验并发布。

### 新版 Release 内容与证书方式

当前离线发布修订号由 config/release-versions.env 的 RELEASE_REVISION 控制，当前修订使用 tag `k8s-v1.37.2-r7`。离线归档包含 CFSSL/cfssljson、Helm、Calicoctl、crictl、etcd、containerd、CNI plugins、Docker Engine、cri-dockerd、Docker Compose、Rocky Linux 9 RPM 及依赖；另含 Harbor 官方离线安装器、Calico/CoreDNS Helm Charts，以及 pause、Calico、NodeLocal DNSCache 和 BusyBox 网络验收镜像归档。完整清单见归档内 `ARTIFACTS.txt`、`IMAGE-REFERENCES.txt` 和 `SHA256SUMS`。

证书配置模板统一存放在 config/cfssl/，scripts/03-generate-pki.sh 使用 CFSSL 签发 X.509 证书，并为节点证书通过 -hostname 传入节点主机名和内网 IP。实际私钥与签发证书保留在部署机 pki/，不得提交到仓库。

从零部署及验收步骤见 [docs/INSTALL-FROM-SCRATCH.md](docs/INSTALL-FROM-SCRATCH.md)。核心脚本顺序为：

~~~bash
sudo bash scripts/01-prepare-offline.sh
sudo bash scripts/17-install-cli-tools.sh
sudo bash scripts/03-generate-pki.sh
sudo bash scripts/04-make-kubeconfigs.sh
sudo bash scripts/14-render-node-configs.sh
sudo bash scripts/15-distribute-node-configs.sh
~~~

集群安装完成后，依次执行 scripts/19-install-calico.sh、scripts/20-install-coredns.sh、scripts/25-install-node-local-dns.sh 和 scripts/18-verify-cluster.sh。最终验收会强制从 Harbor 拉取 BusyBox，并验证 Pod DNS、跨节点 Pod IP 与 ClusterIP Service。

### Issue 触发

1. 在仓库创建 Issue，标题或正文填写 Kubernetes 版本，例如 `v1.37.2`。
2. 为 Issue 添加 `build-offline` 标签。
3. Actions 自动调用 `scripts/ci/build-offline-release.sh`。
4. 脚本读取 `config/release-versions.env` 和 `config/cluster.env.example` 中的组件版本，统一下载 Kubernetes、etcd、containerd、runc、CNI、crictl、CFSSL、Helm、Calicoctl、Docker Engine、cri-dockerd、Docker Compose、Harbor offline installer，并在 Rocky Linux 9 容器中解析下载 RPM 依赖；CI 下载 Calico CRD/Operator（v3.33.0）与 CoreDNS（1.50.4）Helm Charts，渲染后从 Chart 默认配置和 Tigera Operator 动态清单提取全部镜像并打包。
5. 脚本通过 `nginx/Dockerfile` 在 Rocky Linux 9 容器构建环境源码编译 NGINX stream 二进制。
6. 发布 `k8s-vX.Y.Z-rN` Release，包含离线资源包、NGINX 独立二进制和 SHA256 文件；当前修订号为 r7。

### 手动触发

进入 **Actions → Issue 驱动的离线资源包构建与 Release 发布 → Run workflow**，输入版本号即可。

### 版本维护原则

- Kubernetes 版本由 Issue 或手动输入提供。
- etcd、containerd、runc、CNI、crictl、pause、NodeLocal DNS 和 NGINX 等版本在 `config/release-versions.env` 中维护；Calico（CRD 与 Operator）及 CoreDNS Helm Chart 版本只在 `config/cluster.env` 中维护（仓库默认值位于 `config/cluster.env.example`，CI 从该示例配置读取）；组件镜像 tag 由 Chart 默认值决定。
- 下载地址、校验、构建和 Release 上传只在 `scripts/ci/build-offline-release.sh` 中维护。
- Workflow YAML 只负责事件过滤、checkout 和调用仓库脚本，不重复维护 URL、版本矩阵或构建命令。
- 修改构建流程时优先修改脚本和配置，不要在 Workflow 中复制构建实现。

> Release 已包含 Harbor 官方离线安装器和项目明确列出的基础 OCI 镜像归档，但不包含完整 Rocky Linux 系统仓库快照，也不包含任意业务/扩展组件镜像。

## 统一安装入口（一条命令部署）

在填写 `config/cluster.env`、确认 GitHub Release 资源可下载、完成私有镜像仓库准备后，部署机使用 root 执行：

~~~bash
sudo bash scripts/00-install.sh all
~~~

统一入口会按依赖顺序完成离线资源下载与校验、部署机工具安装、SSH 公钥配置、CFSSL 证书、kubeconfig、节点配置生成与分发、全部节点系统优化、运行时和 systemd、Harbor 部署与基础镜像导入、etcd quorum 验证、全部 Master API `/readyz` 验证、Worker NGINX/kubelet、Calico、CoreDNS、NodeLocal DNSCache 和 Harbor/DNS/跨节点网络自动验收。

支持按阶段执行：`prepare`（预处理）、`download`、`ssh`、`certs`、`system`、`harbor`、`etcd`、`control-plane`、`workers`、`calico`、`coredns`、`node-local-dns`、`verify`、`status`。先执行预处理，再执行组件安装：

~~~bash
sudo bash scripts/00-install.sh prepare
sudo bash scripts/00-install.sh etcd
sudo bash scripts/00-install.sh workers
sudo bash scripts/00-install.sh verify
~~~

`etcd`、`control-plane` 和 `workers` 等组件阶段不会自动安装前置依赖或生成证书；执行前会检查所需证书及节点分发状态，缺失时提示先运行 `prepare` 并退出。`control-plane` 完成后会逐个探测所有 Master 的 API `/readyz`，未全部就绪时不会启动 Worker；单独执行 `workers` / `calico` 也有相同门槛。`all` 会显式先运行预处理，再部署所有组件。入口和每个节点均有独立执行锁、完成/失败标记、脚本及配置指纹和日志。失败后修复问题，再次执行同一命令即可跳过已完成且健康的阶段，继续失败阶段。etcd 已有数据时不会重新初始化；CFSSL 已生成的 CA、证书和 ServiceAccount 密钥会复用，防止重跑覆盖密钥。

详细说明见 [docs/UNIFIED-INSTALLER.md](docs/UNIFIED-INSTALLER.md)。`prepare` 完成后，`all` 会在 etcd 之前自动安装 Harbor 并导入基础镜像；也可单独运行 `sudo bash scripts/00-install.sh harbor`。当前 Harbor 默认通过 HTTP/80 访问，运行时配置为 insecure registry，而不是 TLS CA 证书信任。

## 五、集中式部署与配置分发

项目采用“部署端生成配置、批量分发、节点端安装执行”的模式。先在部署机完成 `config/cluster.env`，配置节点 IP、`RUNTIME_TYPE` 与 `KUBE_PROXY_MODE`，然后执行：

```bash
sudo bash scripts/14-render-node-configs.sh
sudo bash scripts/15-distribute-node-configs.sh
```

第一个脚本在本地 `generated/<node>/` 生成每台节点的 `cluster.env`、kubelet（`clusterDNS` 指向 `NODE_LOCAL_DNS_IP`，默认 `169.254.20.10`）、kube-proxy、NGINX stream 配置，以及 containerd/Docker、crictl 和 Harbor HTTP registry 信任配置；同时在 `generated/common/etc/` 生成内核模块清单和 sysctl 文件。第二个脚本通过 rsync/SCP 批量分发项目、离线资源、配置、证书和节点 kubeconfig。请先检查生成目录，再执行分发。远程安装脚本只安装二进制、应用已分发的内核配置、部署 systemd 单元并校验配置，不再用 heredoc 临时创建服务配置。

### 容器运行时选择

- `RUNTIME_TYPE="containerd"`：使用 containerd CRI socket。
- `RUNTIME_TYPE="docker"`：使用 Docker Engine + cri-dockerd，kubelet 连接 cri-dockerd 的 CRI socket。Docker Engine 本身不是 Kubernetes CRI 接口；Docker 模式需设置 `DOCKER_VERSION` 和 `CRI_DOCKERD_VERSION`，再运行离线资源准备脚本。

### kube-proxy 模式选择

- `KUBE_PROXY_MODE="ipvs"`：加载 IPVS 内核模块并安装 `ipvsadm`。注意：IPVS 自 Kubernetes v1.35 起已弃用，v1.40 起默认禁用，v1.43 计划移除。
- `KUBE_PROXY_MODE="nftables"`：推荐的新部署模式，要求 Linux kernel >= 5.13、`nft` >= 1.0.1，并安装 `nftables`；配置会显式写入 `mode: nftables`。

模式应在 kube-proxy 首次启动前确定。集群运行后切换代理模式属于网络变更，应安排维护窗口并验证 ClusterIP、NodePort 和跨节点流量。

## 六、节点部署顺序

### 6.1 部署机本地准备

以下步骤在部署机执行。先将 `config/cluster.env.example` 复制为 `config/cluster.env` 并填写参数：

```bash
# 在 Rocky Linux 9 amd64 暂存机准备离线资源
sudo bash scripts/01-prepare-offline.sh
# 暂存机与部署机分离时，先将 offline/ 目录复制到部署机项目根目录
sudo dnf install -y --disablerepo="*" offline/rpms/*.rpm
sudo bash scripts/17-install-cli-tools.sh
# 部署机需具备 rsync、ssh、scp 客户端

# 在部署机本地生成 PKI、kubeconfig 和各节点配置
sudo bash scripts/03-generate-pki.sh
sudo bash scripts/04-make-kubeconfigs.sh
sudo bash scripts/14-render-node-configs.sh

# 一次性批量同步项目、offline/、节点配置、节点证书和 kubeconfig
sudo bash scripts/15-distribute-node-configs.sh
```

`15-distribute-node-configs.sh` 不会分发根 CA 私钥、etcd CA 私钥或管理员 kubeconfig；节点只接收其角色所需的证书和 kubeconfig。管理员 kubeconfig 保留在部署机 `~/.kube/config`。

### 6.2 远程节点批量执行

部署机需按 `SSH_USER`、`SSH_PASSWORD`、`SSH_PORT` 配置 SSH 公钥登录；非 root 账号需免密 sudo。使用统一批量执行入口，支持 `all`、`masters`、`workers` 节点组；`--parallel` 表示并发执行，任一节点失败会返回失败状态：

```bash
# 全部节点系统预检、运行时安装和 systemd 安装
sudo bash scripts/16-batch-exec.sh all 00-preflight.sh --parallel
sudo bash scripts/16-batch-exec.sh all 02-install-runtime.sh --parallel
sudo bash scripts/16-batch-exec.sh all 06-install-systemd.sh --parallel
# 06 阶段会按选择加载 IPVS 或 nftables 内核模块，并应用生成的 sysctl 配置

# 先并发启动全部 etcd Master，再启动全部 Master 控制平面
sudo bash scripts/16-batch-exec.sh masters 07-bootstrap-etcd.sh --parallel
sudo bash scripts/16-batch-exec.sh masters 08-start-control-plane.sh --parallel
# 先确认每个 Master API /readyz 均正常，再启动 Worker

# Worker 先安装 NGINX API 代理，再启动 kubelet/kube-proxy
sudo bash scripts/16-batch-exec.sh workers 13-install-nginx-proxy.sh --parallel
sudo bash scripts/16-batch-exec.sh workers 09-start-worker.sh --parallel
```

### 6.3 后续集群组件

1. 确认 Harbor 已健康且离线镜像已导入，再依次执行 scripts/19-install-calico.sh、scripts/20-install-coredns.sh 和 scripts/25-install-node-local-dns.sh；Helm Chart 和 NodeLocal DNSCache 镜像均来自离线包/Harbor。
2. 确认全部镜像已同步到私有仓库或导入节点。
3. 执行 `sudo bash scripts/18-verify-cluster.sh`，自动验证 Harbor 镜像拉取、Pod DNS、跨节点 Pod IP 和 ClusterIP Service。NodeLocal DNSCache 必须在全部节点 Ready。
4. 使用 `kubectl get nodes -o wide` 检查节点状态。

`scripts/12-build-nginx-binary.sh` 已保留为兼容提示入口，不再执行本地构建。NGINX 必须来自对应 Kubernetes Release 离线包。

## 七、NGINX 离线安装

NGINX 由 Actions 构建并纳入离线包 `offline/bin/nginx`，Worker 不需要访问 GitHub Release：

```bash
sudo bash scripts/13-install-nginx-proxy.sh
sudo systemctl status nginx-k8s-api
curl --cacert /etc/kubernetes/pki/k8s-ca.crt https://127.0.0.1:6443/readyz
```

安装脚本从节点已分发的离线包读取 `offline/bin/nginx`，与包内 SHA256 及配置版本核对后安装。Worker 不需要 Docker/Podman、外网访问，也不需要在节点上编译源码。

## 八、常用检查

完整从零部署、证书检查、etcd 健康检查、Calico 状态和 CoreDNS/网络验收请参阅 [docs/INSTALL-FROM-SCRATCH.md](docs/INSTALL-FROM-SCRATCH.md)。部署完成后可运行：

```bash
sudo bash scripts/18-verify-cluster.sh
```

常用运维检查：

```bash
bash -n scripts/*.sh scripts/ci/*.sh
systemctl status etcd kube-apiserver kubelet kube-proxy nginx-k8s-api
# Runtime: containerd 模式使用 systemctl status containerd；Docker 模式使用 systemctl status docker cri-docker.socket
curl --cacert /etc/kubernetes/pki/k8s-ca.crt https://127.0.0.1:6443/readyz
kubectl get nodes -o wide
kubectl get pods -A -o wide
```

## 九、安全注意事项

- `k8s-ca.key`、`etcd-ca.key` 和 `front-proxy-ca.key` 等根 CA 私钥不得分发；专用 `cluster-signer.key` 仅分发到 Master 控制平面。节点证书和 kubeconfig 按最小权限分发。
- 不要通过关闭 SELinux 或防火墙规避配置问题。
- etcd 必须有异机备份，禁止同时停止两个成员。
- 当前无外部 LB，管理员 `API_DNS` 不是高可用入口；Master 故障时需调整 DNS 或 kubeconfig。
- 生产使用前必须完成目标拓扑预演、故障切换、备份恢复和升级演练。
