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
# the images by the linux/amd64 digests of the code repository's
# upstream-images.txt, which the store's copies carry (the chart's
# defaults are the multi-arch indexes, which the store does not hold)
cilium install --version 1.20.0 \
  --set image.digest=sha256:9a9fc73bb594bf2497955a481996c7a4ad146ee2e142152c3890dea10ad6d3c5 \
  --set operator.image.genericDigest=sha256:79e630e3f5e2344a2c352d341a619c1cb7fbe874cadcfe244edf032d62d037c2 \
  --set envoy.image.digest=sha256:070017873c423cf294b094eef9794f3670cac8df1872bd30a98f142dd6897e18 \
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
# v1.21.2 from its upstream by the digest of the code repository's
# upstream-images.txt: the store cannot serve before Forgejo runs
helm install cert-manager oci://quay.io/jetstack/charts/cert-manager@sha256:634dce9c13b56677a2c05e2ab76c312d0be2664022d5dd05815da67e1fd5f610 -n platform \
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

## 4. Forgejo and the dump restore

```sh
kubectl apply -f k8s/platform/gateway-api/edge.yaml   # Gateway programs once cilium carries the gatewayAPI flags
# extract the HelmRelease values (no yq needed):
python3 -c "
import yaml
docs = list(yaml.safe_load_all(open('k8s/platform/forgejo/helmrelease.yaml')))
hr = [d for d in docs if d['kind']=='HelmRelease'][0]
yaml.safe_dump(hr['spec']['values'], open('/tmp/forgejo-values.yaml','w'))"
# 17.1.7 from its upstream by the digest of the code repository's
# upstream-images.txt, as cert-manager above
helm install forgejo oci://code.forgejo.org/forgejo-helm/forgejo@sha256:f5044e73361f5991978f1bc281a570bf893fd0f468e7d76274a7853eb27428cf \
  -n forgejo -f /tmp/forgejo-values.yaml
```

`https://git.aisoftwarefactory.world/api/v1/version` answers 403 "Only signed
in user is allowed" for anonymous callers: the instance is private, that is
the healthy answer. Check authenticated (factory-admin, seed env) instead;
the restored database comes back with the CNPG recovery, so only `repos/`
and the SSH host keys need the dump:

```sh
kubectl -n forgejo exec deploy/forgejo -c forgejo -- mkdir -p /data/git/gitea-repositories
tar -C <dump>/repos --owner=1000 --group=1000 -cf - . |
  kubectl -n forgejo exec -i deploy/forgejo -c forgejo -- tar -xf - -C /data/git/gitea-repositories
kubectl -n forgejo exec -i deploy/forgejo -c forgejo -- sh -c 'cat > /data/ssh/gitea.rsa' < <dump>/data/ssh/gitea.rsa
kubectl -n forgejo exec -i deploy/forgejo -c forgejo -- sh -c 'cat > /data/ssh/gitea.rsa.pub' < <dump>/data/ssh/gitea.rsa.pub
kubectl -n forgejo exec deploy/forgejo -c forgejo -- chmod 600 /data/ssh/gitea.rsa
kubectl -n forgejo delete pod -l app.kubernetes.io/instance=forgejo   # serve the old SSH host key
kubectl -n forgejo exec deploy/forgejo -c forgejo -- forgejo doctor check --run hooks --fix
kubectl -n forgejo exec deploy/forgejo -c forgejo -- forgejo doctor check --run enable-push-options --fix
# never --run fix-push-mirrors-without-git-remote (README step 4)
```

## 5. Fast-forward pushes (before Flux's first sync)

Local clones are ahead of the dump; pushes made while Forgejo was down
reached GitHub only. Per repo, verify a strict fast-forward, then push:

```sh
cd ~/repos/ai-software-factory && git fetch forgejo
git rev-list --left-right --count forgejo/master...master   # 0 N, N > 0
git push forgejo master && git push origin master
cd ~/repos/ai-software-factory-code && git fetch origin
git rev-list --left-right --count origin/main...main && git push origin main
cd ~/repos/ai-software-factory-infra && git fetch origin
git rev-list --left-right --count origin/main...main && git push origin main
```

The code repo is the known case: its local main sits on the GitHub push
made during the teardown window, ahead of the dump's tree.

