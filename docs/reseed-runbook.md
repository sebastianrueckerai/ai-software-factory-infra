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

Gateway API CRDs first (Ruling 46), then Cilium with the full flag set
(Ruling 47; the gatewayAPI and envoy flags are the ones the 2026-10-13
morning re-seed forgot and paid for twice):

```sh
kubectl apply --server-side -f k8s/platform/gateway-api/crds.yaml
cilium install --version 1.20.0 \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=localhost \
  --set k8sServicePort=7445 \
  --set 'securityContext.capabilities.ciliumAgent={CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}' \
  --set 'securityContext.capabilities.cleanCiliumState={NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}' \
  --set cgroup.autoMount.enabled=false \
  --set cgroup.hostRoot=/sys/fs/cgroup \
  --set encryption.enabled=true \
  --set encryption.type=wireguard \
  --set gatewayAPI.enabled=true \
  --set gatewayAPI.hostNetwork.enabled=true \
  --set envoy.securityContext.capabilities.keepCapNetBindService=true \
  --set 'envoy.securityContext.capabilities.envoy={NET_ADMIN,SYS_ADMIN,NET_BIND_SERVICE}'
cilium status --wait
```

Expected: cilium 3/3, cilium-envoy 3/3, operator 1/1, no kube-proxy
DaemonSet, GatewayClass `cilium` accepted. k8sServiceHost is the KubePrism
loopback, never a node address; kubeProxyReplacement must stay true. The
connectivity suite is optional (known failure: node-to-node DNS).

## 3. Storage, certs, Postgres

```sh
kubectl apply -f k8s/platform/namespaces.yaml
kubectl apply -k k8s/platform/local-path
kubectl -n local-path-storage wait --for=condition=Available deployment/local-path-provisioner --timeout=180s
helm install cert-manager jetstack/cert-manager -n platform --version v1.21.2 \
  --set crds.enabled=true --set config.gatewayAPI.enabled=true
kubectl -n platform wait --for=condition=Available deployment/cert-manager --timeout=300s
kubectl -n platform wait --for=condition=Available deployment/cert-manager-webhook --timeout=300s
kubectl create -f /tmp/<restore-dir>/edge-tls-*.yaml   # create, never apply (README step 3)
set -a; . ~/repos/ai-software-factory/.env.tools; . ~/repos/ai-software-factory/.env.seed; set +a
bash scripts/seed-secrets.sh     # pass 1: cnpg-s3-creds must exist before cluster recovery
```

Seed pass 1 ends with `platform: 15 secrets / forgejo: 8 / factory: 12`; the
OpenBao and Forgejo passes skip (`run this script again after step 6/7`).

```sh
kubectl apply --server-side -f k8s/platform/cnpg/operator.yaml
# [trap, 2026-10-13: plain apply fails "metadata.annotations: Too long" on the
#  CRDs; if a plain apply already ran, re-apply server-side and ignore field
#  conflicts on the deployment/webhooks it had created]
kubectl -n cnpg-system wait --for=condition=Available deployment/cnpg-controller-manager --timeout=420s
kubectl apply --server-side -f k8s/platform/cnpg/plugin-barman-cloud.yaml   # after cert-manager (README)
kubectl apply -f k8s/platform/cnpg/objectstore.yaml
kubectl apply -f k8s/platform/cnpg/cluster.yaml    # recovery; ~10 min to healthy
kubectl apply -f k8s/platform/cnpg/databases.yaml
```

Watch: `kubectl -n platform get cluster sf-cluster -o jsonpath='{.status.phase}'`
until `Cluster in healthy state`, then one primary + two replicas Running.

## 4-9

See README steps 4 to 9 (bootstrap slice, Forgejo dump restore, fast-forward
pushes, runner-init + flux bootstrap, OpenBao snapshot, hand tokens, gate).
