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
until Task 9 installs Cilium):

    python3 - << 'PY'
    for n in range(3):
        f = f'controlplane-{n}.yaml'
        docs = open(f).read().split('\n---\n')
        kept = [d for d in docs if 'kind: KubeFlannelCNIConfig' not in d]
        open(f, 'w').write('\n---\n'.join(kept))
    PY

Run from this directory, with tofu initialised in the repo root.