## 6. runner-init, flux bootstrap, coredns, seed pass 2

The store of outside images and charts (org `upstream`) comes back with
the packages bucket and the CNPG recovery. The seed's Forgejo pass writes
its pull secrets, flux-system's among them, before Flux's first sync.
Check the store; if it is empty, fill it before that sync, since the
platform, its charts and the trusted runner come from it:

```sh
set -a; . ~/repos/ai-software-factory/.env.tools; . ~/repos/ai-software-factory/.env.seed; set +a
bash scripts/seed-secrets.sh    # the Forgejo pass: org upstream, forgejo-registry, forgejo-charts
# the nodes' login to the store, for their registry mirrors (no reboot)
sh talos/registry-mirrors.sh <node0> <node1> <node2>
curl -s -u "factory-admin:$FORGEJO_FACTORY_ADMIN_PASSWORD" \
  'https://git.aisoftwarefactory.world/api/v1/packages/upstream?type=container&limit=1' | jq length   # 1: it came back
# an empty store only: the copy (crane's login for the images, the
# REGISTRY_ pair for the Helm repository)
printf %s "$FORGEJO_FACTORY_ADMIN_PASSWORD" | crane auth login git.aisoftwarefactory.world -u factory-admin --password-stdin
REGISTRY_USER=factory-admin REGISTRY_PASSWORD="$FORGEJO_FACTORY_ADMIN_PASSWORD" \
  ~/repos/ai-software-factory-code/scripts/upstream-copy ~/repos/ai-software-factory-code/upstream-images.txt
```

```sh
set -a; . ~/repos/ai-software-factory/.env.tools; . ~/repos/ai-software-factory/.env.seed; set +a
curl -s -u "factory-admin:$FORGEJO_FACTORY_ADMIN_PASSWORD" \
  'https://git.aisoftwarefactory.world/api/v1/orgs/sf/actions/runners/registration-token' | jq -r .token > /tmp/rt
kubectl -n forgejo create secret generic runner-init \
  --from-literal=CONFIG_NAME=sf-runner \
  --from-literal=CONFIG_INSTANCE=https://git.aisoftwarefactory.world \
  --from-literal=CONFIG_TOKEN="$(cat /tmp/rt)"
# [trap] org registration token of sf, never an instance token (README step 6)
kubectl -n forgejo rollout restart deploy/forgejo-runner
```

Flux PAT (factory-admin, `read:misc` + `write:repository`):

```sh
# [trap] list first and revoke any old flux-bootstrap-* token: a name that
#  already exists in the restored DB mints nothing (sha1 null, 5-byte file)
curl -s -u "factory-admin:$FORGEJO_FACTORY_ADMIN_PASSWORD" \
  'https://git.aisoftwarefactory.world/api/v1/users/factory-admin/tokens' | jq -r '.[] | "\(.id) \(.name)"'
curl -s -u "factory-admin:$FORGEJO_FACTORY_ADMIN_PASSWORD" -X POST \
  'https://git.aisoftwarefactory.world/api/v1/users/factory-admin/tokens' \
  -H 'Content-Type: application/json' \
  -d '{"name":"flux-bootstrap-<date>","scopes":["read:misc","write:repository"]}' \
  | jq -r .sha1 > /tmp/flux-token
chmod 600 /tmp/flux-token
```

```sh
export GITEA_TOKEN="$(cat /tmp/flux-token)"
flux bootstrap gitea --url=https://git.aisoftwarefactory.world/sf/ai-software-factory-infra \
  --branch=main --path=clusters/sf --token-auth
# Flux's first platform sync rolls the Forgejo release (503 for ~1 min): retry
# [trap] if the source stays suspended on a TLS handshake timeout in-cluster:
kubectl apply -f k8s/platform/coredns.yaml
kubectl -n kube-system delete pod -l k8s-app=kube-dns
#   Talos coredns carries no reload plugin: the Corefile rewrite needs the pod
#   restart, or in-cluster DNS keeps answering the public edge IP
kubectl -n flux-system annotate gitrepository/flux-system \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite   # force the retry
bash scripts/seed-secrets.sh    # pass 2
```

## 7. OpenBao snapshot

Throwaway init, ship the snapshot, restore, restart, unseal with the
original key (README step 7):

