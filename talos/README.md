# Talos configs

secrets.yaml is generated per cluster and lives in the seed bundle,
never here. The generated controlplane-<N>.yaml files, worker.yaml and
talosconfig embed the cluster secrets too, so they are gitignored and
regenerated on demand from secrets.yaml, patches.yaml and node-<N>.yaml:

    talosctl gen config sf https://$(cd .. && tofu output -raw api_endpoint_ip):6443 \
      --with-secrets secrets.yaml --with-docs=false --with-examples=false \
      --config-patch-control-plane @patches.yaml --output-dir . --force
    for i in 0 1 2; do
      talosctl machineconfig patch controlplane.yaml \
        --patch @node-$i.yaml -o controlplane-$i.yaml
      talosctl validate --config controlplane-$i.yaml --mode cloud
    done

The generator always emits a KubeFlannelCNIConfig document; Talos then
runs flannel. The cluster uses Cilium, so strip that document from every
generated controlplane file after generation (the cluster has no CNI
until Task 9 installs Cilium). The generator also registers the
control-plane NoSchedule taint; Stage 1 runs control-plane nodes only,
so strip the taints block from the KubeNodeConfig document too. Config
patches cannot delete these fields: the typed patcher ignores null keys.

    python3 - << 'PY'
    for n in range(3):
        f = f'controlplane-{n}.yaml'
        docs = open(f).read().split('\n---\n')
        kept = []
        for d in docs:
            if 'kind: KubeFlannelCNIConfig' in d:
                continue
            if 'kind: KubeNodeConfig' in d:
                lines, out, skip = d.splitlines(), [], False
                for line in lines:
                    if line.startswith('taints:'):
                        skip = True
                        continue
                    if skip and (line.startswith(' ') or not line.strip()):
                        continue
                    skip = False
                    out.append(line)
                d = '\n'.join(out)
            kept.append(d)
        open(f, 'w').write('\n---\n'.join(kept))
    PY

The taint is only read at kubelet registration. A node that already
registered keeps it, so remove it by hand on live nodes:

    kubectl taint node sf-0 sf-2 node-role.kubernetes.io/control-plane:NoSchedule-

Kube-proxy is disabled at generation time (KubeProxyConfig document) so
Cilium runs kube-proxy-free and its Gateway API controller works. Each
node caps EPHEMERAL at 100 GB (VolumeConfig document; uncapped it fills
the whole disk and volumes never shrink) and carves a 200 GB user volume
at install time (UserVolumeConfig document, auto-mounted at
/var/mnt/local-path-provisioner); the local-path provisioner serves
PersistentVolumeClaims from it.

Run from this directory, with tofu initialised in the repo root.
