# 从零部署到集群验收（Rocky Linux 9 / amd64）

本文是本仓库当前实现的端到端部署流程，目标示例拓扑为 3 Master + 3 Worker；实际 Master 数量由 `MASTER_COUNT` 决定，Kubernetes v1.37.2。部署端负责下载离线 Release、生成 PKI/kubeconfig/节点配置、批量分发和执行。节点端不需要安装 Docker 来构建 NGINX；运行时按 containerd 或 Docker + cri-dockerd 选择。

## 快速一键安装

当本文列出的系统、网络、镜像仓库和 Release 前置条件全部满足后，可直接运行统一入口完成全流程：

~~~bash
sudo bash scripts/00-install.sh all
~~~

`all` 会显式先执行预处理，再部署 Harbor 并导入基础镜像，然后依序部署 etcd、控制平面、Worker 和集群组件。若选择分阶段安装，必须先执行 `sudo bash scripts/00-install.sh prepare`；随后 `etcd`、`workers` 等组件命令只做前置证书和依赖检查，不会自动生成证书或安装依赖；启动控制平面后，入口会逐个检查全部 Master API `/readyz`，全部成功才允许启动 Worker。缺少证书时会提示并退出。入口记录本地和各节点的完成/失败标记，失败后修复再运行同一命令即可断点续装。详见 [docs/UNIFIED-INSTALLER.md](UNIFIED-INSTALLER.md)。



> **拓扑变更边界：** `MASTER_COUNT` 动态决定新集群初始化时的 Master/Worker 分组。修改配置后必须重新执行 `prepare`，重新渲染并分发证书和节点配置。此配置不是运行中 etcd 集群的扩缩容接口；已有集群不得只修改 `MASTER_COUNT` 后重新执行 `etcd`。运行中成员增删必须单独使用 etcd member add/remove 流程，更新证书、控制平面和代理配置，并先备份、逐步验收。证书脚本会复用既有 CA/叶子证书并拒绝覆盖不完整文件；当拓扑变化导致 API Server SAN 不再匹配时，必须按证书轮换流程处理，不能删除 CA 或 etcd 数据目录来绕过检查。

> **重要边界：** 本仓库 Release 包含 Harbor 官方离线安装器，以及 CoreDNS、pause、Calico、NodeLocal DNSCache 等基础 OCI 镜像归档。业务镜像和未列入归档的 Operator/CSI/监控镜像仍需单独纳入。Harbor 默认通过 HTTP/80 + nip.io 访问，运行时配置为 HTTP insecure registry；HTTP 不存在 TLS CA 证书信任。当前 API 入口没有外部 LB/VIP，管理端 API_DNS 指向单台 Master，不具备入口层 HA。

## 0. 部署拓扑与网络前置条件

- `MASTER_COUNT` 台 Master：etcd、kube-apiserver、kube-controller-manager、kube-scheduler。
- 其余至少 1 台 Worker：kubelet、kube-proxy、NGINX TCP/TLS 透传代理。
- Rocky Linux 9 x86_64，所有 Master 主机名使用 `master-*`，其余 Worker 使用 `worker-*`，静态 IP。
- 所有节点时间同步；部署机通过 `SSH_USER`、`SSH_PASSWORD`、`SSH_PORT` 配置 SSH 公钥访问。非 root 账号必须具备免密 sudo。
- Master 间 TCP 2379/2380；Worker 到全部 Master TCP 6443；节点间 VXLAN UDP 4789；节点间 TCP 179 仅在启用 Calico BGP 时需要。另按 [docs/PORTS.md](PORTS.md) 配置其余端口。
- POD_CIDR、SERVICE_CIDR 不得与机房、VPN、VPC 网络冲突。
- 所有节点的 MTU、防火墙、DNS、路由、磁盘和 SELinux 策略先行确认，不建议通过关闭防火墙/SELinux解决问题。

## 1. 准备部署机与版本参数

在 Rocky Linux 9 amd64 部署机 clone 仓库：

~~~bash
git clone https://github.com/bookgh/kubernetes-binary-ha.git
cd kubernetes-binary-ha
cp config/cluster.env.example config/cluster.env
vi config/cluster.env
~~~

至少确认以下参数：