```sh
kubectl -n platform exec openbao-0 -- bao operator init -key-shares=1 -key-threshold=1 -format=json > /tmp/bao-init.json
chmod 600 /tmp/bao-init.json
RT=$(jq -r .root_token /tmp/bao-init.json)
kubectl -n platform cp <restore-dir>/openbao-*.snap openbao-0:/tmp/openbao.snap
# [trap] `kubectl exec -i -- sh -c 'cat > file'` can land a 0-byte file: use cp
printf '%s' "$RT" | kubectl -n platform exec -i openbao-0 -- \
  sh -c 'BAO_TOKEN="$(cat)" bao operator raft snapshot restore -force /tmp/openbao.snap'
kubectl -n platform delete pod openbao-0 && kubectl -n platform wait --for=Ready pod/openbao-0 --timeout=300s
set -a; . ~/repos/ai-software-factory/.env.seed; set +a
printf '%s' "$OPENBAO_UNSEAL_KEY" | kubectl -n platform exec -i openbao-0 -- \
  sh -c 'k="$(cat)"; bao operator unseal "$k"'
bash scripts/seed-secrets.sh    # pass 3: platform 27 / forgejo 19 / factory 16
```

## 8. Hand tokens, merge protections, CronJobs

```sh
# kubeconfig context: scripts expect admin@sf; talosctl may have written admin@sf-1
kubectl config rename-context admin@sf-1 admin@sf
# forgejo-pat: factory-admin read:repository token, secret the factory
# GitRepository reads; then force its first clone
curl -s -u "factory-admin:$FORGEJO_FACTORY_ADMIN_PASSWORD" -X POST \
  'https://git.aisoftwarefactory.world/api/v1/users/factory-admin/tokens' \
  -H 'Content-Type: application/json' \
  -d '{"name":"forgejo-pat-<date>","scopes":["read:repository"]}' | jq -r .sha1 > /tmp/fp
kubectl -n flux-system create secret generic forgejo-pat --from-literal=token="$(cat /tmp/fp)"
kubectl -n flux-system annotate gitrepository/factory-code \
  reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite
bash scripts/setup-factory-merge.sh    # reads back the protections exactly
```

Per-project tokens: the gateway DB rows carry token values the restore
brings back; a token revoked by hand leaves factoryd logging `access token
does not exist` per project every reconcile. Rotate every project in
factory/projects/ but the factory's own two, which hold no tokens:

```sh
for f in factory/projects/*.yaml; do
  p=$(basename "$f" .yaml)
  case $p in ai-software-factory-code|ai-software-factory-infra) continue ;; esac
  kubectl -n factory exec deploy/factoryd -- factoryd register-project --name "$p" --rotate
done
```

`openbao-config` and `signoz-objects` CronJobs fail during the sealed or
rolling window; the next 10-minute run converges (`Complete`, later runs
`no change`). The failures fire signoz webhook issues on this repository:
close them with a note once the jobs converge.

## 9. Gate, and the image pin

The first code-main CI run builds and pushes the factory images to the
fresh registry; the roll monitor then opens a roll card whose pull request
re-pins the code repo's own `k8s/*.yaml` digests. That pull request waits
on a merge approval (the repo's merge rule is human): approve it as
controller (`scripts/console-as.sh login && console-as.sh approve <id>`,
the approval request id is in the gateway DB) or every later card of the
repo queues behind the roll and stalls. A bootstrap image pushed from a
local docker cache (what the pods boot on before the first CI build) makes
the roll real, not empty: the pins move from the cache artifact to the CI
build. The infra workflow pin is not rolled by anything: edit
`.forgejo/workflows/config-check.yml` `FACTORYD_IMAGE` to the new
`factory-gateway` digest (the one the factoryd pod runs,
`kubectl -n factory get deploy factoryd -o jsonpath='{.spec.template.spec.containers[0].image}'`),
or config-check fails at `docker create` with a manifest-unknown pull.
Then the README step 9 gate: repo HEADs match both remotes, Stage 2 exit
tests, CI green on main, one task through authenticated intake to a fork
PR with checks on the untrusted runner and job-env-audit green, ledger
`spent_eur` equal to the LiteLLM key's own spend.
