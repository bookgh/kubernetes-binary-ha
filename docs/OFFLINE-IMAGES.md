# 离线容器镜像准备与 Harbor 导入

Harbor 自身只使用官方 Harbor offline installer；Harbor 服务镜像不进入通用 Kubernetes 镜像归档。

## 镜像发现与打包

CI 不再维护独立的镜像数组，按以下顺序构建：

1. 下载固定版本的 Calico CRDs 和 Tigera Operator manifests，并把仓库实际部署使用的 CoreDNS、Calico Installation 模板复制到 Release 的 `manifests/`。
2. 将运行时 sandbox、NodeLocal DNS 和 Calico Operator 动态创建的镜像声明写入仅供提取使用的 `image-inventory.yaml`。该文件不会被 kubectl apply。
3. 如果仓库存在 `helm/*.tgz`，CI 使用 Release 内 Helm 渲染 Chart（优先采用 Chart 内的 `values-offline.yaml`），然后解析渲染结果。
4. `scripts/ci/extract-image-refs.py` 遍历 YAML/JSON 文档中的 image 字段，校验 tag/digest、规范化引用、去重并排序，生成 `images/IMAGE-REFERENCES.txt`。
5. CI 按清单拉取 linux/amd64 镜像并生成归档。Harbor 安装脚本消费同一清单，保留源仓库路径生成目标标签并推送，不再维护第二套镜像映射。

清单按字典序稳定排序，构建目录每次从空临时目录创建；相同制品和版本输入会得到相同的镜像引用清单。OCI tar 的字节级可复现性取决于 Docker 导出工具，当前保证输入与镜像清单幂等。

## Release 资产

- `harbor/harbor-offline-installer-v<version>-amd64.tgz`：Harbor 官方离线安装器，单独保存。
- `manifests/`：部署时使用的 Calico CRDs、Tigera Operator、CoreDNS 与 Calico Installation 模板，以及镜像提取清单。
- `images/kubernetes-images-linux-amd64.tar`：除 Harbor 自身之外的离线部署镜像。
- `images/IMAGE-REFERENCES.txt`：源镜像引用及 RepoDigest。

## 部署流程

1. 在 `config/cluster.env` 配置 Harbor 节点和私有仓库地址。
2. 执行 `sudo bash scripts/00-install.sh prepare`。
3. 执行 `sudo bash scripts/00-install.sh harbor`，或运行 `sudo bash scripts/00-install.sh all`。Harbor 在预处理后、etcd 前安装。
4. Harbor 节点读取 `offline/images/IMAGE-REFERENCES.txt`，导入归档并按源仓库路径重打标签推送。
5. Calico 和 CoreDNS 安装脚本使用 Release 内的 `offline/manifests/`，与 CI 提取镜像时使用的模板一致。

NodeLocal DNS 镜像目前作为离线镜像声明纳入资源包；仓库尚无 NodeLocal DNS 工作负载安装脚本/manifest，因此不代表该组件已经部署。新增部署制品后，提取器会自动发现其镜像。

Harbor 默认使用 HTTP/80 + nip.io。HTTP registry 配置不是 TLS CA 信任；生产环境建议使用 HTTPS 和证书。
