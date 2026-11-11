# 统一安装入口与断点续装

## 1. 一条命令完成部署

本项目新增统一入口 `scripts/00-install.sh`。在部署机完成配置、Release 资源准备和镜像仓库准备后，以 root 执行：

~~~bash
sudo bash scripts/00-install.sh all
~~~

该入口按依赖顺序完成：Release 离线资源下载与校验、部署机 RPM/CLI 安装、SSH 公钥登录、CFSSL PKI、kubeconfig、节点配置渲染与分发、全部节点系统预检、容器运行时、systemd/内核参数、**Harbor 离线部署与基础镜像导入**、etcd、控制平面、Worker、NGINX、Calico、CoreDNS、NodeLocal DNSCache 和端到端网络验收。

> 一条命令不代表跳过环境准备。首次运行前须配置 `HARBOR_NODE_IP`、`HARBOR_HOST`、`HARBOR_URL`、`PRIVATE_REGISTRY` 和镜像引用；`HARBOR_NODE_IP` 可以是集群节点，也可以是独立的 Rocky Linux 9 主机。Release 已包含 Harbor 官方离线安装器和基础 Kubernetes/Calico 镜像归档。Harbor 在 `prepare` 完成后、etcd 启动前部署。当前默认使用 HTTP/80，因此运行时配置的是 HTTP insecure registry，而不是 TLS CA 证书信任。请先核验 SSH host key 指纹；SSH 用户、密码和端口从 `cluster.env` 读取。非 root SSH 用户必须具备免密 sudo 权限。

## 2. 安装参数

| 命令 | 执行内容 |
|---|---|
| `sudo bash scripts/00-install.sh all` | 从下载到最终验收的完整流程 |
| `sudo bash scripts/00-install.sh prepare` | 显式执行预处理：下载资源、安装部署机工具、配置 SSH、生成证书/kubeconfig、渲染分发配置，并完成节点预检、运行时和 systemd 准备 |
| `sudo bash scripts/00-install.sh download` | 仅下载 Release、校验离线包、安装部署机 RPM 和 CLI |
| `sudo bash scripts/00-install.sh ssh` | 配置并验证全部节点 SSH 公钥登录 |
| `sudo bash scripts/00-install.sh certs` | SSH 检查、生成/复用证书、kubeconfig、渲染和分发 |
| `sudo bash scripts/00-install.sh system` | `prepare` 的兼容别名，执行完整预处理 |
| `sudo bash scripts/00-install.sh harbor` | 在 `HARBOR_NODE_IP` 指定节点部署 Harbor，并导入/推送离线镜像 |
| `sudo bash scripts/00-install.sh etcd` | 检查 Harbor 健康、证书和节点配置，再启动 etcd 并按 MASTER_COUNT 验证成员和 quorum；缺少前置条件立即退出 |
| `sudo bash scripts/00-install.sh control-plane` | 验证 etcd quorum 后启动全部 Master，并等待每台 Master API `/readyz` 成功 |
| `sudo bash scripts/00-install.sh workers` | 检查证书、节点配置及全部 Master API `/readyz`，再安装 Worker NGINX 并启动 kubelet/kube-proxy；不自动执行前置准备 |
| `sudo bash scripts/00-install.sh calico` | 完成前置阶段后安装 Calico |
| `sudo bash scripts/00-install.sh coredns` | 完成前置阶段后安装 CoreDNS |\n| `sudo bash scripts/00-install.sh node-local-dns` | 安装 NodeLocal DNSCache，并等待全部节点 DaemonSet Ready |
| `sudo bash scripts/00-install.sh verify` | 重新执行集群健康检查 |
| `sudo bash scripts/00-install.sh status` | 查看部署机本地阶段标记 |

`prepare` 是独立的预处理阶段。请先执行 `sudo bash scripts/00-install.sh prepare`，再按需执行 `etcd`、`control-plane`、`workers` 等组件阶段。组件阶段不会隐式下载资源、安装依赖或生成证书；若本地证书或节点证书分发缺失，会明确提示先执行 `prepare` 并退出。`all` 会显式按顺序执行预处理、Harbor、etcd quorum 验证、控制平面启动、全部 Master API `/readyz` 门槛、Worker、Calico、CoreDNS、NodeLocal DNSCache 和最终验收。NodeLocal DNSCache 在 kubelet 配置中使用 `NODE_LOCAL_DNS_IP`（默认 `169.254.20.10`），并在所有节点以 DaemonSet 运行。单独执行 `etcd` 前必须先完成 `harbor`；单独执行 `workers` 或 `calico` 前，必须已有可用控制平面 API。

