# 从零部署到集群验收（Rocky Linux 9 / amd64）

本文是本仓库当前实现的端到端部署流程，目标拓扑为 3 Master + 3 Worker，Kubernetes v1.37.2。部署端负责下载离线 Release、生成 PKI/kubeconfig/节点配置、批量分发和执行。节点端不需要安装 Docker 来构建 NGINX；运行时按 containerd 或 Docker + cri-dockerd 选择。

> **重要边界：** 本仓库自动化覆盖系统二进制、CFSSL、Helm、Calicoctl、crictl、Docker/Compose、RPM、etcd、Calico 安装清单和 CoreDNS 清单。Calico/CoreDNS/pause 等容器镜像仍需提前同步到所有节点可访问的私有镜像仓库；镜像不是 Release 中的二进制文件。当前 API 入口没有外部 LB/VIP，管理端 API_DNS 指向单台 Master，不具备入口层 HA。

## 0. 部署拓扑与网络前置条件

- 3 台 Master：etcd、kube-apiserver、kube-controller-manager、kube-scheduler。
- 3 台 Worker：kubelet、kube-proxy、NGINX TCP/TLS 透传代理。
- Rocky Linux 9 x86_64，固定主机名 master-01..03、worker-01..03，静态 IP。
- 所有节点时间同步；部署机 root SSH 免密访问所有节点。
- Master 间 TCP 2379/2380；Worker 到全部 Master TCP 6443；节点间 VXLAN UDP 4789；节点间 TCP 179 仅在启用 Calico BGP 时需要。另按 docs/NETWORK-PORTS.md 配置其余端口。
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

- 六台节点的 IP、主机名数组；目前脚本校验固定 3 Master + 3 Worker。
- API_DNS 必须解析到可达 Master IP。当前没有 VIP/LB，DNS 解析不提供高可用。
- RUNTIME_TYPE=containerd 或 RUNTIME_TYPE=docker。Docker 模式必须使用 cri-dockerd。
- KUBE_PROXY_MODE=nftables 或 ipvs。Kubernetes 1.37 新部署推荐 nftables；IPVS 已弃用，使用前应确认内核模块和 kube-proxy 支持。
- PRIVATE_REGISTRY、COREDNS_IMAGE、PAUSE_IMAGE 必须指向真实可达、已准备镜像的仓库。

版本清单集中在 config/release-versions.env，集群参数集中在 config/cluster.env。修改版本后必须重新构建一个新的、不可覆盖的 Release tag。

## 2. 构建并发布离线 Release

GitHub Actions 的离线 Release workflow 使用 scripts/ci/build-offline-release.sh 构建。为目标 Kubernetes 版本触发 workflow，构建完成后应在 GitHub Releases 中看到 k8s-v1.37.2-r2（tag 由 RELEASE_REVISION 控制）。

离线包归档内含：
- Kubernetes server/client 二进制、etcd、containerd、runc、CNI plugins、crictl；
- CFSSL 和 cfssljson、Helm、Calicoctl；
- Docker Engine 静态二进制、cri-dockerd、Docker Compose CLI plugin；
- NGINX stream 二进制及构建信息；
- Rocky Linux 9 amd64 RPM 及依赖、Calico CRD/Operator manifests、SHA256SUMS 和 ARTIFACTS.txt。

下载前检查 Release 的资产和 SHA256。Release tag 不可覆盖；变更组件版本应发布新 tag。离线包中不包含容器镜像归档。

## 3. 准备离线资源并安装部署端 CLI

