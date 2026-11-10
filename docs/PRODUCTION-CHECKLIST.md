# Production acceptance checklist

- [ ] Rocky Linux 9 minor release and kernel approved; all nodes same baseline.
- [ ] CPU architecture x86_64; time synchronized; hostnames and static IPs correct.
- [ ] Pod/Service CIDRs do not overlap any routed network.
- [ ] Firewall is least-privilege; UDP/4789 allowed node-to-node for VXLAN.
- [ ] containerd CRI v1 works; SystemdCgroup=true; pause image available offline.
- [ ] All artifacts have verified SHA256/signature and provenance recorded.
- [ ] All image references pinned to digest and available in private registry/offline archives.
- [ ] API server certificate SAN covers VIP, DNS and all master IPs.
- [ ] Each kubelet cert has CN=system:node:<node> and O=system:nodes.
- [ ] etcd member certificates and peer TLS work; exactly one leader.
- [ ] etcd data on reliable local SSD; latency and fsync monitored.
- [ ] API Server /readyz passes on all three masters.
- [ ] Controller-manager and scheduler leader election works.
- [ ] All six Kubernetes nodes Ready.
- [ ] Calico VXLAN and cross-node Pod traffic pass.
- [ ] CoreDNS has at least two replicas and resolves cluster Services.
- [ ] etcd snapshots stored off-node and restore rehearsal passes.
- [ ] VIP failover and API backend failover pass.
- [ ] Certificate expiry, audit logs, etcd alarms, node pressure and API latency monitored.
- [ ] Upgrade rehearsal performed against a staging copy.

- [ ] Each Worker NGINX service listens only on 127.0.0.1:6443 and passes TLS through to the three master API servers.
- [ ] Stop one master API server at a time and verify worker-local NGINX retries another healthy master.
