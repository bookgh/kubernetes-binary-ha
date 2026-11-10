# Kubernetes Binary HA

Rocky Linux 9 / amd64, Kubernetes v1.37.2 binary high-availability deployment baseline. No kubeadm.

The complete source tree is distributed in [kubernetes-binary-ha-rocky9-v1.37.2.zip](./kubernetes-binary-ha-rocky9-v1.37.2.zip). Extract it before following the runbook.

## Build offline assets from an Issue

1. Open an Issue whose title or body contains a Kubernetes version such as `v1.37.2`.
2. Add the `build-offline` label.
3. GitHub Actions validates the version, downloads the matching upstream artifacts, verifies Kubernetes SHA256 files, and creates a Release named `k8s-vVERSION`.
4. The Release includes an amd64 archive, SHA256SUMS, and a component manifest.

The workflow only accepts semantic versions and does not execute Issue text. Releases are immutable: an existing tag is not overwritten.

## Important

The deployment project is a baseline, not a production-certified installer. Review site-specific network values, image dependencies, PKI/RBAC, firewall rules and the production checklist in the source archive. The current artifact script does not mirror all container images; see `docs/OFFLINE-IMAGES.md` in the source tree.

## Repository layout

The ZIP contains `config/`, `docs/`, `manifests/`, `scripts/`, and `systemd/`.
