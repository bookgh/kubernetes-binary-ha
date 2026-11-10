# Kubernetes v1.37.2 二进制高可用集群部署项目

基于 **Rocky Linux 9 / x86_64（amd64）**，使用 Kubernetes 官方二进制文件部署三 Master、三 Worker 集群，不使用 kubeadm。当前 API 入口采用 **Master 本机回环访问 + Worker 本机 NGINX TCP 代理**，暂不部署外部负载均衡器、Keepalived 或 VIP。

> **生产提示：** 本仓库仍在持续完善。生产部署前必须在 Rocky Linux 9 六节点预演环境完成证书、镜像、网络、故障切换、备份恢复和升级验证。

## 一、架构与访问路径

| 节点 | 组件 | API 访问方式 |
|---|---|---|
| master-01～03 | kube-apiserver、controller-manager、scheduler、etcd | 本机组件访问 `https://127.0.0.1:6443` |
| worker-01～03 | kubelet、kube-proxy、NGINX stream | 本机访问 `https://127.0.0.1:6443`，由 NGINX 转发到三台 Master |
| 运维终端 | kubectl、管理员 kubeconfig | `https://${API_DNS}:6443`；当前无 LB，DNS 应指向可达 Master |

Worker 本机 NGINX 只做 TCP 转发，不解密 TLS。Master 上的 kube-apiserver 必须监听 `0.0.0.0:6443`，以便 Worker 通过 Master 节点 IP 访问。

## 二、目录说明

- `config/`：集群参数、组件版本、kubelet/kube-proxy 和 NGINX 配置模板。
- `scripts/`：系统预检、离线资源准备、安装、证书、启动、验证和升级脚本。
- `scripts/ci/`：GitHub Actions 调用的构建与发布脚本，是离线资源构建流程的唯一实现入口。
- `systemd/`：containerd、etcd、Kubernetes 组件及 Worker NGINX 服务单元。
- `manifests/`：RBAC、Calico 和 CoreDNS 清单模板。
- `nginx/Dockerfile`：从源码编译带 `stream` 模块的 NGINX。
- `docs/`：部署手册、参数、网络端口、离线镜像和生产验收文档。

## 三、部署前准备

1. 准备六台 Rocky Linux 9 x86_64 主机，主机名为 `master-01`～`master-03`、`worker-01`～`worker-03`。
2. 配置固定 IP、DNS、NTP、路由、MTU、磁盘和防火墙策略。
3. 确认 `POD_CIDR`、`SERVICE_CIDR` 与现有网络无重叠。
4. 将 `config/cluster.env.example` 复制为 `config/cluster.env`，填写真实 IP、API DNS、版本和镜像仓库。
5. 对照 `docs/PARAMETER-REFERENCE.md` 复核参数。

## 四、通过 GitHub Actions 构建离线 Release

NGINX 不再由运维人员在暂存机手动构建。所有二进制资源（包括 NGINX）由 GitHub Actions 统一构建、校验并发布。

### Issue 触发

1. 在仓库创建 Issue，标题或正文填写 Kubernetes 版本，例如 `v1.37.2`。
2. 为 Issue 添加 `build-offline` 标签。
3. Actions 自动调用 `scripts/ci/build-offline-release.sh`。
4. 脚本读取 `config/release-versions.env` 中的组件版本，统一下载 Kubernetes、etcd、containerd、runc、CNI、crictl、Calico 清单。
5. 脚本通过 `nginx/Dockerfile` 在 Rocky Linux 9 容器构建环境源码编译 NGINX stream 二进制。
6. 发布 `k8s-vX.Y.Z` Release，包含离线资源包、NGINX 独立二进制和各自的 SHA256 文件。

### 手动触发

进入 **Actions → Issue 驱动的离线资源包构建与 Release 发布 → Run workflow**，输入版本号即可。

### 版本维护原则

- Kubernetes 版本由 Issue 或手动输入提供。
- etcd、containerd、runc、CNI、crictl、Calico、CoreDNS 和 NGINX 版本只在 `config/release-versions.env` 中维护。
- 下载地址、校验、构建和 Release 上传只在 `scripts/ci/build-offline-release.sh` 中维护。
- Workflow YAML 只负责事件过滤、checkout 和调用仓库脚本，不重复维护 URL、版本矩阵或构建命令。
- 修改构建流程时优先修改脚本和配置，不要在 Workflow 中复制构建实现。

> 当前离线包不包含完整 Rocky Linux RPM 仓库快照和全部容器镜像。Calico、CoreDNS、pause 及业务镜像需要按目标版本单独同步到私有仓库或制作 OCI 归档。

