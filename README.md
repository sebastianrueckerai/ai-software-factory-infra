# ai-software-factory-infra

What the cluster is: OpenTofu for Hetzner Cloud servers, Talos machine
configs, Flux-managed platform manifests. Design lives in the
ai-software-factory repo. Human-only repository, agents never write here.

## Flux layout

Flux v2.9.5 is bootstrapped against
`https://git.aisoftwarefactory.world/sf/ai-software-factory-infra`,
sync path `clusters/sf`:

- `clusters/sf/flux-system/` — Flux components and the flux-system sync,
  written by `flux bootstrap`.
- `clusters/sf/platform.yaml` — the Kustomization that owns the platform
  tree; `clusters/sf/kustomization.yaml` is the sync build root.
- `clusters/sf/factory.yaml` — the GitRepository `factory-code` (the code
  repo, secret `forgejo-pat`) and the Kustomization `factory` that applies
  the code repo's `k8s/` tree (namespace `factory`, prune on, after
  `platform`).
- `k8s/platform/` — the platform tree: chart sources, Gateway API edge,
  cert-manager and Forgejo HelmReleases, CNPG, local-path, and the
  CoreDNS Corefile. The Corefile's rewrite sends in-cluster git DNS to
  the gateway Service; prune is on, so deleting coredns.yaml from the
  tree deletes the rewrite and re-breaks the Flux sync. From here on,
  platform changes ship as commits to this tree and Flux applies them;
  nothing is applied by hand.
