# 自动构建离线资源包并发布 GitHub Release

## 1. 设计原则

GitHub Actions 负责触发，仓库脚本负责实现。构建逻辑、下载 URL、版本号、校验和不重复写在 Workflow YAML 中。

- Workflow：只做 Issue/手动触发过滤、checkout、传入事件上下文并调用构建脚本。
- `config/release-versions.env`：统一维护 etcd、containerd、runc、CNI、crictl、Calico、CoreDNS、NGINX 版本及 NGINX 源码 SHA256。
- `scripts/ci/build-offline-release.sh`：唯一构建入口，完成版本提取、下载、校验、NGINX 源码构建、归档和 Release 发布。
- `nginx/Dockerfile`：唯一 NGINX 编译定义。
- `scripts/13-install-nginx-proxy.sh`：Worker 下载对应 Release 中的 NGINX 二进制和校验文件，验证后安装。

## 2. Issue 触发

1. 创建 Issue，在标题或正文填写 Kubernetes 版本，例如 `v1.37.2`。
2. 添加 `build-offline` 标签。
3. Actions 提取第一个符合 `X.Y.Z` 或 `vX.Y.Z` 的版本号。
4. 构建脚本下载 Kubernetes 和配套组件，并对 Kubernetes 官方 SHA256 文件执行校验。
5. Docker 构建 NGINX 源码，导出独立的 `nginx-<版本>-linux-amd64` 二进制及 SHA256。
6. 发布 `k8s-vX.Y.Z` Release。

## 3. 手动触发

进入仓库 **Actions → Issue 驱动的离线资源包构建与 Release 发布 → Run workflow**，填写版本号。

## 4. Release 资产

- `offline-kubernetes-vX.Y.Z-rocky9-amd64.tar.gz`：Kubernetes、etcd、containerd、runc、CNI、crictl、Calico 清单和 NGINX 副本。
- 对应 `.tar.gz.sha256`：归档校验文件。
- `nginx-<NGINX_VERSION>-linux-amd64`：NGINX 独立二进制。
- 对应 `.sha256`：NGINX 独立二进制校验文件。

Worker 安装脚本使用 Kubernetes 版本构造 Release tag，并使用 `NGINX_VERSION` 构造资产名称。下载后执行 SHA256 校验，校验失败立即退出，不安装不可信二进制。

## 5. 如何修改版本或构建逻辑

- 修改配套组件版本：编辑 `config/release-versions.env`。
- 修改 NGINX 编译参数：编辑 `nginx/Dockerfile`。
- 修改下载、校验、打包、发布步骤：编辑 `scripts/ci/build-offline-release.sh`。
- 修改触发条件或 runner：编辑 `.github/workflows/issue-offline-release.yml`。
- 修改 Worker 下载/安装行为：编辑 `scripts/13-install-nginx-proxy.sh`。

不要在 Workflow YAML 中复制脚本中的 URL、版本或 shell 构建命令。

## 6. Runner 与兼容性

当前使用固定的 `ubuntu-24.04` runner，并使用支持 Node.js 24 的 `actions/checkout@v5`，避免 `ubuntu-latest` 自动迁移造成不可控变化。

## 7. 资源范围

当前 Release 不包含完整 Rocky Linux RPM 仓库快照，也不包含所有容器镜像。容器镜像应按目标版本独立同步到内网仓库或 OCI 归档。生产使用前必须验证离线节点能访问所有镜像。
