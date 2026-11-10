# Kubernetes Binary HA

Rocky Linux 9 / amd64, Kubernetes v1.37.2 binary high-availability deployment baseline. No kubeadm.

## Repository contents

- `.github/workflows/issue-offline-release.yml`: Issue-driven offline artifact Release workflow.
- `config/cluster.env.example`: sample topology and component versions.
- `scripts/lib.sh`, `scripts/01-prepare-offline.sh`: shared helpers and online staging artifact downloader.
- `docs/`: offline image guidance, production acceptance checklist, and Release workflow instructions.

**Deployment source completeness:** the full generated project archive contains additional node installation scripts, manifests, systemd units, HAProxy/Keepalived configuration, PKI and kubeconfig helpers. Those remaining files have not yet been committed to this repository. The local generated archive is not a GitHub-hosted download.

## Build offline assets from an Issue

1. Create a repository label named `build-offline` (GitHub → Issues → Labels).
2. Open an Issue whose title or body contains a Kubernetes version such as `v1.37.2`.
3. Add the `build-offline` label.
4. GitHub Actions extracts a strict semantic version token, checks that the Kubernetes binary exists upstream, downloads the pinned supporting artifacts, verifies Kubernetes SHA256 files, and creates a Release named `k8s-vVERSION`.
5. The Release includes an amd64 archive and SHA256 checksum.

You can also start the workflow manually from **Actions → Issue-driven offline bundle release → Run workflow**.

The workflow does not execute Issue text. Existing Release tags are never overwritten.

## Scope and safety

The automated Release includes Kubernetes control-plane/node/client binaries, etcd, containerd, runc, CNI plugins, crictl, and Calico operator/CRD manifests. It does not include Rocky Linux RPM dependencies or all container images. Mirror images to an internal registry or OCI archive separately; see `docs/OFFLINE-IMAGES.md`.

This is a deployment baseline, not a production-certified installer. Review network values, image dependencies, PKI/RBAC, firewall rules, and the acceptance checklist before use.
