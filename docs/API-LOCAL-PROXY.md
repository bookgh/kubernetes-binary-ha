# Local Kubernetes API endpoint design

Master-local kubelet, controller-manager and scheduler use `https://127.0.0.1:6443`. Each Worker runs NGINX stream locally on `127.0.0.1:6443`, forwarding TCP to all three master addresses on port 6443. The Master API server still binds `0.0.0.0:6443` so Workers can reach it.

NGINX is a TCP passthrough proxy. It does not terminate TLS. The selected kube-apiserver terminates TLS and validates the original client certificate. The API server certificate SAN must include IP `127.0.0.1`, all three master IPs, `API_DNS`, and Kubernetes service DNS/IP.

The NGINX source is compiled with the stream module by `nginx/Dockerfile` on a connected Rocky Linux 9 amd64 build host. `scripts/12-build-nginx-binary.sh` exports the resulting binary to `offline/bin/nginx`; `scripts/13-install-nginx-proxy.sh` installs it on each Worker. Docker/Podman is not required on cluster nodes.

No external LB/VIP is deployed in this phase. Admin kubeconfig uses `API_DNS`, which must resolve to a reachable master address. Without an external LB, admin endpoint availability is not HA; operators can point it to another master when required.

On Workers, verify `nginx -t`, `systemctl status nginx-k8s-api`, and `curl --cacert /etc/kubernetes/pki/k8s-ca.crt https://127.0.0.1:6443/readyz`.