- 在 `config/cluster.env` 中维护 `NODE_NAMES` 和 `NODE_IPS` 两个数组，顺序必须先列出全部 Master，再列出全部 Worker；`MASTER_COUNT` 设置为 Master 数量，前 `MASTER_COUNT` 项自动成为 Master，其余自动成为 Worker。至少需要一个 Master 和一个 Worker；单 Master 不具备成员故障容忍能力，生产环境建议使用奇数 Master（3/5/7），偶数成员会产生 etcd quorum 风险并触发警告。节点名称和 IP 按索引一一对应，脚本会在 `lib.sh` 中派生角色数组并校验数量、重复项、主机名角色及 IPv4 格式。
- 修改节点清单后，可先运行 `bash scripts/tests/test-dynamic-inventory.sh`，验证 1+1、2+2、3+3、5+2 拓扑的角色派生及非法 Master 数量拒绝逻辑。
- API_DNS 必须解析到可达 Master IP。当前没有 VIP/LB，DNS 解析不提供高可用。
- RUNTIME_TYPE=containerd 或 RUNTIME_TYPE=docker。Docker 模式必须使用 cri-dockerd。
- KUBE_PROXY_MODE=nftables 或 ipvs。Kubernetes 1.37 新部署推荐 nftables；IPVS 已弃用，使用前应确认内核模块和 kube-proxy 支持。
- `HARBOR_NODE_IP` 可以是集群节点，也可以是独立 Rocky Linux 9 Harbor 主机；`HARBOR_HOST` 使用 `harbor.<HARBOR_NODE_IP>.nip.io`，`HARBOR_URL` 使用 `http://`。
- `PRIVATE_REGISTRY` 默认设置为 `${HARBOR_HOST}/library`；`PAUSE_IMAGE`、`NODE_LOCAL_DNS_IMAGE` 和 `NETWORK_TEST_IMAGE` 指向 Harbor 中对应镜像。`NODE_LOCAL_DNS_IP` 默认 `169.254.20.10`，必须确认该链路本地地址未被主机网络占用。CoreDNS 和 Calico 镜像由各自 Chart/Operator 的版本清单决定，不再单独配置镜像 tag。
- `SSH_USER`、`SSH_PASSWORD`、`SSH_PORT` 控制公钥分发；非 root SSH 账号必须具备免密 sudo。
- KUBERNETES_SERVICE_IP 必须是 SERVICE_CIDR 中 Kubernetes API Service 使用的 IP，默认 10.96.0.1，并进入 apiserver 证书 SAN。

版本清单集中在 config/release-versions.env，集群参数集中在 config/cluster.env。修改版本后必须重新构建一个新的、不可覆盖的 Release tag。

## 2. 构建并发布离线 Release

GitHub Actions 的离线 Release workflow 使用 scripts/ci/build-offline-release.sh 构建。为目标 Kubernetes 版本触发 workflow，构建完成后应在 GitHub Releases 中看到 k8s-v1.37.2-r8（tag 由 RELEASE_REVISION 控制；实际部署以 Release 页面和配置文件为准）。

离线包归档内含：
- Kubernetes server/client 二进制、etcd、containerd、runc、CNI plugins、crictl；
- CFSSL 和 cfssljson、Helm、Calicoctl；
- Docker Engine 静态二进制、cri-dockerd、Docker Compose CLI plugin；
- NGINX stream 二进制及构建信息（安装时从 offline/bin/nginx 校验后本地安装，不需要 Worker 访问 GitHub）；
- Rocky Linux 9 amd64 RPM 及依赖、Calico CRD/Operator Helm Charts、CoreDNS Helm Chart、渲染后的 manifests、SHA256SUMS 和 ARTIFACTS.txt。

下载前检查 Release 资产和 SHA256。Release tag 不可覆盖；变更组件版本应发布新 tag。离线包包含 Harbor 离线安装器和项目基础镜像归档。

## 3. 准备离线资源并安装部署端 CLI

~~~bash
sudo bash scripts/01-prepare-offline.sh
# 按离线 RPM 根包清单安装部署机必需 RPM，并安装 Helm/CFSSL 等 CLI
sudo bash scripts/00-install.sh download
~~~

01 会下载 Release 归档和 SHA256，校验外层及内部 SHA256SUMS，在临时目录完成全部资产校验后再原子切换仓库根目录 offline/；下载/校验失败不会先删除旧离线包。RPM 包来自 Release，不再要求部署机访问 Rocky Linux 软件源。部署机本地安装 Helm、Calicoctl、crictl、CFSSL 和 cfssljson，便于后续管理和验收。离线资源目录同时包含 Harbor 安装器与 Kubernetes 镜像归档。