~~~bash
sudo bash scripts/01-prepare-offline.sh
sudo dnf install -y --disablerepo="*" offline/rpms/*.rpm
sudo bash scripts/17-install-cli-tools.sh
~~~

01 会下载 Release 归档和 SHA256，校验外层及内部 SHA256SUMS，并将离线内容放入仓库根目录 offline/。RPM 包来自 Release，不再要求部署机访问 Rocky Linux 软件源。部署机本地安装 Helm、Calicoctl、crictl、CFSSL 和 cfssljson，便于后续管理和验收。

如果部署机与实际执行下载的暂存机分离，将完整 offline/ 目录安全复制到部署机项目根目录，并再次执行：

~~~bash
(cd offline && sha256sum -c SHA256SUMS)
~~~

## 4. 本地生成 CFSSL PKI、kubeconfig 和节点配置

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

## 5. 分发到六台节点

部署机确认 root SSH 免密、SSH host key 已核验：

~~~bash
sudo bash scripts/15-distribute-node-configs.sh
~~~

脚本通过 SCP/rsync 分发仓库、Release 离线包、每节点 kubelet/kube-proxy 配置、运行时配置、模块/sysctl 配置和节点专属凭据。根 CA 私钥和管理员 kubeconfig 不分发；etcd CA 私钥保留在部署机。检查各节点文件权限和目录：

~~~bash
ssh root@master-01 'ls -l /etc/kubernetes/pki /etc/etcd/pki'
ssh root@worker-01 'ls -l /etc/kubernetes/pki /etc/kubernetes'
~~~

## 6. 批量预检、安装运行时和 systemd

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

## 7. 启动 etcd 集群并验证 quorum

~~~bash
sudo bash scripts/16-batch-exec.sh masters 07-bootstrap-etcd.sh --parallel
~~~

在启动控制平面前，必须先执行部署机上的 etcd 专项检查：

~~~bash
sudo bash scripts/21-verify-etcd.sh
~~~

该脚本检查三个 endpoint health、member 数量为 3、Leader 唯一性和 Raft 状态。三个 endpoint 均应返回 healthy，成员应为 3 个且有且仅有 1 个 Leader。未达到 quorum 时不得继续启动控制平面。完整集群就绪后再运行 scripts/18-verify-cluster.sh。

## 8. 启动 Kubernetes 控制平面与 Worker

先启动三台 Master：

~~~bash
sudo bash scripts/16-batch-exec.sh masters 08-start-control-plane.sh --parallel
~~~

确认各 Master 的 API Server /readyz 正常，再启动 Worker：

~~~bash
sudo bash scripts/16-batch-exec.sh workers 13-install-nginx-proxy.sh --parallel
sudo bash scripts/16-batch-exec.sh workers 09-start-worker.sh --parallel
~~~

Worker NGINX 是 TLS passthrough，监听本机 127.0.0.1:6443，向三个 Master 的 TCP/6443 转发。管理员入口 API_DNS 仍然是单 Master DNS，不等同于外部 HA LB。

## 9. 镜像同步、安装 Calico 和 CoreDNS

### 9.1 镜像准备

离线 Release 包含清单和二进制，不包含 OCI 镜像。需在可访问上游镜像的暂存机拉取并推送至私有仓库。至少准备：
- quay.io/tigera/operator:v3.33.0；
- Calico v3.33.0 对应的 calico/node、calico/cni、calico/kube-controllers（以及 Operator 清单/Installation 实际引用的其他镜像）；
- coredns/coredns:v1.13.1；
- registry.k8s.io/pause:3.10。

示例（根据企业仓库命名规则调整）：

~~~bash
docker pull quay.io/tigera/operator:v3.33.0
docker tag quay.io/tigera/operator:v3.33.0 "$PRIVATE_REGISTRY/tigera/operator:v3.33.0"
docker push "$PRIVATE_REGISTRY/tigera/operator:v3.33.0"
docker pull coredns/coredns:v1.13.1
docker tag coredns/coredns:v1.13.1 "$COREDNS_IMAGE"
docker push "$COREDNS_IMAGE"
~~~

Calico 其他镜像按 offline/manifests/tigera-operator.yaml 与 Operator 生成的资源逐项同步。确认六台节点都能访问仓库、信任仓库 CA，并已配置拉取凭据（如仓库启用认证）。

### 9.2 安装 Calico VXLAN

~~~bash
sudo bash scripts/19-install-calico.sh
~~~

脚本依次应用 Release 中的 CRD、Tigera Operator，并生成含 POD_CIDR 和私有 Registry 的 Installation CR。默认 VXLAN、BGP Disabled；因此正常情况下不应把 BGP Peering 列表为空当作故障。节点地址自动探测默认 firstFound，多网卡节点需在安装前根据实际网卡调整 manifests/calico-installation.yaml.template 的 nodeAddressAutodetectionV4。

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

先确保 config/cluster.env 的 COREDNS_IMAGE 是已推送的私有镜像地址，然后执行：

~~~bash
sudo bash scripts/20-install-coredns.sh
kubectl -n kube-system rollout status deployment/coredns
kubectl -n kube-system get svc kube-dns
~~~

CoreDNS Service ClusterIP 必须等于 DNS_SERVICE_IP。

## 10. 集群健康检查与功能验收

运行一键检查：

~~~bash
sudo bash scripts/18-verify-cluster.sh
~~~

脚本检查：
1. etcd 三个 endpoint health、endpoint status、member list；
2. API Server /readyz?verbose；
3. 所有 Node Ready；
4. Calico DaemonSet rollout、calicoctl 节点和 IPPool、可用时 TigeraStatus；
5. CoreDNS Deployment 和全量 Pod 状态。

进一步执行业务网络验收：

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

## 11. 证书检查、etcd 备份和运行时检查

证书 SAN 检查示例：

~~~bash
openssl x509 -in pki/apiserver.crt -noout -subject -issuer -dates -ext subjectAltName
openssl verify -CAfile pki/k8s-ca.crt pki/apiserver.crt
openssl x509 -in pki/etcd-master-01-server.crt -noout -subject -ext subjectAltName
~~~

证书应包含预期主机名和内网 IP；不要只检查证书文件存在。根 CA 私钥应离线加密备份，制定证书轮换流程。

etcd 快照示例（使用可访问 etcd 的 Master 上的 etcdctl 和 etcd client cert）：

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

## 12. 故障处理和安全边界

- etcd 无 quorum：先检查成员状态、2379/2380 网络、防火墙、证书 SAN/有效期和磁盘延迟；不要删除 /var/lib/etcd 重建成员。
- Calico Pod 不 Ready：检查镜像拉取、节点路由/MTU、UDP/4789、防火墙、CNI 文件和 calico-node 日志；多网卡时检查地址自动探测。
- CoreDNS 不 Ready：检查 CoreDNS 镜像、Service ClusterIP、kube-proxy、上游 DNS 和 Corefile。
- Worker NotReady：检查本机 NGINX、127.0.0.1:6443/readyz、CRI socket、kubelet 日志和 kubelet 证书。
- 不得提交私钥、kubeconfig、仓库认证凭据或真实生产 IP 等敏感信息到公共仓库。
- 当前没有外部 LB/VIP；若需要管理入口高可用，需另行部署并验收负载均衡器。
