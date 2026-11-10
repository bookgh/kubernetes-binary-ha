# Kubernetes Binary HA

Rocky Linux 9 / amd64 Kubernetes v1.37.2 binary HA deployment baseline. No kubeadm.

## API endpoint design (current)

- Master local kubelet, controller-manager and scheduler: `https://127.0.0.1:6443`.
- Every Worker runs a local NGINX TCP stream proxy on `127.0.0.1:6443`, forwarding to all three master IPs on TCP/6443.
- kube-apiserver on each Master still binds `0.0.0.0:6443` so Workers can connect to its node IP. Master-local clients use loopback.
- NGINX does **not** terminate TLS; TLS passes through to kube-apiserver.
- No external HAProxy/Keepalived, LB nodes, or VIP are used for now.
- Admin kubeconfig uses `API_DNS`, which must resolve to a reachable Master. Without an external LB, the admin endpoint is not HA.

## Build and install NGINX

On a connected Rocky Linux 9 amd64 build host, with Docker or Podman:

```bash
sudo bash scripts/12-build-nginx-binary.sh
```

The Dockerfile builds NGINX 1.30.6 from source with the stream module and verifies the source tarball SHA256. It exports the compiled binary to `offline/bin/nginx`.

Transfer the binary and project to each Worker, then run:

```bash
sudo bash scripts/13-install-nginx-proxy.sh
```

Docker/Podman is not required on cluster nodes.

## TLS requirements

The kube-apiserver serving certificate SAN must include IP `127.0.0.1`, all three Master IPs, `API_DNS`, and Kubernetes service DNS/IP. Since NGINX is TCP passthrough, clients validate the selected kube-apiserver certificate directly.

See [local API proxy design](docs/API-LOCAL-PROXY.md) and [automated offline Release](docs/AUTOMATED-RELEASE.md).

## Scope

This repository currently contains the endpoint-proxy integration and selected deployment scaffolding; it is not yet the complete deployment source tree. Container images and some Rocky Linux RPM dependencies must be mirrored separately. See [offline image guidance](docs/OFFLINE-IMAGES.md). Validate all generated configs in a Rocky Linux 9 staging cluster before production.
