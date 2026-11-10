# 自动构建离线资源包并发布 GitHub Release

## 一、通过 Issue 触发

1. 在 Issue 标题或正文中填写 Kubernetes 版本号，例如 `v1.37.2`。
2. 为 Issue 添加 `build-offline` 标签。
3. 工作流仅提取符合 `X.Y.Z` 格式的版本号，不会解析或执行 Issue 正文中的其他内容。
4. 工作流先检查 Kubernetes 上游二进制文件是否存在，再下载固定版本的配套组件。
5. 对 Kubernetes 官方提供 SHA256 文件的二进制执行校验。
6. 构建成功后创建 `k8s-vX.Y.Z` Release，并上传离线资源压缩包及其 SHA256 文件。
7. 如果同名 Release/tag 已存在，工作流会拒绝覆盖，保证已发布资源不可被静默替换。

## 二、手动触发

进入 GitHub 仓库的 **Actions → Issue-driven offline bundle release → Run workflow**，输入版本号（例如 `v1.37.2`），然后运行工作流。

## 三、权限要求

工作流使用仓库范围的 `GITHUB_TOKEN`，声明权限为 `contents: write` 和 `issues: read`。请在仓库 Settings → Actions → General 中确认工作流令牌允许创建 Release（需要 Contents 写权限）。不需要授予创建或批准 Pull Request 的权限。

## 四、资源范围与限制

当前 Release 资源包包含 Kubernetes 控制平面/节点/客户端二进制文件、etcd、containerd、runc、CNI 插件、crictl、在 Rocky Linux 9 构建环境源码编译的 NGINX stream 二进制文件，以及 amd64 架构的 Calico Operator/CRD 清单。

当前**不包含** Rocky Linux RPM 依赖包，也不包含全部容器镜像。请单独将镜像同步到内网仓库或制作 OCI 归档，详见 `docs/OFFLINE-IMAGES.md`。配套组件版本固定在工作流环境变量中；调整版本前必须检查上游兼容性和下载地址。

## 五、故障排查

- 工作流没有启动：确认 Issue 已添加 `build-offline` 标签，并确认 Issue 事件触发器启用。
- 版本校验失败：标题或正文必须包含有效的 `vX.Y.Z` 或 `X.Y.Z`。
- 下载失败：检查上游发布资源是否存在，以及 GitHub-hosted runner 的网络连通性。
- Release 创建失败：检查仓库 Actions 的 Contents 写权限，并确认目标 tag 尚未存在。
- NGINX 构建失败：检查 `nginx/Dockerfile`、源码校验和以及 Docker 构建日志。