## 3. 幂等标记和断点续装

### 本地阶段标记

部署机状态目录：

- `/var/lib/kubernetes-binary-ha-controller/steps/*.done`
- `/var/lib/kubernetes-binary-ha-controller/steps/*.failed`
- `/var/log/kubernetes-binary-ha-install/`

离线 Release 下载和节点配置渲染均先写入同一文件系统的临时目录，全部校验/渲染成功后再切换目录，失败不会先删除上一份可用资源。每个本地阶段成功后写入 `.done`，失败写入 `.failed`。完成标记记录脚本、集群参数、Release 版本、CFSSL CSR/profile 和 manifests 的指纹；Harbor 阶段还会纳入 Harbor 离线安装器、镜像归档、镜像引用清单及 Harbor SHA256 清单。相关脚本、配置或镜像制品发生变化时，旧标记不再视为有效。

### 节点阶段标记

每台节点独立保存：

- `/var/lib/kubernetes-binary-ha/steps/*.done`
- `/var/lib/kubernetes-binary-ha/steps/*.failed`
- `/var/log/kubernetes-binary-ha/`

`scripts/23-batch-step.sh` 并行分发任务，远端由 `scripts/22-node-step.sh` 加锁执行。只有服务脚本返回成功后才写入完成标记。远端标记还会核对部署脚本、节点配置、证书、运行时配置、systemd 单元和离线资源清单指纹，并检查对应服务是否仍处于健康状态。

### 失败后如何继续

1. 查看入口输出的失败阶段和日志路径。
2. 登录失败节点，查看 `/var/log/kubernetes-binary-ha/` 对应日志及 `journalctl -u 服务名`。
3. 修复网络、镜像、证书、磁盘或服务配置问题。
4. 再次运行同一条命令：

~~~bash
sudo bash scripts/00-install.sh all
~~~

已经成功且指纹未变化、健康检查通过的节点会显示 `[SKIP]`；失败节点或配置变化的阶段会重新执行。无需清空所有状态，也不要删除 etcd 数据目录来“重试”。

## 4. 防止重复初始化和数据破坏

- etcd 已有 `/var/lib/etcd/member` 且服务 active 时，启动脚本视为已初始化并跳过；已有数据但服务停止时会拒绝重新初始化，要求人工检查。
- CFSSL CA/叶子证书已存在且证书/私钥成对时复用；只有一半文件时拒绝覆盖。ServiceAccount JWT 密钥对同样复用，避免重跑改变签名密钥。
- Calico、CoreDNS 使用 Helm upgrade/install；NodeLocal DNSCache 使用 apply 和 DaemonSet rollout 检查，可重复提交期望配置；跳过阶段时会复查节点覆盖率和 Ready 数量。最终 verify 会运行临时跨节点验收 Pod，强制从 Harbor 拉取 BusyBox 镜像，验证 Pod 的 NodeLocal DNS、集群 DNS、Pod IP 和 ClusterIP Service 连通性，并在结束时删除验收命名空间。
- 容器运行时和 systemd 安装脚本可重复执行；远端包装器在指纹一致且健康检查通过时不再重复执行。 若 etcd、Kubernetes 或运行时服务已运行，安装脚本会先比对当前二进制版本，发现版本不一致就拒绝原地覆盖。scripts/11-upgrade-node.sh 当前明确禁用，避免将不完整的单节点替换流程误当作滚动升级方案。
- 本地入口和每个远端节点均有 `flock` 锁，避免同一控制端或节点同时执行两个安装任务。

> 证书 SAN、CA 或集群参数发生变化时，不会自动覆盖既有 CA/证书。请按证书轮换流程处理，不要为了让标记变绿而删除 PKI 或 etcd 数据。

## 5. 日志和问题定位

~~~bash
# 查看本地阶段状态
sudo bash scripts/00-install.sh status

# 查看最近一次入口日志
sudo ls -lt /var/log/kubernetes-binary-ha-install/

# 查看某一节点的服务安装日志
ssh root@master-01 'ls -lt /var/log/kubernetes-binary-ha/'

# 检查远端阶段标记
ssh root@master-01 'ls -l /var/lib/kubernetes-binary-ha/steps/'
~~~

如需重新执行健康检查（包含 Harbor 镜像拉取、Pod DNS、跨节点 Pod IP 和 Service 流量验收）：

~~~bash
sudo bash scripts/00-install.sh verify
~~~

不建议提供清空所有标记的通用 reset 命令：它容易导致 etcd、CA 或运行中的服务被误初始化。若确需重新安装某个组件，应先备份状态和数据，再针对该组件制定恢复步骤。
