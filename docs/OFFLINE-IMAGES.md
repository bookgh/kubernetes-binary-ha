# 离线容器镜像准备与导入指南

本项目的二进制/RPM 准备脚本不会自动推断所有镜像及其传递依赖。Calico Operator、Calico Node、kube-controllers、CoreDNS、pause，以及 metrics、CSI、存储和其他业务组件的镜像都必须显式准备。

## 推荐流程

1. 在联网暂存机安装 `skopeo` 或 `podman`，并准备 containerd/OCI 工具。
2. 渲染目标 Calico 版本的完整清单，检查 Operator 默认镜像和 CRD 引用。
3. 提取全部镜像引用，生成清单并逐项审核。
4. 按 `linux/amd64` 拉取镜像，记录镜像 digest。
5. 重新标记并推送到内网镜像仓库，或导出 OCI 归档。
6. 生成 digest 锁定清单和 SHA256 校验文件。
7. 在隔离环境使用 `ctr -n k8s.io images import` 导入 OCI 归档。
8. 配置 containerd registry mirror；需要认证时配置 imagePullSecrets。
9. 在无公网环境执行镜像拉取验证，确认所有镜像均可获取。

## 至少需要核对的镜像类别

- `registry.k8s.io/pause`：版本必须与 containerd `sandbox_image` 一致。
- `quay.io/tigera/operator`：Calico Operator。
- `docker.io/calico/node`：Calico 节点组件。
- `docker.io/calico/cni`：Calico CNI。
- `docker.io/calico/kube-controllers`：Calico 控制器。
- `registry.k8s.io/coredns/coredns`：CoreDNS。
- 可选 Typha、metrics-server、Ingress、CSI、监控、策略和业务应用镜像。

不要假设静态镜像清单在 Calico 补丁版本之间始终不变。应检查目标版本实际渲染的清单、Operator 默认镜像和 digest，并优先使用 digest 固定版本。

## 验收标准

- 每个镜像都有来源、tag、digest 和 SHA256 记录。
- 镜像架构为目标节点支持的 `linux/amd64`。
- 所有镜像在内网仓库或离线归档中均可用。
- 隔离环境节点可成功拉取 pause、CNI、CoreDNS 和控制器镜像。