如果部署机与实际执行下载的暂存机分离，将完整 offline/ 目录安全复制到部署机项目根目录，并再次执行：

~~~bash
(cd offline && sha256sum -c SHA256SUMS)
~~~

## 4. 配置部署机到节点的 SSH 公钥免密登录

**此步骤必须在证书/配置分发之前执行**，因为后续 `15-distribute-node-configs.sh`、批量执行脚本和统一安装入口都依赖 SSH 公钥登录。

先在 `config/cluster.env` 检查以下配置：

~~~bash
export SSH_USER="root"
export SSH_PASSWORD="首次分发公钥时使用的登录密码"
export SSH_PORT="22"
~~~

- `SSH_USER`：远程节点登录账号，默认 root。使用普通账号时，该账号必须能免密执行 sudo。
- `SSH_PASSWORD`：仅用于首次通过 `sshpass` 调用 `ssh-copy-id` 分发公钥；若留空，脚本会由 `ssh-copy-id` 交互式询问远程密码。不要把真实密码提交到 Git。
- `SSH_PORT`：所有目标节点 SSH 端口，必须与 sshd 实际监听端口一致。
- 部署机需安装 `ssh`、`ssh-keygen`、`ssh-copy-id`；配置了非空密码时还需要 `sshpass`。离线 RPM 根包清单会提供所需工具。

确认节点 IP、账号、端口无误后，在部署机以 root 执行：

~~~bash
sudo bash scripts/05-configure-ssh.sh
~~~

脚本会在部署机的 `/root/.ssh/` 下生成或复用专用 Ed25519 密钥 `kubernetes-binary-ha_ed25519`，将公钥分发到全部 Master、Worker；若 Harbor 位于独立主机，也会配置 Harbor 节点。私钥只保留在部署机。首次连接会采用 `StrictHostKeyChecking=accept-new` 记录主机密钥；**首次连接前应通过可信渠道核对每台主机的 SSH host key 指纹**，不要在未核验身份的情况下盲目接受。

完成后脚本会逐台使用 BatchMode 验证公钥登录。也可手工抽查：

~~~bash
sudo ssh -p 22 -o BatchMode=yes root@192.168.10.21 true
sudo ssh -p 22 -o BatchMode=yes root@192.168.10.41 true
~~~

将示例 IP、账号和端口替换为实际配置。若验证失败，检查账号密码、sshd 端口、防火墙、远端 `~/.ssh/authorized_keys` 权限以及部署机私钥权限；修复后重新执行脚本即可。SSH 私钥和密码不得复制到集群节点或提交到仓库。

统一安装方式无需手工单独执行该脚本：`sudo bash scripts/00-install.sh prepare` 会自动执行 SSH 公钥配置；也可单独运行 `sudo bash scripts/00-install.sh ssh`。
## 6. 本地生成 CFSSL PKI、kubeconfig 和节点配置

先生成证书：

~~~bash
sudo bash scripts/03-generate-pki.sh
~~~

