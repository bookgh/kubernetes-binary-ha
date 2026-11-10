# Kubernetes 集群分阶段部署手册

本文以 Rocky Linux 9、amd64、三 Master + 三 Worker 为基线。部署前先完成网络、安全和离线资源评审。

## 阶段 0：站点准备

- 核对六台主机名、静态 IP、DNS、MTU、路由、NTP、磁盘和时间同步。
- 确认 Pod CIDR/Service CIDR 不与现有网络重叠。
- 确认 Worker 到所有 Master 的 TCP/6443 可达；Master 间 TCP/2379、2380 可达。
- 在 GitHub Actions 中创建离线 Release；确认归档、独立 NGINX 资产及 SHA256 均已上传。
- 将项目脚本和配置传入隔离环境；离线资源包按 Release 校验和验证后解压。
- 单独准备 pause、Calico、CoreDNS 和业务容器镜像。

## 阶段 1：部署端生成配置与批量分发

在部署机配置 `config/cluster.env`，确认六个节点 IP、`RUNTIME_TYPE` 和 `KUBE_PROXY_MODE`。生成所有节点配置并批量分发：

```bash
sudo bash scripts/14-render-node-configs.sh
sudo bash scripts/15-distribute-node-configs.sh
```

配置先写入本地 `generated/<node>/`，确认内容无误后再分发。远程节点不使用 SSH heredoc 临时生成配置。

## 阶段 2：操作系统与运行时

1. 六台节点运行 `scripts/00-preflight.sh`，检查系统、所选运行时和代理模式要求。
2. 六台节点运行 `scripts/02-install-runtime.sh`。containerd 模式安装 containerd；Docker 模式安装 Docker Engine + cri-dockerd。
3. 检查所选运行时、runc、CNI 插件和 `crictl info`；Docker 模式检查 `docker.service` 与 `cri-docker.socket`。
4. 确认 `SystemdCgroup=true`、CRI 插件启用、pause 镜像可离线获取。

## 阶段 3：PKI 与 kubeconfig

1. 在可信任 PKI 工作站运行 `scripts/03-generate-pki.sh`。
2. 检查证书 CN、O、SAN、EKU 和有效期。
3. 运行 `scripts/04-make-kubeconfigs.sh`。
4. CA 私钥保持离线；按节点分发专属证书和 kubeconfig。

## 阶段 4：Worker NGINX 安装

每台 Worker 配置 `config/cluster.env`，确保 `K8S_VERSION` 与已发布 Release 一致，`NGINX_VERSION` 与 `config/release-versions.env` 一致。Worker 需要能访问 GitHub Release 下载资产。

```bash
sudo bash scripts/13-install-nginx-proxy.sh
systemctl status nginx-k8s-api
curl --cacert /etc/kubernetes/pki/k8s-ca.crt https://127.0.0.1:6443/readyz
```

安装脚本下载独立 NGINX 二进制及 SHA256 文件，校验通过才安装。Worker 不运行 Docker/Podman，也不构建 NGINX。若集群完全隔离 GitHub，可在有网络的管理机下载 Release 资产并通过可信介质分发；仍应在 Worker 执行同样的校验和安装流程。

## 阶段 5：etcd 与控制平面

1. 六台节点运行 `scripts/06-install-systemd.sh`。
2. 三台 Master 配置并启动 etcd：`scripts/07-bootstrap-etcd.sh`。
3. 验证 etcd endpoint health、成员列表和 quorum。
4. 三台 Master 启动控制平面：`scripts/08-start-control-plane.sh`。
5. 分别检查 API Server `/livez` 和 `/readyz`。

## 阶段 6：Worker

1. 分发 Worker 专属 kubelet 证书和 kubeconfig。
2. 先安装并验证 NGINX 本机 API 代理。
3. 运行 `scripts/09-start-worker.sh`。
4. 检查 Node 注册和 Ready 状态。

## 阶段 7：CNI、DNS 与验收

1. 应用 Calico CRD、Operator 和自定义资源。
2. 确认全部镜像均已导入内网仓库或节点缓存。
3. 检查 Calico VXLAN、跨节点 Pod 通信。
4. 部署 CoreDNS 并验证集群域名解析。
5. 逐台停止 API Server，验证 Worker NGINX 能切换到其他健康 Master。
6. 完成 etcd 快照异机保存和恢复演练。

**警告：** `initial-cluster-state=new` 仅用于首次创建 etcd 集群，禁止通过删除现有数据目录重建成员。
