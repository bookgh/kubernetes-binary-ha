# Automated offline Release

## Trigger from an Issue

- Put a Kubernetes version such as `v1.37.2` in the Issue title or body.
- Add the `build-offline` label.
- The workflow extracts only a strict `X.Y.Z` version token, checks that the Kubernetes binary exists upstream, downloads the pinned supporting components, verifies the official Kubernetes SHA256 files, and publishes `k8s-vX.Y.Z`.
- It refuses to overwrite an existing Release/tag.

The workflow can also be started manually from **Actions → Issue-driven offline bundle release → Run workflow**.

## Permissions

The workflow uses the repository-scoped `GITHUB_TOKEN` with `contents: write` and `issues: read`. In repository Settings → Actions → General, allow GitHub Actions to create and approve pull requests is not needed; ensure the workflow token has permission to create Releases (contents write).

## Scope and limitations

This release currently contains Kubernetes control-plane/node/client binaries, etcd, containerd, runc, CNI plugins, crictl, and Calico operator/CRD manifests for amd64. It does **not** include Rocky Linux RPM dependencies or all container images. Mirror images to an internal registry or OCI archive separately; see the deployment project's `docs/OFFLINE-IMAGES.md`. Supporting component versions are pinned in the workflow and should be reviewed before changing them.
