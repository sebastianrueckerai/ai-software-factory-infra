# Re-seed runbook

The executable companion to README's "Rebuild": the exact commands of one
re-seed, in order, each one as it was run. The README carries the reasoning
and the traps; this file carries the command lines, so the next restart does
not re-derive them from the ledger. Written during the 2026-10-13 re-seed,
every command verified by that run. Fill in `<new-ip>` values as you go.

Conventions: infra repo root is `~/repos/ai-software-factory-infra`, the
secrets env is `~/repos/ai-software-factory/.env.tools` and `.env.seed`
(sourced in the same command, never printed), and every talosctl call passes
`--talosconfig` explicitly (`~/.talos/config` can shadow the local one).

## 1. Substrate

```sh
tofu apply -target=hcloud_primary_ip.node -auto-approve   # reserves 3 IPs
tofu output api_endpoint_ip                               # new node-0 address
# DDNS: point git, console, signoz at it (x10.mx is dead; see README step 1)
set -a; . ~/repos/ai-software-factory/.env.tools; set +a
for h in git console signoz; do
  curl -sS "https://dynamicdns.park-your-domain.com/update?domain=aisoftwarefactory.world&password=$NAMECHEAP_DDNS_PASSWORD&host=$h&ip=<new-ip>"
done   # each answers ErrCount 0 / Done true / the IP
```

```sh
cd talos
talosctl gen config sf https://<new-ip>:6443 --with-secrets secrets.yaml \
  --with-docs=false --with-examples=false --config-patch-control-plane @patches.yaml \
  --output-dir . --force
for i in 0 1 2; do
  talosctl machineconfig patch controlplane.yaml --patch @node-$i.yaml -o controlplane-$i.yaml
  talosctl validate --config controlplane-$i.yaml --mode cloud
done
# strip the flannel document + control-plane taints (script in talos/README.md), revalidate
```

```sh
cd .. && tofu apply -auto-approve    # network, firewall, 3 servers (~4 min)
tofu output node_public_ips
# edit k8s/platform/cluster-facts/configmap.yaml ONLY if the set changed; commit then
# BEFORE the CNPG step: check cluster.yaml's recovery pair (origin = generation
# of the newest completed base backup in the bucket, archive = next sibling).
# The close's edit is easy to miss; verify with:
aws s3 ls s3://aisoftwarefactory-backups/cnpg/sf-cluster/          # generations
aws s3 ls s3://aisoftwarefactory-backups/cnpg/sf-cluster/<gen>/base/
```

```sh
cd talos && export TALOSCONFIG=./talosconfig
talosctl -e <node0> -n <node0> bootstrap       # etcd forms; can take 10+ min
kubectl config delete-context admin@sf 2>/dev/null; kubectl config delete-cluster sf 2>/dev/null
talosctl -e <node0> -n <node0> kubeconfig .    # then kubectl apply the merged file
kubectl get nodes                              # three Ready (up to ~15 min)
```

## 2. CNI

See README step 2 (Cilium imperatively, full Ruling-47 flag set).

## 3. Storage, certs, Postgres

See README step 3 (local-path, cert-manager, edge TLS from the bucket, CNPG
operator/plugin/cluster/databases; the plugin must follow cert-manager).

## 4-9

See README steps 4 to 9 (bootstrap slice, Forgejo dump restore, fast-forward
pushes, runner-init + flux bootstrap, OpenBao snapshot, hand tokens, gate).
