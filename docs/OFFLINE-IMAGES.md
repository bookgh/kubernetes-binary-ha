# 离线容器镜像准备与 Harbor 导入

Harbor 自身只使用官方 Harbor offline installer；Harbor 服务镜像不进入通用 Kubernetes 镜像归档。

## Helm Chart 与版本来源

Calico、Tigera Operator 和 CoreDNS 的版本统一在 `config/cluster.env` 中定义（仓库默认值维护在 `config/cluster.env.example`）：

- `CALICO_VERSION`：Calico 应用/镜像版本；`CALICO_CHART_VERSION`：Calico Helm Chart 版本（默认与应用版本一致）。
- `TIGERA_OPERATOR_VERSION`：Tigera Operator 镜像版本。
- `COREDNS_VERSION`：CoreDNS 应用镜像版本。
- `COREDNS_CHART_VERSION`：CoreDNS Helm Chart 版本。

GitHub Actions 无法读取部署机未提交的 `config/cluster.env`，因此构建时读取仓库中的 `config/cluster.env.example`。升级组件时，应同步更新该示例配置中的版本；部署机再将其复制为 `config/cluster.env`。

## 镜像发现与打包

CI 不再维护 Calico/CoreDNS 的独立镜像数组，构建流程如下：

1. 下载指定版本的 Calico 原生 `projectcalico.org.v3` CRD Chart、`tigera-operator` Chart 和 CoreDNS Chart，全部保存到 Release 的 `helm/` 目录。
2. 使用 Release 内的 Helm 二进制渲染这三个 Chart；CoreDNS 渲染时应用与部署一致的镜像版本、Service IP、集群域名和 kube-dns 标签。
3. 从渲染后的 YAML 自动提取镜像引用，定位 Chart 实际引用的 Tigera Operator 镜像并拉取。
4. 调用该 Operator 的 `--print-images=list`，获取其版本对应的 Calico 工作负载镜像清单。将该清单转成仅供提取使用的 YAML，不会 kubectl apply。
5. 将 pause、NodeLocal DNS 等运行时镜像声明与 Chart/Operator 清单合并，通过 `scripts/ci/extract-image-refs.py` 校验 tag/digest、规范化、去重并排序。
6. CI 按最终清单拉取 linux/amd64 镜像并生成统一归档；Harbor 安装脚本消费同一清单，保留源仓库路径推送到私有仓库。

Calico 3.33 使用统一的 `calico/calico` 镜像，不能再引用不存在的 `calico/cni`、`calico/kube-controllers` 等旧镜像。镜像集合由对应版本 Operator 动态输出，不在 CI 中手写旧镜像名。

## Release 资产

- `helm/projectcalico.org.v3-<version>.tgz`：Calico 原生 v3 CRD Chart。
- `helm/tigera-operator-<version>.tgz`：Calico Tigera Operator Chart。
- `helm/coredns-<version>.tgz`：CoreDNS Chart。
- `manifests/helm-rendered/`：CI 使用的 Helm 渲染结果，仅用于镜像提取和审计。
- `images/kubernetes-images-linux-amd64.tar`：除 Harbor 自身之外的离线部署镜像。
- `images/IMAGE-REFERENCES.txt`：源镜像引用及 RepoDigest。

## 部署流程

1. 在 `config/cluster.env` 配置集群参数、组件版本和 Harbor 私有仓库地址。
2. 执行 `sudo bash scripts/00-install.sh prepare`。
3. 执行 `sudo bash scripts/00-install.sh harbor`，或运行 `sudo bash scripts/00-install.sh all`。Harbor 在预处理后、etcd 前安装。
4. Harbor 节点读取 `offline/images/IMAGE-REFERENCES.txt`，导入归档并按源仓库路径重打标签推送。
5. 执行 `scripts/19-install-calico.sh` 和 `scripts/20-install-coredns.sh`，从 Release 内本地 Chart 安装，不访问公网 Helm 仓库。

NodeLocal DNS 镜像目前作为离线镜像声明纳入资源包；仓库尚无 NodeLocal DNS 工作负载安装脚本/manifest，因此不代表该组件已经部署。新增部署制品后，提取器会自动发现其镜像。

Harbor 默认使用 HTTP/80 + nip.io。HTTP registry 配置不是 TLS CA 信任；生产环境建议使用 HTTPS 和证书。
