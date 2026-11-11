# 自动构建离线资源包并发布 GitHub Release

## 1. 设计原则

GitHub Actions 负责触发，仓库脚本负责实现。构建逻辑、下载 URL、版本号、校验和不重复写在 Workflow YAML 中。

- Workflow：只做 Issue/手动触发过滤、checkout、传入事件上下文并调用构建脚本。
- `config/release-versions.env`：统一维护 etcd、containerd、runc、CNI、crictl、Calico、CoreDNS、pause、NodeLocal DNS、Harbor、NGINX 版本及校验值。
- `scripts/ci/build-offline-release.sh`：唯一构建入口，先下载实际部署 manifests/Helm Chart，再提取镜像、拉取归档、构建 NGINX 并发布 Release。
- `scripts/ci/extract-image-refs.py`：从 YAML/JSON manifests 和 Helm 渲染结果提取、规范化、去重、排序镜像引用。
- `nginx/Dockerfile`：唯一 NGINX 编译定义。
- `scripts/13-install-nginx-proxy.sh`：Worker 从配置的 Release base URL 下载 NGINX 二进制和校验文件，验证后安装。

## 2. Issue 触发

1. 创建 Issue，在标题或正文填写 Kubernetes 版本，例如 `v1.37.2`。
2. 添加 `build-offline` 标签。
3. Actions 提取第一个符合 `X.Y.Z` 或 `vX.Y.Z` 的版本号。
4. 构建脚本下载 Kubernetes 和配套组件，并对 Kubernetes 官方 SHA256 文件执行校验。
5. 下载 Harbor 官方 offline installer，并按 `HARBOR_SHA256` 校验。
6. 下载实际部署 manifests；如存在 Helm Chart 则使用 Helm 渲染；从 manifests、渲染结果及运行时/Operator 动态镜像声明中提取镜像引用，校验、去重、排序后拉取 linux/amd64 镜像并生成归档与 RepoDigest 清单。Harbor 自身镜像仅由官方离线安装器提供。
7. 使用 `nginx/Dockerfile` 构建 NGINX 源码，导出独立二进制及 SHA256。
8. 发布 `k8s-vX.Y.Z-rN` Release。

## 3. Release 资产

- `offline-kubernetes-vX.Y.Z-rocky9-amd64.tar.gz`：Kubernetes、etcd、containerd、runc、CNI、crictl、Calico 清单、Harbor 离线安装器、Kubernetes 镜像归档、Docker/Compose 和 Rocky Linux 9 RPM 依赖。
- 对应 `.tar.gz.sha256`：归档校验文件。
- `nginx-<NGINX_VERSION>-linux-amd64`：NGINX 独立二进制。
- 对应 `.sha256`：NGINX 独立二进制校验文件。

归档内的 Harbor 文件单独放在 `harbor/`，Harbor 自身镜像由官方 offline installer 包含。其余镜像由部署制品提取后合并为 `images/kubernetes-images-linux-amd64.tar`，来源和 RepoDigest 记录在 `images/IMAGE-REFERENCES.txt`；Harbor 导入端消费同一清单，不再维护独立映射。内部 `SHA256SUMS` 覆盖两个大文件。

## 4. 版本与下载加速

- 配套组件、Harbor 和镜像版本：编辑 `config/release-versions.env`。
- Release 下载加速：编辑 `config/cluster.env` 中的 `GITHUB_REPOSITORY_URL` 和 `GITHUB_RELEASE_BASE_URL`。
- 修改下载、校验、打包、发布步骤：编辑 `scripts/ci/build-offline-release.sh`。
- 修改 NGINX 编译参数：编辑 `nginx/Dockerfile`。
- 修改 Worker 下载/安装行为：编辑 `scripts/13-install-nginx-proxy.sh`。

Release tag 不可覆盖。修改任何组件版本或制品内容时，必须提升 `RELEASE_REVISION` 并创建新 tag。

## 5. 资源范围与部署边界

当前 Release 包含项目明确列出的基础镜像，不代表任意 Operator、CSI、监控、Ingress、存储或业务应用的所有依赖。新增组件镜像时，应同步扩展 Actions 镜像清单、Harbor 推送映射和部署配置。

Harbor 由 `scripts/00-install.sh all` 在集群预处理后、etcd 之前部署。当前默认访问方式是 HTTP/80 + nip.io；containerd 使用 `certs.d/<HARBOR_HOST>/hosts.toml`，Docker 使用 `insecure-registries`。这是 HTTP registry 配置，不是 TLS CA 信任。生产环境应规划 HTTPS、证书签发和 CA 分发。
