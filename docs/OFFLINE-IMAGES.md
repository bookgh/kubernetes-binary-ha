# 离线容器镜像准备与 Harbor 导入

本项目的 GitHub Actions Release 现在统一打包 Harbor 官方离线安装器和基础 Kubernetes/Calico OCI 镜像。Harbor 安装器单独放在 `offline/harbor/`；其他基础镜像合并为一个 `offline/images/kubernetes-images-linux-amd64.tar`，并附带 `IMAGE-REFERENCES.txt`、归档 SHA256 和 Release 内部 `SHA256SUMS`。

## Release 中包含的镜像

- CoreDNS：`registry.k8s.io/coredns/coredns`
- pause：`registry.k8s.io/pause`
- Calico Node：`docker.io/calico/node`
- Calico CNI、kube-controllers、pod2daemon-flexvol
- Tigera Operator：`quay.io/tigera/operator`
- NodeLocal DNSCache：`registry.k8s.io/dns/k8s-dns-node-cache`

镜像版本集中在 `config/release-versions.env`。构建时固定拉取 `linux/amd64`，生成一个 Docker image archive，并记录来源镜像引用和 RepoDigest。Harbor 自身的核心镜像由 Harbor 官方 offline installer 包含，不重复加入 Kubernetes 镜像归档。

## 部署流程

1. 在 `config/cluster.env` 配置 `HARBOR_NODE_IP`、`HARBOR_HOST`、`HARBOR_URL`、`PRIVATE_REGISTRY` 和各镜像引用。
2. 执行 `sudo bash scripts/00-install.sh prepare`，完成节点预处理、运行时安装、配置渲染和资源分发。
3. 执行 `sudo bash scripts/00-install.sh harbor`，或直接执行 `sudo bash scripts/00-install.sh all`。统一入口会在 prepare 完成后、etcd 之前安装 Harbor。
4. Harbor 节点导入镜像归档，将源镜像重新标记并推送到 Harbor 的 `library` project。
5. 容器运行时已在 prepare 阶段配置 Harbor HTTP registry endpoint；containerd 使用 `certs.d/<HARBOR_HOST>/hosts.toml`，Docker 使用 `insecure-registries`。
6. 运行时与集群组件从 Harbor 拉取镜像；部署后可使用 `crictl images` 或 `docker images` 检查。

Harbor 默认访问方式为 `http://harbor.<节点IP>.nip.io`。HTTP 不使用 TLS 证书，因此当前所谓 registry trust 是允许访问该 HTTP registry，并非安装 CA 证书。不要将此 HTTP 配置视为生产 HTTPS 安全配置；生产环境建议配置域名证书、HTTPS 和运行时 CA 信任。

## 镜像归档结构与完整性

```text
offline/
├── harbor/
│   └── harbor-offline-installer-v<version>-amd64.tgz
└── images/
    ├── kubernetes-images-linux-amd64.tar
    └── IMAGE-REFERENCES.txt
```

完整 Release 的 `SHA256SUMS` 覆盖 Harbor 安装器和镜像归档。部署机下载时会校验 Release 外层 SHA256 和归档内部 SHA256；分发时大体积 Harbor 与镜像归档只发送到 `HARBOR_NODE_IP`，避免在每个集群节点重复存储。

## 额外镜像

本归档覆盖项目当前明确配置的基础镜像，不代表任意 Operator、CSI、监控、Ingress、存储或业务应用的所有依赖。新增组件时应把其镜像版本纳入 `config/release-versions.env`，并扩展 Actions 镜像清单、Harbor 推送映射和对应部署配置。生产环境建议使用 digest 锁定镜像。