证书配置全部位于 config/cfssl/：
- CA CSR：Kubernetes、etcd、front-proxy、kubelet signer；
- ca-config.json：server/client/peer profile 和有效期；
- csr/*.json：apiserver、etcd server/peer、kubelet、admin、controller-manager、scheduler、kube-proxy 等服务 CSR 模板。

所有 X.509 证书通过 CFSSL 签发。节点证书和 etcd 成员证书的命令显式使用 -hostname=节点主机名,节点内网IP（CFSSL 根据内容自动识别 DNS 与 IP SAN，不要添加 DNS: 或 IP: 前缀），API Server 证书额外包含 API DNS、全部 Master IP、回环地址和 Kubernetes Service DNS/IP。脚本保留 OpenSSL 仅用于生成 ServiceAccount JWT RSA key pair（sa.key/sa.pub），它不是 X.509 证书。

生成 kubeconfig 和每节点本地配置：

~~~bash
sudo bash scripts/04-make-kubeconfigs.sh
sudo bash scripts/14-render-node-configs.sh
~~~

检查 pki/、kubeconfigs/ 和 generated/。不要把 pki/*.key、管理员 kubeconfig 或生成目录提交到 Git。

## 6. 分发到全部节点

部署机确认本节的 `05-configure-ssh.sh` 已成功执行，全部节点及独立 Harbor 节点均可 BatchMode 公钥登录，且 SSH host key 已核验：

~~~bash
sudo bash scripts/15-distribute-node-configs.sh
~~~

脚本通过 SCP/rsync 分发仓库、Release 离线包、每节点 kubelet/kube-proxy 配置、运行时配置、模块/sysctl 配置和节点专属凭据。根 CA 私钥和管理员 kubeconfig 不分发；etcd CA 私钥保留在部署机。检查各节点文件权限和目录：

~~~bash
ssh root@master-01 'ls -l /etc/kubernetes/pki /etc/etcd/pki'
ssh root@worker-01 'ls -l /etc/kubernetes/pki /etc/kubernetes'
~~~

## 7. 批量预检、安装运行时和 systemd

~~~bash
sudo bash scripts/16-batch-exec.sh all 00-preflight.sh --parallel
sudo bash scripts/16-batch-exec.sh all 02-install-runtime.sh --parallel
sudo bash scripts/16-batch-exec.sh all 06-install-systemd.sh --parallel
~~~

检查各节点：

~~~bash
systemctl is-active containerd || systemctl is-active docker
crictl info
ls -l /opt/cni/bin
lsmod | egrep 'overlay|br_netfilter|ip_vs|nf_tables'
sysctl net.ipv4.ip_forward
~~~

- containerd 模式：containerd、ctr、shim、runc、CNI 和 crictl 安装到节点；CRI endpoint 为 /run/containerd/containerd.sock。
- Docker 模式：Docker Engine + cri-dockerd + Compose plugin；kubelet 连接 /run/cri-dockerd.sock，不能将 Docker Engine socket 当作 CRI endpoint。
- IPVS 模式检查 ipvsadm -Ln；nftables 模式检查 nft list ruleset。不要在集群运行后随意切换模式。

## 8. 部署 Harbor 并导入镜像，然后启动 etcd 集群

在第 6 节全部节点预处理、运行时安装和配置分发完成后，先部署 Harbor：

~~~bash
sudo bash scripts/00-install.sh harbor
~~~

Harbor 部署在 `HARBOR_NODE_IP` 指定节点，默认使用 `http://harbor.<节点IP>.nip.io`。脚本会安装 Docker Engine/Compose（即使 Kubernetes 节点使用 containerd）、运行 Harbor 官方离线安装器、导入 `offline/images/kubernetes-images-linux-amd64.tar`，并将镜像推送到 `PRIVATE_REGISTRY`。Harbor 管理员密码和数据库密码在 Harbor 节点生成，保存在 `/root/harbor-credentials`，权限为 0600。

运行时预处理阶段已经配置 registry trust：containerd 使用 `/etc/containerd/certs.d/<HARBOR_HOST>/hosts.toml`，Docker 使用 `insecure-registries`。由于当前 Harbor URL 为 HTTP，此配置不是 TLS CA 信任。完成 Harbor 健康检查和镜像推送后，才允许继续 etcd 阶段。

~~~bash
sudo bash scripts/16-batch-exec.sh masters 07-bootstrap-etcd.sh --parallel
~~~

在启动控制平面前，必须先执行部署机上的 etcd 专项检查：

~~~bash
sudo bash scripts/21-verify-etcd.sh
~~~

该脚本检查全部 Master endpoint health、member 数量与 `MASTER_COUNT` 一致、预期成员及 peer URL、唯一 Leader 和 Raft 状态。所有 endpoint 均应返回 healthy，成员数量必须等于 `MASTER_COUNT` 且有且仅有 1 个 Leader。未达到 quorum 时不得继续启动控制平面。完整集群就绪后再运行 scripts/18-verify-cluster.sh。

## 9. 启动 Kubernetes 控制平面与 Worker

先启动全部 Master：

~~~bash
sudo bash scripts/16-batch-exec.sh masters 08-start-control-plane.sh --parallel
~~~

通过 SSH 在每台 Master 本机检查 `https://127.0.0.1:6443/readyz`。统一安装入口会等待全部 Master 的 API `/readyz` 成功，再允许进入 Worker 阶段。手工分步执行时也必须遵守该门槛，再启动 Worker：

~~~bash
sudo bash scripts/16-batch-exec.sh workers 13-install-nginx-proxy.sh --parallel
sudo bash scripts/16-batch-exec.sh workers 09-start-worker.sh --parallel
~~~

Worker NGINX 是 TLS passthrough，监听本机 127.0.0.1:6443，向全部 Master 的 TCP/6443 转发。管理员入口 API_DNS 仍然是单 Master DNS，不等同于外部 HA LB。

## 10. 镜像同步、安装 Calico 和 CoreDNS

### 9.1 镜像准备与验收

CoreDNS、pause、Calico Operator/数据面和 NodeLocal DNSCache 镜像已由 Actions 从 Helm Chart 渲染结果、Operator 动态清单及运行时镜像声明中提取，并在 Harbor 阶段自动导入/推送。无需再手工执行 docker pull/tag/push。可根据 `offline/images/IMAGE-REFERENCES.txt` 核对源镜像及对应 tag，并在 Harbor 中确认以下目标路径：

- `$PRIVATE_REGISTRY/coredns/coredns:<Chart 默认 tag>`
- `$PAUSE_IMAGE`
- `$PRIVATE_REGISTRY/calico/node:<Operator 清单 tag>`
- `$PRIVATE_REGISTRY/tigera/operator:<Chart 默认 tag>`
- `$NODE_LOCAL_DNS_IMAGE`

NodeLocal DNSCache 现已由 `scripts/25-install-node-local-dns.sh` 部署为覆盖所有节点的 DaemonSet。每个节点的 kubelet `clusterDNS` 指向 `NODE_LOCAL_DNS_IP`，NodeLocal DNSCache 将集群域名请求转发至 CoreDNS 的 `DNS_SERVICE_IP`。离线 Release 还包含 BusyBox 网络验收镜像；Harbor 阶段会将其推送到 `NETWORK_TEST_IMAGE` 对应路径。业务镜像及其他未列入基础归档的依赖仍需自行准备。

### 9.2 安装 Calico VXLAN

~~~bash
sudo bash scripts/19-install-calico.sh
~~~

脚本依次应用 Release 中的 CRD、Tigera Operator，并生成含 POD_CIDR 和私有 Registry 的 Installation CR。默认 VXLAN、BGP Disabled；因此正常情况下不应把 BGP Peering 列表为空当作故障。节点地址自动探测使用 Operator/Installation 的默认配置；多网卡节点应在安装前按实际网卡规划，在 `scripts/19-install-calico.sh` 的 Helm values 中显式配置 `installation.calicoNetwork.nodeAddressAutodetectionV4`。

检查：

~~~bash
kubectl get tigerastatus
kubectl get pods -n calico-system -o wide
kubectl get nodes -o wide
calicoctl get nodes -o wide
calicoctl get ippools -o wide
~~~

期望所有节点出现 Ready 的 calico-node Pod；Installation/各 TigeraStatus 状态正常，IPPool CIDR 与 POD_CIDR 一致。

### 9.3 安装 CoreDNS

CoreDNS Chart 的默认镜像 tag 已随 Chart 固定，部署脚本只将镜像仓库地址指向 Harbor；确认 `offline/images/IMAGE-REFERENCES.txt` 中的 CoreDNS 镜像已成功推送后执行：

~~~bash
sudo bash scripts/20-install-coredns.sh
kubectl -n kube-system rollout status deployment/coredns
kubectl -n kube-system get svc kube-dns
~~~

CoreDNS Service ClusterIP 必须等于 DNS_SERVICE_IP。

### 9.4 安装 NodeLocal DNSCache

NodeLocal DNSCache 使用 Release 中的镜像 `$NODE_LOCAL_DNS_IMAGE`，由 Harbor 节点提前导入。确认 kubelet 配置已经在渲染/分发阶段写入本地 DNS 地址：

~~~bash
grep -A1 '^clusterDNS:' generated/worker-01/var/lib/kubelet/config.yaml
grep -E '^(DNS_SERVICE_IP|NODE_LOCAL_DNS_IP)=' generated/worker-01/etc/kubernetes/cluster.env
~~~

预期 `clusterDNS` 为 `169.254.20.10`（或实际配置的 `NODE_LOCAL_DNS_IP`），CoreDNS Service IP 仍为 `DNS_SERVICE_IP`。部署：

~~~bash
sudo bash scripts/25-install-node-local-dns.sh
kubectl -n kube-system rollout status ds/node-local-dns
kubectl -n kube-system get ds node-local-dns
kubectl -n kube-system get pods -l k8s-app=node-local-dns -o wide
~~~

DaemonSet 的 `numberReady` 必须等于 Kubernetes Node 总数。NodeLocal DNSCache 以 hostNetwork 方式监听链路本地地址 53/UDP、53/TCP；请确保节点防火墙允许本机 Pod 到该地址的 DNS 流量，且没有其他 hostNetwork 服务占用 53 端口。


## 11. 集群健康检查与功能验收

运行一键检查：

~~~bash
sudo bash scripts/18-verify-cluster.sh
~~~

脚本检查：
1. etcd 全部 endpoint health、endpoint status、member list（成员数量与 MASTER_COUNT 一致）；
2. API Server /readyz?verbose；
3. 所有 Node Ready；
4. Calico DaemonSet rollout、calicoctl 节点和 IPPool、可用时 TigeraStatus；
5. CoreDNS Deployment、Service ClusterIP、Endpoints 和全量 Pod 状态；Node 数量及每个 InternalIP 与部署配置一致。
6. NodeLocal DNSCache DaemonSet 覆盖全部节点并 Ready。
7. 自动化网络验收：从 Harbor 强制拉取 BusyBox 测试镜像，验证 Pod 的 resolv.conf 使用 NodeLocal DNS、解析 kubernetes.default 和验收 Service 域名，再从不同节点间通过 Pod IP 与 ClusterIP Service 访问 HTTP 服务。测试 namespace 在结束时自动删除。

`scripts/18-verify-cluster.sh` 会自动调用 `scripts/26-verify-network.sh` 执行以下检查，无需手动创建测试 Pod：

~~~bash
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl get svc -A
kubectl run dns-test --image=busybox:1.36 --restart=Never --command -- sleep 3600
kubectl wait --for=condition=Ready pod/dns-test --timeout=180s
kubectl exec dns-test -- nslookup kubernetes.default.svc.cluster.local
kubectl delete pod dns-test
~~~

如需跨节点网络验收，分别在不同 Worker 上运行测试 Pod，验证 Pod IP 互通；再创建 ClusterIP Service，验证服务发现和转发。镜像必须先同步到内网仓库。NodePort 验收需使用实际配置的 NodePort 和防火墙策略。

## 12. 证书检查、etcd 备份和运行时检查

证书 SAN 检查示例（以下 etcd-master-01 是默认示例拓扑中的首个 Master；应按实际节点名替换）：

~~~bash
openssl x509 -in pki/apiserver.crt -noout -subject -issuer -dates -ext subjectAltName
openssl verify -CAfile pki/k8s-ca.crt pki/apiserver.crt
openssl x509 -in pki/etcd-master-01-server.crt -noout -subject -ext subjectAltName
~~~

证书应包含预期主机名和内网 IP；不要只检查证书文件存在。根 CA 私钥应离线加密备份，制定证书轮换流程。

etcd 快照示例（使用任意健康 Master 上的 etcdctl 和该成员自己的 etcd server client cert）： 以下 `master-01` 是默认示例拓扑中的首个 Master，实际执行时请替换为所选成员名称。

~~~bash
ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/etcd/pki/etcd-ca.crt \
  --cert=/etc/etcd/pki/etcd-master-01-server.crt \
  --key=/etc/etcd/pki/etcd-master-01-server.key \
  snapshot save /var/backups/etcd-$(date +%F-%H%M%S).db
~~~

将快照复制到异机/对象存储，验证快照状态并定期演练恢复。不要在生产集群直接执行恢复测试。

运行时检查：
- containerd：systemctl status containerd、crictl info、ctr -n k8s.io containers list。
- Docker：systemctl status docker cri-docker.socket cri-docker.service、docker info、crictl info。
- kube-proxy IPVS：ipvsadm -Ln；nftables：nft list ruleset。

## 13. 故障处理和安全边界

- etcd 无 quorum：先检查成员状态、2379/2380 网络、防火墙、证书 SAN/有效期和磁盘延迟；不要删除 /var/lib/etcd 重建成员。
- Calico Pod 不 Ready：检查镜像拉取、节点路由/MTU、UDP/4789、防火墙、CNI 文件和 calico-node 日志；多网卡时检查地址自动探测。
- CoreDNS 不 Ready：检查 CoreDNS 镜像、Service ClusterIP、kube-proxy、上游 DNS 和 Corefile。
- Worker NotReady：检查本机 NGINX、127.0.0.1:6443/readyz、CRI socket、kubelet 日志和 kubelet 证书。
- 不得提交私钥、kubeconfig、仓库认证凭据或真实生产 IP 等敏感信息到公共仓库。
- 当前没有外部 LB/VIP；若需要管理入口高可用，需另行部署并验收负载均衡器。
