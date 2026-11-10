# Kubernetes v1.37.2 二进制高可用集群部署项目

基于 **Rocky Linux 9 / x86_64（amd64）**，使用 Kubernetes 官方二进制文件部署三 Master、三 Worker 集群，不使用 kubeadm。当前 API 入口采用 **Master 本机回环访问 + Worker 本机 NGINX TCP 代理**，暂不部署外部负载均衡器、Keepalived 或 VIP。

> **生产提示：** 本仓库仍在持续完善。生产部署前必须在 Rocky Linux 9 六节点预演环境完成证书、镜像、网络、故障切换、备份恢复和升级验证，不要将未经端到端验证的模板直接投入生产。

## 一、架构与访问路径

| 节点 | 组件 | API 访问方式 |
|---|---|---|
| master-01～03 | kube-apiserver、controller-manager、scheduler、etcd | 本机组件访问 `https://127.0.0.1:6443` |
| worker-01～03 | kubelet、kube-proxy、NGINX stream | 本机访问 `https://127.0.0.1:6443`，由 NGINX 转发到三台 Master |
| 运维终端 | kubectl、管理员 kubeconfig | `https://${API_DNS}:6443`；当前无 LB，DNS 应指向可达 Master |

Worker 本机 NGINX 只做 TCP 转发，不解密 TLS：

```text
Worker kubelet / kube-proxy
        |
        v
127.0.0.1:6443（本机 NGINX stream）
        +---- master-01:6443
        +---- master-02:6443
        +---- master-03:6443
```

Master 上的 kube-apiserver 必须监听 `0.0.0.0:6443`，以便 Worker 通过 Master 节点 IP 访问；Master 本机客户端仍访问本机 API。API Server 证书 SAN 必须包含 `127.0.0.1`、全部 Master IP、`API_DNS`、Kubernetes Service DNS 和 Service IP。

## 二、目录说明

- `config/`：集群参数、kubelet/kube-proxy 和 NGINX 配置模板。
- `scripts/`：系统预检、离线资源准备、安装、证书、启动、验证和升级脚本。
- `systemd/`：containerd、etcd、Kubernetes 组件及 Worker NGINX 服务单元。
- `manifests/`：RBAC、Calico 和 CoreDNS 清单模板。
- `nginx/Dockerfile`：从源码编译带 `stream` 模块的 NGINX。
- `docs/`：部署手册、参数、网络端口、离线镜像和生产验收文档。

## 三、部署前准备

1. 准备六台 Rocky Linux 9 x86_64 主机，主机名为 `master-01`～`master-03`、`worker-01`～`worker-03`。
2. 配置固定 IP、DNS、NTP、路由、MTU、磁盘和防火墙策略。
3. 确认 `POD_CIDR`、`SERVICE_CIDR` 与现有 LAN/VPN/云网络无重叠。
4. 将 `config/cluster.env.example` 复制为 `config/cluster.env`，填写真实 IP、API DNS、版本和镜像仓库。
5. 对照 `docs/PARAMETER-REFERENCE.md` 复核参数。

## 四、离线资源准备

在可联网的 Rocky Linux 9 amd64 暂存机上运行：

```bash
cp config/cluster.env.example config/cluster.env
vi config/cluster.env
sudo bash scripts/01-prepare-offline.sh
sudo bash scripts/12-build-nginx-binary.sh
```

脚本会准备 Kubernetes、etcd、containerd、runc、CNI、crictl、Calico 清单和 RPM 依赖。NGINX 通过 Dockerfile 从源码构建，最终仅导出二进制文件到 `offline/bin/nginx`。将项目和 `offline/` 目录安全传输到隔离环境。

**注意：** 二进制包不等于完整离线集群。Calico、CoreDNS、pause 及其他工作负载容器镜像必须按目标版本单独拉取、校验并导入私有仓库或 OCI 归档，详见 `docs/OFFLINE-IMAGES.md`。

## 五、节点部署顺序

1. 六台节点分别运行 `scripts/00-preflight.sh`。
2. 传输 `offline/`，六台节点运行 `scripts/02-install-runtime.sh`。
3. 在可信任 PKI 工作站运行 `scripts/03-generate-pki.sh`，检查证书并按最小权限分发。
4. 运行 `scripts/04-make-kubeconfigs.sh`，仅向对应节点分发 kubelet kubeconfig。
5. 六台节点运行 `scripts/06-install-systemd.sh`。
6. 三台 Master 配置并启动 etcd：`scripts/07-bootstrap-etcd.sh`。
7. 三台 Master 启动控制平面：`scripts/08-start-control-plane.sh`。
8. 每台 Worker 安装本地代理：`scripts/13-install-nginx-proxy.sh`，再运行 `scripts/09-start-worker.sh`。
9. 按部署手册部署 Calico、CoreDNS、RBAC 并执行网络验收。
10. 在具备管理员凭据的节点运行 `scripts/10-verify.sh`。

`scripts/05-install-lb.sh` 为历史兼容入口，当前方案不使用外置 LB/VIP，不应执行。

## 六、NGINX 源码构建与安装

NGINX 在联网 Rocky Linux 9 amd64 构建机通过 Docker/Podman 构建，启用 stream 模块。Worker 不需要安装 Docker/Podman：

```bash
sudo bash scripts/12-build-nginx-binary.sh  # 联网构建机
sudo bash scripts/13-install-nginx-proxy.sh # 每台 Worker
```

服务监听 `127.0.0.1:${API_PORT}`，以 TCP 方式转发到三台 Master。NGINX 不终止 TLS。

## 七、常用检查

```bash
bash -n scripts/*.sh
systemctl status containerd etcd kube-apiserver kubelet nginx-k8s-api
curl --cacert /etc/kubernetes/pki/k8s-ca.crt https://127.0.0.1:6443/readyz
kubectl get nodes -o wide
kubectl get pods -A -o wide
```

## 八、自动构建离线 Release

工作流位于 `.github/workflows/issue-offline-release.yml`，支持手动 `workflow_dispatch` 输入 Kubernetes 版本，也支持 Issue 触发（需添加 `build-offline` 标签，且标题或正文包含 `vX.Y.Z`）。成功后创建不可覆盖的 `k8s-vX.Y.Z` Release，并上传离线资源包和 SHA256 文件。

工作流需要仓库 Actions 权限允许 `GITHUB_TOKEN` 写入 Releases。该工作流生成的是离线二进制资源包，不包含全部容器镜像和 Rocky Linux RPM 仓库快照。

## 九、安全注意事项

- CA 私钥不得分发到集群节点；节点证书按最小权限分发。
- 不要通过关闭 SELinux 或防火墙规避配置问题。
- etcd 必须有异机备份，禁止同时停止两个成员。
- 当前无外部 LB，管理员 `API_DNS` 不是高可用入口；Master 故障时需调整 DNS 或 kubeconfig。
- 生产使用前必须完成六节点预演、故障切换、备份恢复和升级演练。