## 五、集中式部署与配置分发

项目采用“部署端生成配置、批量分发、节点端安装执行”的模式。先在部署机完成 `config/cluster.env`，配置节点 IP、`RUNTIME_TYPE` 与 `KUBE_PROXY_MODE`，然后执行：

```bash
sudo bash scripts/14-render-node-configs.sh
sudo bash scripts/15-distribute-node-configs.sh
```

第一个脚本在本地 `generated/<node>/` 生成每台节点的 kubelet、kube-proxy 和运行时配置；第二个脚本通过 SSH/SCP 批量分发。请先检查生成目录，再执行分发。节点端不再临时拼接这些配置文件。

### 容器运行时选择

- `RUNTIME_TYPE="containerd"`：使用 containerd CRI socket。
- `RUNTIME_TYPE="docker"`：使用 Docker Engine + cri-dockerd，kubelet 连接 cri-dockerd 的 CRI socket。Docker Engine 本身不是 Kubernetes CRI 接口；Docker 模式需设置 `DOCKER_VERSION` 和 `CRI_DOCKERD_VERSION`，再运行离线资源准备脚本。

### kube-proxy 模式选择

- `KUBE_PROXY_MODE="ipvs"`：加载 IPVS 内核模块并安装 `ipvsadm`。
- `KUBE_PROXY_MODE="nftables"`：要求 Linux kernel >= 5.13，并安装 `nftables`；配置会显式写入 `mode: nftables`。

模式应在 kube-proxy 首次启动前确定。集群运行后切换代理模式属于网络变更，应安排维护窗口并验证 ClusterIP、NodePort 和跨节点流量。

## 六、节点部署顺序

1. 六台节点分别运行 `scripts/00-preflight.sh`。
2. 从对应 Release 下载离线资源包并解压到项目的 `offline/` 目录。
3. 六台节点运行 `scripts/02-install-runtime.sh`。
4. 在可信任 PKI 工作站运行 `scripts/03-generate-pki.sh`，检查证书并按最小权限分发。
5. 运行 `scripts/04-make-kubeconfigs.sh`，仅向对应节点分发 kubelet kubeconfig。
6. 六台节点运行 `scripts/06-install-systemd.sh`。
7. 三台 Master 配置并启动 etcd：`scripts/07-bootstrap-etcd.sh`。
8. 三台 Master 启动控制平面：`scripts/08-start-control-plane.sh`。
9. 每台 Worker 先运行 `scripts/13-install-nginx-proxy.sh` 安装 Release 中的 NGINX，再运行 `scripts/09-start-worker.sh`。
10. 按部署手册部署 Calico、CoreDNS、RBAC 并执行网络验收。
11. 在具备管理员凭据的节点运行 `scripts/10-verify.sh`。

`scripts/12-build-nginx-binary.sh` 已保留为兼容提示入口，不再执行本地构建。NGINX 必须来自对应 Kubernetes Release。

## 七、NGINX Release 下载与安装

NGINX 由 Actions 自动构建并作为独立 Release 资产发布。每台 Worker 只需准备项目脚本和 `config/cluster.env`，确保能访问 GitHub Release：

```bash
sudo bash scripts/13-install-nginx-proxy.sh
sudo systemctl status nginx-k8s-api
curl --cacert /etc/kubernetes/pki/k8s-ca.crt https://127.0.0.1:6443/readyz
```

安装脚本根据 `K8S_VERSION` 和 `NGINX_VERSION` 计算 Release tag 和资产名称，下载 NGINX 及 SHA256 文件，校验成功后才安装。Worker 不需要 Docker/Podman，也不需要在节点上编译源码。

## 八、常用检查

```bash
bash -n scripts/*.sh scripts/ci/*.sh
systemctl status containerd etcd kube-apiserver kubelet nginx-k8s-api
curl --cacert /etc/kubernetes/pki/k8s-ca.crt https://127.0.0.1:6443/readyz
kubectl get nodes -o wide
kubectl get pods -A -o wide
```

## 九、安全注意事项

- CA 私钥不得分发到集群节点；节点证书按最小权限分发。
- 不要通过关闭 SELinux 或防火墙规避配置问题。
- etcd 必须有异机备份，禁止同时停止两个成员。
- 当前无外部 LB，管理员 `API_DNS` 不是高可用入口；Master 故障时需调整 DNS 或 kubeconfig。
- 生产使用前必须完成六节点预演、故障切换、备份恢复和升级演练。
