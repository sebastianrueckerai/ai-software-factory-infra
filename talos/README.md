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

Run from this directory, with tofu initialised in the repo root.
