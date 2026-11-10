# Offline container image workflow

The binaries/RPM preparation script does not guess all transitive image dependencies.
The operator, Calico node, kube-controllers, CoreDNS, pause, and any metrics/CSI/storage
images must be mirrored and imported explicitly.

Recommended procedure on a connected staging host:
1. Install `skopeo` or `podman` and containerd tooling.
2. Render the exact Calico operator manifests for the selected release.
3. Extract every image reference from the rendered manifests and CRDs/operator defaults.
4. Pull each image for `linux/amd64`.
5. Retag to the internal registry and push to the air-gapped registry, OR export OCI archives.
6. Generate a digest lock file and SHA256SUMS.
7. On the isolated side, import OCI archives with `ctr -n k8s.io images import`.
8. Configure containerd registry mirrors and imagePullSecrets if needed.

Minimum image families:
- registry.k8s.io/pause (match containerd sandbox_image)
- quay.io/tigera/operator
- docker.io/calico/node
- docker.io/calico/cni
- docker.io/calico/kube-controllers
- registry.k8s.io/coredns/coredns

Do not assume a static image list remains correct across Calico patch releases. Inspect exact
rendered manifests and operator image defaults. Prefer digest-pinned images.
