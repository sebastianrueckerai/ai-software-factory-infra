# Talos configs

secrets.yaml is generated per cluster and lives in the seed bundle,
never here. The generated controlplane-<N>.yaml files, worker.yaml and
talosconfig embed the cluster secrets too, so they are gitignored and
regenerated on demand from secrets.yaml, patches.yaml, node-<N>.yaml and
the home_cidr of terraform.tfvars, which the API firewall rule allowlists:

    sed "s|HOME_CIDR|$(sed -n 's/^home_cidr *= *"\(.*\)"/\1/p' ../terraform.tfvars)|" \
      patches.yaml > patches.local.yaml
    talosctl gen config sf https://$(cd .. && tofu output -raw api_endpoint_ip):6443 \
      --with-secrets secrets.yaml --with-docs=false --with-examples=false \
      --config-patch-control-plane @patches.local.yaml --output-dir . --force
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
node caps EPHEMERAL at 200 GB (VolumeConfig document; uncapped it fills
the whole disk and volumes never shrink) and carves a 100 GB user volume
at install time (UserVolumeConfig document, auto-mounted at
/var/mnt/local-path-provisioner, noexec); the local-path provisioner serves
PersistentVolumeClaims of class `local-path` from it. Class `factory-cache`
lives under /var/lib/factory-cache on EPHEMERAL, which is not noexec, since
its caches hold executables. The RegistryMirrorConfig documents pull
outside images from the factory's store first; the store's login is no
part of these files, `registry-mirrors.sh` patches it into the running
nodes (the root README, "The store of outside images").

Run from this directory, with tofu initialised in the repo root.

## Node image

The servers boot a Hetzner snapshot of the Talos Image Factory image for
`schematic.yaml` (stock Talos plus the gVisor extension; schematic ID
d9ff89777e246792e7642abd3220a616afb4e49822382e4213a2e528ab826fe5). An
in-place `talosctl upgrade` cannot add extensions, so a new extension set
means a new snapshot and a server re-lay. `main.tf` selects the snapshot
by labels, including `schematic=<first 16 chars of the ID>` (Hetzner label
values stop at 63 characters), so an older gVisor-less snapshot is never
picked.

Build it with:

    set -a; source ../../ai-software-factory/.env.tools; set +a
    HCLOUD_TOKEN=$HETZNER_KEY ./build-snapshot.sh

The script downloads the image locally and verifies it with `xz -t`,
creates a throwaway key, SSH-only firewall and cx23 server, boots a fresh
rescue system, streams the image over ssh onto /dev/sda, powers off via
sysrq, snapshots with the labels `os`, `version`, `arch` and `schematic`,
and tears everything down on exit. Two rules come from failed builds:
never download the image inside the rescue system, and never reuse a
rescue that has already streamed an image (it wedges).
