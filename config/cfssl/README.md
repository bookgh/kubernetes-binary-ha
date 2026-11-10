# CFSSL PKI 配置

此目录存放证书签发配置模板，纳入版本控制。X.509 证书由 `scripts/03-generate-pki.sh` 使用 CFSSL 生成，所有叶子证书签发命令均显式传入 `-hostname=节点主机名,节点内网IP`。CFSSL 会自动识别 DNS 名和 IP，不要写 `DNS:` 或 `IP:` 前缀。

- `*-ca-csr.json`：各独立 CA 的 CSR 模板。
- `ca-config.json`：server/client/peer 签发 profile 和有效期。
- `csr/*.json`：按 apiserver、etcd server/peer、kubelet、admin、controller-manager、scheduler、kube-proxy 等服务分别维护 CSR 模板；脚本按节点清单动态填充 CN，SAN 由 `-hostname` 参数指定。

私钥、签发出的证书、序列号和 kubeconfig 不属于配置模板，禁止提交到 Git。部署机上的 `pki/` 目录应限制为 root 可读，并做好离线备份。