- Seeded secrets (`sf-cluster-superuser`, `app-secret`, `pg-*`,
  `cnpg-s3-creds`, `forgejo-admin-secret`, `forgejo-db-creds`,
  `hetzner-s3-creds`, `runner-init`, `litellm-master-key`,
  `litellm-deepseek`, `litellm-qwen` (key ALIBABA_CLOUD_KEY), `litellm-glm` (keys Z_AI_KEY), `signoz-root` (namespace `platform`, keys `email`, `password`: SigNoz's root login, value `SIGNOZ_ADMIN_PASSWORD` in the seed env, created by `scripts/seed-secrets.sh`; the SigNoz HelmRelease fails until it exists), `signoz-s3` (namespace `platform`, key `s3.xml`: the S3 key pair `HETZNER_S3_ACCESS_KEY_ID`/`HETZNER_S3_SECRET_ACCESS_KEY` from `.env.tools` wrapped in the XML ClickHouse reads through `include_from`, created by `scripts/seed-secrets.sh`; the ClickHouse pod does not start until it exists, see Telemetry), `forgejo-secret-key` (namespace `forgejo`, the pinned Forgejo `SECRET_KEY`; a new key makes every stored Actions secret unreadable), `github-mirror` (namespace `forgejo`, key `token`: the fine-grained GitHub token of the push mirrors, the two repositories only, contents read and write, ruling 144; value `GITHUB_MIRROR_PAT` in `.env.tools`)) are imperative and stay out of the tree. In `factory`: `factory-db-creds` (keys `username`/`password`, the CNPG `gateway` role), a copy of `litellm-master-key` (key `masterkey`), and the `forgejo-registry` pull secret (username `sebastian`, the CI registry PAT), `factoryd-intake` (key `token`, the bearer token for factoryd's task intake; no stored value, a re-seed generates a fresh one with `openssl rand -hex 32`), `factoryd-webhook` (key `secret`, task 42: the HMAC-SHA256 secret shared with Forgejo's webhook config for `POST /webhooks/forgejo`; value `FORGEJO_WEBHOOK_SECRET` in the seed env, because the webhook itself lives in Forgejo's database and comes back with the restore; a fresh value must be set on the webhook too), and `forgejo-ci-registrar` (key `token`, tasks 41 and 46, rulings 101 and 101a: a `write:repository` token of the dedicated Forgejo user `factory-ci` scoped to the code repository; Forgejo's repository runner API demands the repository owner, so `factory-ci` is a member of org `sf`'s Owners team, and `main`'s push and merge whitelist, which applies to admins, excludes it, so the token can neither push nor merge `main`; factoryd's CI spawner uses it to stand up the ephemeral `pr-untrusted` runner pods and its intake uses it to read the code repository's collaborators and assignee list; no stored value: the user comes back with the database restore, mint a fresh token on re-seed, never mount it into a runner pod itself), `forgejo-ci-org-read` (key `token`, ruling 108: a second `factory-ci` token with the single scope `read:organization` and no repository, because Forgejo refuses that scope on a repository-limited token; factoryd's trust gate reads org `sf`'s teams, their repositories and their members with it; no stored value: mint a fresh token on re-seed), `gateway-tool-keys` (task 52: keys `FIRECRAWL_KEY`, `REPLICATE_KEY`, `FAL_AI_KEY`, the MCP tools' provider keys, mounted by the gateway only; created from `.env.tools` without printing it: `set -a; . .env.tools; set +a; kubectl -n factory create secret generic gateway-tool-keys --from-literal=FIRECRAWL_KEY="$FIRECRAWL_KEY" --from-literal=REPLICATE_KEY="$REPLICATE_KEY" --from-literal=FAL_AI_KEY="$FAL_AI_KEY"`), `gateway-factoryd` (task 52: key `token`, the bearer the gateway presents on factoryd's `POST /internal/escalations`; both deployments mount it; no stored value, a re-seed generates a fresh one with `openssl rand -hex 32`), and `hetzner-agent` (task 53: key `token`, the API token of the Hetzner project `agent` that holds only agent-commissioned servers, firewalls and volumes; mounted by the gateway only, never by factoryd; value `HETZNER_AGENT_KEY` in `.env.tools`: `set -a; . .env.tools; set +a; kubectl -n factory create secret generic hetzner-agent --from-literal=token="$HETZNER_AGENT_KEY"`), and `hetzner-ci` (task 49, ruling 110: key `token`, the API token of the Hetzner project `ci` that holds only the throwaway PR build VMs and their firewalls; mounted by factoryd only, whose collector deletes anything in that project it does not know; value `HETZNER_CI_KEY` in `.env.tools`: `set -a; . .env.tools; set +a; kubectl -n factory create secret generic hetzner-ci --from-literal=token="$HETZNER_CI_KEY"`), and `console-oauth` (keys `client_id`, `client_secret`, `session_key`, the console's Forgejo OAuth2 app `factory-console`; not seeded: CronJob `console-oauth` in `forgejo` makes it, see Rebuild step 8) — pods cannot read secrets across namespaces, so the master key exists in `platform` and `factory` and rotation must replace both. `forgejo-pat` in `flux-system` (a copy of the bootstrap sync credentials) authenticates the `factory-code` GitRepository. The `gateway` role itself was created imperatively on `sf-cluster` (`CREATE ROLE gateway LOGIN PASSWORD ...`, value `SF_PG_GATEWAY_PASSWORD` in the seed env); CNPG's Database CR cannot create its owner role. The S3
  keys exist in four secrets — `cnpg-s3-creds` in `platform` for CNPG
  backups, `signoz-s3` in `platform` for SigNoz's cold storage,
  `hetzner-s3-creds` in `forgejo` for the nightly dump, `factory-s3-creds`
  in `factory` for the artifact store — and rotation must replace all
  four; ClickHouse reads `signoz-s3` at start, so delete pod
  `chi-signoz-clickhouse-cluster-0-0-0` after rotating it. Rotating `litellm-master-key` or
  `litellm-deepseek` also requires `kubectl -n platform rollout restart
  deployment/litellm`, because no reloader watches those secrets.

## Policy

`k8s/platform/policy/policy.yaml` is the factory's capability policy:
per-task default and maximum budget, the per-day cap over all tasks
(UTC day), the capability classes (the model aliases and tools a task
class may use: a paid tool with per-task `max_requests` and `max_eur`, a
free one, `escalate_to_human` and the commissioning tools, as `{}`; a tool
no class of the task lists is refused, ruling 132), and
`prices`, the tool prices no provider API reports (Firecrawl's EUR per
credit, Replicate's EUR per second by hardware SKU and the SKU of each
usable model, fal's megapixel bound), each with its source URL;
`risk`, the rules that classify an agent pull request by its changed
paths (ordered globs to a class, most severe class wins; `forbidden`
fails the task, `requires_approval` waits for a human before
`factory-merge` merges; `migration: true` flags schema migrations for the
human's review), and
`envelope_default`, the standard resource envelope a project's first
commissioning request copies (monthly EUR cap, server types, count,
longest lease, largest volume), and
`approvers` (ruling 128), the Forgejo users who may authorize spend in the
console (approve a resource request or a merge, edit an envelope, promote);
a merge approver must also be on main's approvals whitelist. A
Replicate model runs only once it is listed under
`prices.replicate.models`. Its `configMapGenerator` makes it ConfigMap
`factory-policy` in namespace `factory` (stable name, no hash suffix),
which factoryd mounts read-only. factoryd refuses to boot without a
`risk` section, and refuses one with unknown keys just as a live reload
does, so infra must land this ConfigMap before factoryd itself rolls.

To change policy: edit the file, commit, push. Flux applies the
ConfigMap, kubelet updates the mounted file, and factoryd, which reads it
every 30 s, records the new content as an immutable `policy_versions` row
and makes it current (log line `policy: version N loaded`); about two
minutes end to end. The gateway enforces the current version from
Postgres within 30 s more and names it in every audit row. An invalid
edit is logged (`POLICY REJECTED`) and the previous version stays in
force; unknown keys are rejected, and so is a `coder` class that leaves
out a model of factoryd's ladder (`MODEL`, `STRONGER_MODEL`). `day_eur: 0`
stops all spend. Every activation is an append-only `policy_activations`
row, so the history of what was in force when stays in Postgres. Reverting to earlier content makes that
earlier version current again. `GET /policy` on factoryd shows the version
in force.

## The merge bot (ruling 109)

An approved agent pull request is merged by factoryd's `Merge` activity as
the dedicated Forgejo user `factory-merge`, never by the agent's bot.
Forgejo enforces the human's part: `main` of `sf/ai-software-factory-code`
carries exactly this protection (branch protection `main`, set through
`PATCH /repos/sf/ai-software-factory-code/branch_protections/main`):

| field | value |
|---|---|
| `enable_push`, `enable_push_whitelist` | true |
| `push_whitelist_usernames` | `[sebastian]` |
| `enable_merge_whitelist` | true |
| `merge_whitelist_usernames` | `[sebastian, factory-merge]` |
| `enable_approvals_whitelist` | true |
| `approvals_whitelist_username` | `[sebastian]` |
| `required_approvals` | 1 |
| `apply_to_admins` | true |
| `block_on_rejected_reviews` | true |
| `dismiss_stale_approvals` | true |
| `protected_file_patterns`, `unprotected_file_patterns` | empty |
| `enable_status_check` | false |

`factory-merge` (created with the admin API, `POST /admin/users`, a random
password nobody keeps) is a `write` collaborator on the code repository
and nowhere else; its one token, named `factory-merge`, is
`write:repository` scoped to the code repository only (minted with admin
basic auth and `?sudo=factory-merge`) and lives in secret
`factory/forgejo-merge`, key `token`. Its merge is refused (405) until
sebastian's APPROVED review is on the head, which the console submits
through his own OAuth token; a new push dismisses the approval. Its push
to `main` is refused (git: "Not allowed to push to protected branch main";
contents API: 403). It cannot read the infra repository (404). A leaked
token can merge only what sebastian already approved.

`scripts/setup-factory-merge.sh` does all of this idempotently (user,
collaboration, a fresh token into the secret, the protection) and prints
the protection it left. On a rebuild the user, its collaboration and the
protection come back with Forgejo's database; run the script anyway for
the fresh token.

## Build cache

`k8s/platform/build-cache/` is the pull-request image builds' layer cache
(ruling 111): a `registry:3` Deployment and Service `build-cache:5000` in
namespace `forgejo`, plain HTTP, on a 20Gi `local-path` volume. Main CI
(the trusted dind runner) exports each image's BuildKit cache to
`cache/<image>:main` (`factory-gateway`, `opencode-worker`, `ci-runner`);
an untrusted PR runner pod copies it into a local OCI layout and streams
it to its build VM, which never reaches the cache itself. No credential
exists: the CiliumNetworkPolicy `build-cache-ingress` lets the
`forgejo-runner` pods use any method and pods in namespaces labelled
`factory.ai/ci=true` (factoryd's CI namespaces) only GET and HEAD, so a
write from a PR job answers 403; nothing else connects, and the registry
itself has no egress. The API's DELETE is off.

Each main run moves the tags and orphans the old cache's blobs: measured
at about 100 to 200 MB per main run that changes code (2026-09-28: 1.94 ->
2.15 GB over two runs, then 2.35 GB after a third; about 1.5 GB is the
three live caches). The CronJob `build-cache-gc` restarts the registry
daily at 03:30 UTC; its initContainer runs `registry garbage-collect
--delete-untagged` on the idle volume (strategy Recreate) and deletes
them, so the store holds the live caches plus one day's churn (a few GB
on a busy day). local-path does not enforce the 20Gi; the node's disk is
the hard limit.

The cache is disposable and nothing restores it: after a rebuild it is
empty, PR builds log "no cache" and build cold until the next main CI
run fills it. To empty it by hand, delete the PVC and the pod.

## OpenBao SSH CA

Commissioned servers (task 53) trust one SSH CA in OpenBao, and the
factory gateway signs sandbox keys with it.
[k8s/platform/openbao/config.sh](k8s/platform/openbao/config.sh) sets it
up idempotently: the `ssh-client-signer` engine and its CA if missing,
role `factory-agent`, policy `factory-gateway-ssh`, `auth/kubernetes/config`
and role `factory-gateway`. CronJob `openbao-config` in `platform` runs it
every 10 minutes and logs one line, `openbao-config: wrote <paths>` or
`openbao-config: no change`; a run while OpenBao is sealed fails and the
next one succeeds. It logs in as Kubernetes auth role `openbao-config`
(ServiceAccount `openbao-config` in `platform`, audience `openbao`), whose
policy reaches only the paths the script writes: reads of `sys/auth`,
`sys/mounts` and `ssh-client-signer/config/ca`, read and write on
`ssh-client-signer/roles/factory-agent`, and read and write on
`sys/policies/acl/factory-gateway-ssh`, `auth/kubernetes/config` and
`auth/kubernetes/role/factory-gateway` with every parameter pinned by
`allowed_parameters` to the value config.sh writes. Anything else answers
403: another policy text, another ServiceAccount, audience or policy on
the gateway role, another `kubernetes_host`, a new CA, its own role and
policy. Unpinned, the identity could rewrite `factory-gateway-ssh` to
`path "*"` and bind role `factory-gateway` to itself. The root token
never enters the cluster:
[scripts/openbao-config-bootstrap.sh](scripts/openbao-config-bootstrap.sh)
runs config.sh in `openbao-0` with the root token and then writes role
and policy `openbao-config`, the token passed over stdin and never
printed:

    set -a; . ~/repos/ai-software-factory/.env.seed; set +a
    BAO_TOKEN="$OPENBAO_ROOT_TOKEN" scripts/openbao-config-bootstrap.sh

Run it once on a new OpenBao; after that the raft snapshot carries the
role. The CronJob's policy only reads `sys/mounts`, `sys/auth` and
`ssh-client-signer/config/ca`, so enabling the engine or the auth method,
and generating the CA, is the bootstrap's job. config.sh generates a CA
only on OpenBao's exact "no default issuer currently configured" answer
and fails the run on any other read error: a second write to `config/ca`
makes a new CA the default and locks out every running agent server.

The engine at `ssh-client-signer` holds an ed25519 CA; its public key is
served unauthenticated at `/v1/ssh-client-signer/public_key`. Role
`factory-agent` signs user certificates, at most 30 minutes, extension
`permit-pty` only. A certificate opens one server (ruling 125): the
gateway signs for principal `resource-<row id>` of the task's own server,
and that server's cloud-init lists exactly that principal in
`AuthorizedPrincipalsFile` for root. OpenBao 2.6.3's `allowed_users`
takes no glob (`resource-*` refuses `resource-5`, with or without
`allowed_users_template`, verified 2026-09-28), so the role allows any
principal (`*`). Ruling 125 as amended: the binding is the server's
`AuthorizedPrincipalsFile` plus the gateway signing only for the task's
own server. Checked live on 2.6.3 (2026-09-28) with the gateway's login:
a request that omits `valid_principals` is signed for `unassigned`
(`default_user`), and one that sends `valid_principals=""` is signed with
no principals ("Principals: (none)"; `allow_empty_principals` false does
not stop it). sshd refuses both: neither matches the server's principals
file. The gateway always sends the server's principal.
Kubernetes auth role `factory-gateway` admits the `factory-gateway`
ServiceAccount in `factory` only, with audience `openbao` (the gateway
mounts a projected token with that audience; OpenBao reviews it with its
own ServiceAccount, bound to `system:auth-delegator` by the chart), and
its policy `factory-gateway-ssh` may only sign with `factory-agent`:
reading the role, longer TTLs and CA changes answer 400 or 403. The
role must carry `audience=openbao` whenever a gateway with that token
runs: OpenBao refuses its login otherwise, and commissioning and signing
fail. A change of the audience goes into config.sh and into the pinned
values of the bootstrap's policy in the same infra commit as the roll
that changes the token; run the bootstrap once for the new policy, then
check with one signing. OpenBao
is reached over plain HTTP inside the cluster: Cilium's WireGuard
encrypts pod traffic between nodes.
All of it lives in the raft storage, so the snapshot carries it.

## Telemetry

SigNoz (`k8s/platform/signoz/`, chart 0.143.0) is the one telemetry
store. Two collectors of the `k8s-infra` chart (0.17.1, HelmRelease in
`k8s/platform/k8s-infra/`) feed its collector
`signoz-otel-collector.platform` on OTLP HTTP (4318), from namespace
`k8s-infra` (Pod Security `privileged`: the agent mounts host paths,
which the cluster's baseline profile forbids elsewhere):

- `otel-agent`, a DaemonSet: host metrics (CPU, memory, load, disk I/O,
  read from `/proc`; the host's root filesystem is not mounted), kubelet
  stats (node, pod, container and volume, node network and filesystem
  included) and container log lines, read from `/var/log/pods` as uid 0
  without capabilities. It receives nothing (no OTLP receiver, no host
  port). Its ClusterRole reads pods, namespaces, nodes, volumes,
  ReplicaSets and Jobs, and the kubelet's `nodes/stats` and `nodes/pods`;
  no `nodes/proxy`, which would allow exec into any pod on the node.
  Log files it never opens:
  - the agent sandboxes `factory-agents-*` (CI included): an agent's
    transcript must not land in SigNoz;
  - the trusted runner `forgejo-runner` in `forgejo`: it echoes every
    job step's output, and a value a step prints without a mask would
    get a second copy here; Forgejo's Actions log keeps it;
  - SigNoz's own pods and `k8s-infra` itself: every insert would log
    lines that are inserted next.
- `otel-deployment`, one replica: cluster metrics from the Kubernetes API
  (pod phases, node conditions, Job counts, ...) and the Kubernetes
  events as logs (reason in attribute `k8s.event.reason`, namespace in
  `k8s.namespace.name`, the object in resource attributes
  `k8s.object.kind` and `k8s.object.name`, the message as body).

CiliumNetworkPolicies `otel-agent` and `otel-deployment` admit their
egress only to DNS, the API server, SigNoz's collector and, for the
agent, its own node's kubelet (10250); neither admits ingress.

CronJob `signoz-objects` in `platform` (every 10 minutes, one log line
per object, `no change` once converged) writes into SigNoz what it keeps
on its volumes: the dashboards in `signoz/dashboards/*.json` (by title),
the alert rules in `signoz/alerts/*.json` (by name; a file holds the rule
as SigNoz returns it, so an untouched rule compares equal) and the
retention of traces, metrics and logs through SigNoz's TTL settings API.
Edits made in the UI are overwritten on the next run. The run fails, and
so fires the alert below, when SigNoz records a retention set as failed
(it is set again) or still pending ten minutes on: a SigNoz restart in
the middle of a set leaves a row that SigNoz never ages out, and it
refuses every later set. Recovery: delete that row, then the next run
sets the TTL:
`kubectl -n platform debug -it signoz-0 --image=alpine --target=signoz`,
then `apk add sqlite && sqlite3 /proc/1/root/var/lib/signoz/signoz.db
"DELETE FROM ttl_setting WHERE status = 'pending'"`.

- Alert rule `Job failed` (ruling 160): the Job controller's Warning
  event `BackoffLimitExceeded` or `DeadlineExceeded` on a Job, a CronJob
  run included, at least once in the last 15 minutes, per namespace and
  Job name, severity `warning`. It clears by itself 15 minutes after the
  failure; a failed Job the CronJob keeps does not hold it. No
  notification channel yet: the rule's state in SigNoz is the signal.
  The rule routes by notification policy (`usePolicy`), because SigNoz
  refuses a rule that routes to its thresholds' channels when they list
  none.
- Retention: 7 days hot on ClickHouse's local-path volume, then moved to
  volume `s3` (disk `s3`, bucket `signoz-cold` on
  `fsn1.your-objectstorage.com`, prefix `data/`), deleted after 30 days
  (`HOT_DAYS`, `RETENTION_DAYS` in `signoz/objects.yaml`). A TTL change
  applies to parts written after it, so the first objects reach the
  bucket 7 days after a rebuild or a change. ClickHouse's
  `config.d/storage.xml` in the SigNoz HelmRelease defines the disk and
  the storage policy `tiered`; the key pair comes from secret `signoz-s3`
  through `include_from`, so it lands in no ConfigMap and no custom
  resource, and `hide_in_preprocessed` keeps it out of the preprocessed
  config on the data volume. Once the local volume is 90 % full, the
  oldest parts move to S3 early. The disk skips its access check, so
  ClickHouse starts even when the bucket is unreachable or the key wrong;
  parts then stay local, and a full 20 Gi volume stops every insert
  (ClickHouse's log names the failed moves). ClickHouse keeps the S3
  disk's metadata on the local volume, so after a rebuild the bucket's
  objects belong to nobody: the bucket's lifecycle rule (expire after 31
  days) removes them. For logs, SigNoz reports the retention from its own
  database, not from ClickHouse: if ClickHouse's volume alone is lost,
  the job says `no change` while ClickHouse runs its defaults. Then run
  the recovery above with `DELETE FROM ttl_setting`: the next run sets
  all three again.

The rebuild needs: bucket `signoz-cold` with that lifecycle rule, and
secret `signoz-s3` seeded (step 4) before the SigNoz HelmRelease rolls
ClickHouse. Everything else converges by itself.

## Cilium stays outside Flux

Cilium is the substrate Flux itself runs over, and its upgrades are
coupled to Talos (a Cilium upgrade rewrites the KubePrism endpoint
values). It is installed and upgraded imperatively alongside Talos and
deliberately not in the Flux tree, so no sync can break the network the
sync depends on.

## Rebuild

The cluster is disposable. `tofu destroy` is the off-switch, and this is
the way back. Every step below was run at least twice (Stage 3 drill,
Stage 5 rebuild); the traps in brackets each cost hours once. The
detailed commands live in the design repo's plan (Stages 1 and 2 tasks,
Stage 3 outline) and in the ledger.

Before a destroy that must keep Postgres state: a completed CNPG
`Backup` of the live generation, a WAL switch, an OpenBao raft snapshot,
a Forgejo dump, `flux suspend kustomization --all`, and the two-line edit
in `k8s/platform/cnpg/cluster.yaml` (recovery origin = the newest
generation with a completed base backup, live archive = the next unused
sibling). The tree already carries origin `sf-cluster-v4` and archive
`sf-cluster-v5` for the next rebuild.

1. A destroy releases the primary IPs, so first
   `tofu apply -target=hcloud_primary_ip.node`, point the `git` DDNS
   record at the new node-0 address (Namecheap DDNS password in the seed
   env), and regenerate the Talos configs per `talos/README.md` with the
   new API endpoint. Then the full `tofu apply`, and write `tofu output
   node_public_ips` (comma-separated) into
   `k8s/platform/cluster-facts/configmap.yaml` and commit it (ruling 112:
   the build VMs' firewall admits only these sources; a stale list makes
   every PR image build time out). The image selector
   requires the `schematic` label, so only the gVisor snapshot from
   `talos/build-snapshot.sh` can boot. Wait for the nodes, `talosctl
   bootstrap`, fetch the kubeconfig (strip stale `sf*` entries first).
   [Nodes installed from the schematic image register with the
   control-plane taint: remove it from all three.]
2. Cilium, imperatively (see above). The connectivity suite is optional;
   its one known failure is the node-to-node DNS check.
3. local-path, cert-manager, then the CNPG operator and plugin,
   `cluster.yaml`. [cert-manager's CRDs must exist before the plugin
   manifest applies: it carries a Certificate and an Issuer for its own
   webhook, and applying the plugin first drops them silently, leaves
   the plugin pod ContainerCreating and the Cluster reporting an unknown
   plugin. Re-apply the plugin manifest once cert-manager is up. Cost
   about six minutes in the drill.] The recovery runs from the origin
   generation. [Origin and archive must differ, or the plugin refuses
   with an empty-archive error.] Apply the four Database CRs.
4. The bootstrap slice by hand: namespaces, every seeded secret from the
   list above (`forgejo-secret-key` first; `scripts/seed-secrets.sh`
   creates the missing ones from `.env.tools` and `.env.seed` without
   printing a value and leaves existing ones alone, so it also adds a
   new secret to a running cluster; to replace a secret, delete it and
   run it again), Forgejo. Restore the
   repositories from the dump's `repos/` into `gitea-repositories`.
5. Fast-forward push every repository from the local clones to `origin`
   NOW, before Flux's first sync. [Pushes made while Forgejo was down
   reached GitHub only; Flux otherwise converges to the dump's stale
   tree.]
6. Mint `runner-init`, `flux bootstrap` (pinned v2.9.5), let the cascade
   converge. Actions secrets stay readable because the `SECRET_KEY` is
   pinned; after any key change, PUT them again.
7. OpenBao: throwaway init, ship the snapshot, `bao operator raft
   snapshot restore -force`, restart, unseal with the original key. The
   unseal is the one hand step left: the unseal key is the root of
   trust, and auto-unseal needs a key service we do not run. The
   snapshot carries the SSH CA (its signing key too), the gateway's
   Kubernetes auth and role `openbao-config`. Within 10 minutes of the
   unseal CronJob `openbao-config` logs `no change` or the paths it
   rewrote (`kubectl -n platform logs job/<newest openbao-config job>`).
   If its login fails instead, run `scripts/openbao-config-bootstrap.sh`
   once ("OpenBao SSH CA" above). A new CA key needs nothing else:
   servers read it at creation.
8. Re-create what restores do not carry: the `factory` namespace
   secrets, `forgejo-pat` in `flux-system`, a fresh `factoryd-intake`
   token, `factoryd-webhook` from `FORGEJO_WEBHOOK_SECRET`, and a freshly
   minted `forgejo-ci-registrar` token (user `factory-ci`,
   `write:repository`, scoped to the code repository only) and a freshly
   minted `forgejo-ci-org-read` token (user `factory-ci`, scope
   `read:organization` only, no repository), `gateway-tool-keys`,
   `hetzner-agent` and `hetzner-ci` from `.env.tools` and a fresh
   `gateway-factoryd` token. Three CronJobs (every 10 minutes, one log
   line per run, `no change` once converged) take the rest: `console-oauth`
   in `forgejo` finds `console-oauth` missing, regenerates the client
   secret of sebastian's OAuth app `factory-console` with `PATCH
   /api/v1/user/applications/oauth2/{id}` (or creates the app), mints a
   `session_key`, writes the secret and restarts factoryd, which cannot
   start without it; `push-mirrors` in `forgejo` keeps one healthy
   push mirror to GitHub on both repositories (ruling 126, sync_on_commit,
   8 h interval) with the token from `github-mirror` (step 4's seed), and
   recreates a mirror whose `last_error` is set. A mirror is recreated
   only once its sync fails, so after a token change revoke the old token
   or delete both mirrors once (Settings -> Mirror Settings); the next run
   posts them with the new token, and the Forgejo dump after that point
   carries it; `signoz-objects` in `platform` writes SigNoz's
   dashboards, alert rules and retention (see Telemetry), which SigNoz
   loses with its volumes. `signoz-root` came with step 4's seed (`scripts/seed-secrets.sh`
   from `SIGNOZ_ADMIN_PASSWORD`); create it now if SigNoz's HelmRelease
   reports it missing. Check that ConfigMap `cluster-facts`
   (namespace `factory`, key `node_public_ips`) carries the new node
   IPv4s from step 1; factoryd (build VM firewalls, the CI collector's
   interlock) and the gateway (commissioned servers' firewalls, the agent
   collector's interlock) read it only at boot, so restart both after a
   late fix. PUT the Actions secret
   `REGISTRY_PASSWORD` (value `FORGEJO_CI_REGISTRY_PAT`) again if the
   `SECRET_KEY` changed. Check what the database restore should have
   brought back, and create it only if missing: the `gateway` role, the
   `factory-agent` bot as a write collaborator on the code repository,
   the `factory-ci` user in org `sf`'s Owners team (Forgejo's repository
   runner API demands the owner; rulings 101 and 101a), the code
   repository's webhook to factoryd (task
   42, all issue and pull-request events, JSON), the `factory-merge` user
   as a write collaborator on the code repository, and `main`'s branch
   protection exactly as in "The merge bot" below. Mint `factory-merge` a
   fresh token into `forgejo-merge` either way (the old one is not in any
   restore): `scripts/setup-factory-merge.sh`.
   factoryd itself recreates, at boot, the issue labels (`agent`,
   `human`, `state/*`, `priority/*`, `severity/*`) and the bot's private fork
   `factory-agent/ai-software-factory-code` that agent PRs come from
   (ruling 97).
9. Gate: every restored repository's HEAD matches the last pushed commit
   on both Forgejo and GitHub, the Stage 2 exit tests pass, CI on `main`
   is green, and one task through the authenticated intake runs to a
   fork PR whose checks run on the untrusted runner: the workflow
   completes with `job-env-audit` green (the job token's push refused).
   [The CI, build and sandbox egress allowlists must admit
   `storage.googleapis.com` by name (ruling 114): the Go module proxy
   redirects downloads there, and a fork PR's build fails without it.]
   Merged by the human, the task ends `done` and Finish deletes the fork
   branch. The ledger's `spent_eur` must equal the LiteLLM key's own
   recorded spend.

Budget about five hours.

## Push ritual

After every task commit:

    git push origin main && git push github main

Forgejo (`origin`) is primary and is what Flux reads; GitHub (`github`)
is the off-site backup.
