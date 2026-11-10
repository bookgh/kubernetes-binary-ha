# 生产环境验收清单

以下项目必须逐项验证并留存结果。任何关键项未通过，都不应进入生产切换。

- [ ] Rocky Linux 9 次版本、内核版本已批准，六台节点基线一致。
- [ ] CPU 架构为 x86_64；时间同步正常；主机名和静态 IP 正确。
- [ ] Pod/Service CIDR 与所有已路由网络无重叠。
- [ ] 防火墙按最小权限配置；VXLAN 节点间 UDP/4789 可达。
- [ ] `RUNTIME_TYPE` 与实际运行时一致：containerd CRI v1 / Docker + cri-dockerd 至少选其一；CRI endpoint 可由 `crictl info` 正常访问；cgroup driver 为 systemd；pause 镜像可离线获取。
- [ ] 所有软件包已验证 SHA256/签名，并记录来源和构建信息；NGINX 从对应 GitHub Release 下载并校验。
- [ ] `KUBE_PROXY_MODE` 与实际 kube-proxy 配置一致；IPVS 模式确认模块和 `ipvsadm -Ln`，nftables 模式确认内核 >= 5.13、nft >= 1.0.1 且 `nft list ruleset` 可检查。
- [ ] 所有镜像均固定 digest，并已存在于私有仓库或离线归档。
- [ ] API Server 证书 SAN 覆盖 `127.0.0.1`、`API_DNS`、全部 Master IP 和 Kubernetes Service DNS/IP。
- [ ] 每个 kubelet 证书 CN 为 `system:node:<node>`，O 为 `system:nodes`。
- [ ] etcd 成员证书和 peer 双向 TLS 正常；集群恰有一个 Leader。
- [ ] etcd 数据位于可靠本地 SSD；磁盘延迟和 fsync 已纳入监控。
- [ ] 三台 Master 的 API Server `/readyz` 均通过。
- [ ] controller-manager 和 scheduler Leader Election 正常。
- [ ] 六台 Kubernetes 节点全部 Ready。
- [ ] Calico VXLAN 和跨节点 Pod 网络通信通过。
- [ ] CoreDNS 至少两个副本，集群 Service 域名解析正常。
- [ ] etcd 快照异机保存，恢复演练通过。
- [ ] 逐台停止 API Server，验证 Worker 本机 NGINX 上游故障切换。
- [ ] 证书过期、审计日志、etcd 告警、节点压力和 API 延迟均有监控。
- [ ] 已在预演环境完成升级演练。
- [ ] 管理员 API DNS 的单点风险已被接受，或已规划后续外部 LB 方案。
