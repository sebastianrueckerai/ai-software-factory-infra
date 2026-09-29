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
  `litellm-deepseek`, `litellm-qwen` (key ALIBABA_CLOUD_KEY), `litellm-glm` (keys Z_AI_KEY), `signoz-root` (namespace `platform`, keys `email`, `password`: SigNoz's root login, value `SIGNOZ_ADMIN_PASSWORD` in the seed env, created by `scripts/seed-secrets.sh`; the SigNoz HelmRelease fails until it exists), `signoz-webhook` (namespaces `factory` and `platform`, key `password`: the basic auth of SigNoz's webhook channel to factoryd, which factoryd needs to boot; `scripts/seed-secrets.sh` mints it with `openssl rand -hex 30` plus a suffix that meets SigNoz's password rule (upper, lower, digit, symbol), or copies the one that exists into the namespace that lacks it), `signoz-factoryd` (namespaces `factory` and `platform`, keys `email`, `password`: factoryd's SigNoz viewer, which the `signoz-objects` job creates from the `platform` copy; seeded the same way), `signoz-s3` (namespace `platform`, key `s3.xml`: the S3 key pair `HETZNER_S3_ACCESS_KEY_ID`/`HETZNER_S3_SECRET_ACCESS_KEY` from `.env.tools` wrapped in the XML ClickHouse reads through `include_from`, created by `scripts/seed-secrets.sh`; the ClickHouse pod does not start until it exists, see Telemetry), `forgejo-secret-key` (namespace `forgejo`, the pinned Forgejo `SECRET_KEY`; a new key makes every stored Actions secret unreadable), `github-mirror` (namespace `forgejo`, key `token`: the fine-grained GitHub token of the push mirrors, the two repositories only, contents read and write, ruling 144; value `GITHUB_MIRROR_PAT` in `.env.tools`)) are imperative and stay out of the tree. In `factory`: `factory-db-creds` (keys `username`/`password`, the CNPG `gateway` role), a copy of `litellm-master-key` (key `masterkey`), and the `forgejo-registry` pull secret (username `sebastian`, the CI registry PAT, for image pulls only), `forgejo-registry-read` (key `token`: the `read:package` token of user `factory-registry-read` the roller reads main CI's images with; minted by `scripts/seed-secrets.sh`, see Rebuild step 8), `factoryd-intake` (key `token`, the bearer token for factoryd's task intake; no stored value, a re-seed generates a fresh one with `openssl rand -hex 32`), `factoryd-webhook` (key `secret`, task 42: the HMAC-SHA256 secret shared with Forgejo's webhook config for `POST /webhooks/forgejo`; value `FORGEJO_WEBHOOK_SECRET` in the seed env, because the webhook itself lives in Forgejo's database and comes back with the restore; a fresh value must be set on the webhook too), and `forgejo-ci-registrar` (key `token`, tasks 41 and 46, rulings 101 and 101a: a `write:repository` token of the dedicated Forgejo user `factory-ci` scoped to the code repository; Forgejo's repository runner API demands the repository owner, so `factory-ci` is a member of org `sf`'s Owners team, and `main`'s push and merge whitelist, which applies to admins, excludes it, so the token can neither push nor merge `main`; factoryd's CI spawner uses it to stand up the ephemeral `pr-untrusted` runner pods and its intake uses it to read the code repository's collaborators and assignee list; no stored value: the user comes back with the database restore, mint a fresh token on re-seed, never mount it into a runner pod itself), `forgejo-ci-org-read` (key `token`, ruling 108: a second `factory-ci` token with the single scope `read:organization` and no repository, because Forgejo refuses that scope on a repository-limited token; factoryd's trust gate reads org `sf`'s teams, their repositories and their members with it; no stored value: mint a fresh token on re-seed), `gateway-tool-keys` (task 52: keys `FIRECRAWL_KEY`, `REPLICATE_KEY`, `FAL_AI_KEY`, the MCP tools' provider keys, mounted by the gateway only; created from `.env.tools` without printing it: `set -a; . .env.tools; set +a; kubectl -n factory create secret generic gateway-tool-keys --from-literal=FIRECRAWL_KEY="$FIRECRAWL_KEY" --from-literal=REPLICATE_KEY="$REPLICATE_KEY" --from-literal=FAL_AI_KEY="$FAL_AI_KEY"`), `gateway-factoryd` (task 52: key `token`, the bearer the gateway presents on factoryd's `POST /internal/escalations`; both deployments mount it; no stored value, a re-seed generates a fresh one with `openssl rand -hex 32`), and `hetzner-agent` (task 53: key `token`, the API token of the Hetzner project `agent` that holds only agent-commissioned servers, firewalls and volumes; mounted by the gateway only, never by factoryd; value `HETZNER_AGENT_KEY` in `.env.tools`: `set -a; . .env.tools; set +a; kubectl -n factory create secret generic hetzner-agent --from-literal=token="$HETZNER_AGENT_KEY"`), and `hetzner-ci` (task 49, ruling 110: key `token`, the API token of the Hetzner project `ci` that holds only the throwaway PR build VMs and their firewalls; mounted by factoryd only, whose collector deletes anything in that project it does not know; value `HETZNER_CI_KEY` in `.env.tools`: `set -a; . .env.tools; set +a; kubectl -n factory create secret generic hetzner-ci --from-literal=token="$HETZNER_CI_KEY"`), and `console-oauth` (keys `client_id`, `client_secret`, `session_key`, the console's Forgejo OAuth2 app `factory-console`; not seeded: CronJob `console-oauth` in `forgejo` makes it, see Rebuild step 8) — pods cannot read secrets across namespaces, so the master key exists in `platform` and `factory` and rotation must replace both. `forgejo-pat` in `flux-system` (a copy of the bootstrap sync credentials) authenticates the `factory-code` GitRepository. The `gateway` role itself was created imperatively on `sf-cluster` (`CREATE ROLE gateway LOGIN PASSWORD ...`, value `SF_PG_GATEWAY_PASSWORD` in the seed env); CNPG's Database CR cannot create its owner role. The S3
  keys exist in four secrets — `cnpg-s3-creds` in `platform` for CNPG
  backups, `signoz-s3` in `platform` for SigNoz's cold storage,
  `hetzner-s3-creds` in `forgejo` for the nightly dump, `factory-s3-creds`
  in `factory` for the artifact store — and rotation must replace all
  four; ClickHouse reads `signoz-s3` at start, so delete pod
  `chi-signoz-clickhouse-cluster-0-0-0` after rotating it. Rotating `litellm-master-key` or
  `litellm-deepseek` also requires `kubectl -n platform rollout restart
  deployment/litellm`, because no reloader watches those secrets.

## Configuration

`factory/` is factoryd's configuration (ruling 183), read straight from
this repository's `main`; no ConfigMap, no custom resource. Git is the
editing surface, the console shows it read-only.

- `policy.yaml`: per-task default and maximum budget and the per-day cap
  over all tasks (UTC day); `limits` (`sessions`, the round cap;
  `agent_time`, the agent's working time across a task's sessions;
  `supervisor_calls` per session; `supervisor_timeout` per supervisor or
  review call, at most 15m; `stronger_after`, the returns from one stage
  that keep the model; `steps`, the model turns per agent session, 200
  when absent); the capability classes (the model aliases and
  tools a task class may use: a paid tool with per-task `max_requests`
  and `max_eur`, a free one, `escalate_to_human` and the commissioning
  tools, as `{}`; a tool no class of the task lists is refused, ruling
  132); `prices`, the tool prices no provider API reports (Firecrawl's
  EUR per credit, Replicate's EUR per second by hardware SKU and the SKU
  of each usable model, fal's megapixel bound), each with its source
  URL; `risk`, the rules that classify an agent pull request by its
  changed paths (ordered globs to a class, most severe class wins;
  `forbidden` fails the task, `requires_approval` waits for a human
  before `factory-merge` merges; `migration: true` flags schema
  migrations for the human's review); `envelope_default`, the resource
  envelope of a project whose file sets none; `project_default`, the
  quota and standing block of one that sets none (both are also caps:
  stricter wins, a project file may only tighten them, and a looser
  value or an unlisted server type rejects the commit); and
  `approvers` (ruling 128), the Forgejo users who may authorize spend in
  the console; a merge approver must also be on main's approvals
  whitelist; `link_hosts`, the hosts (with their subdomains) links in
  agent-written text factoryd posts on Forgejo may point at besides the
  Forgejo host and the project's own hosts, any other link defanged. A Replicate model runs only once it is listed under
  `prices.replicate.models`.
- `workflow.yaml`: the stages a task's work passes, in order (checks,
  screening, reproduction, policy, migration, review, approval, merge),
  each with `on_findings: agent | human | fail`, `enabled` and an
  optional `when: outsider` (ruling 177).
- `projects/<name>.yaml`: one file per project, the only place its
  settings live (rulings 146, 179, 183): repository, merge rule,
  `objects: factory | seed` (who makes the repository objects:
  factoryd's registration, or this repository and the seed; of a seed
  project factoryd keeps the labels and, for agents coder, the bot's fork,
  and only reports its webhook and namespace labels), `agents: coder | none` (`none`: every
  issue and alert goes to the human lane, `POST /tasks` answers 422),
  notify, namespaces, environments, quota, secrets, `envelope` (the task
  block) and `standing`. A seed project names the seeded secrets
  factoryd reaches it with in `tokens` (`read`, and for agents coder
  `actions` and `merge`; values `forgejo-ci-registrar`, `forgejo-merge`,
  `forgejo-config`, never `forgejo-projects`); a factory project's are
  registration's. The code repository's file lists the namespace
  `factory`, factoryd's own: that makes it the factory's own project
  (its rolls, its CI runs, the console's login). A new factory project:
  add its file, then `factoryd register-project --name <name>`. The
  console shows every project and envelope read-only with a link here.
- `schema/`: the JSON Schemas `factoryd schema --out factory/schema`
  generates from factoryd's Go types. Each YAML file's first line
  references its schema (`# yaml-language-server:
  $schema=schema/policy.schema.json`, `../schema/project.schema.json`
  under `projects/`), so an editor with the YAML language server
  completes keys, lists every enumerated value and marks mistakes.

To change it: edit, run `factoryd config check factory` (the image's
binary, or `go run ./cmd/factoryd config check <path>` in the code
repository), commit, push to main. factoryd polls the head of `main`
every 30 s with the read-only `forgejo-config` token, and records a
valid tree as an immutable `policy_versions` row keyed by the commit;
the gateway enforces the new version from Postgres within 30 s more and
names it in every audit row. A task pins the version its workflow
started under: its session cap, agent time and stronger rung, and in
every session, gate-supervisor call and model review the agent time,
`steps`, `supervisor_calls`, `supervisor_timeout` and the `no_write` detector
come from that version, and so do the activity bounds of those three.
Everything else is read from the version in force when used: the risk
rules, the factoryd model aliases, what the gateway enforces (classes,
tool caps, prices, the day cap), the budget at intake, the approvers,
the other activities' bounds and the envelope defaults. An
invalid commit (unknown key, second YAML
document, a value outside its enumeration, a missing required key, a
missing schema header, an unknown file, a `coder` class that leaves out
a model of factoryd's ladder `MODEL`, `STRONGER_MODEL`) is logged
(`CONFIG REJECTED`), the previous version stays in force, and factoryd
files one issue here per refused commit (a human-lane task, source
`config`) with an alerts row of kind `config_rejected`; the next valid
commit comments on it, closes it, ends the task and judges the alert
real. Ten failed reads in a row (a revoked `forgejo-config` token,
Forgejo unreachable; about five minutes) raise one `config_rejected`
alert of source `read`, without an issue. The workflow
`.forgejo/workflows/config-check.yml` runs the same check on every push
to main and is red for such a commit; it also fails when `schema/`
differs from what the pinned factoryd generates. It runs on the org
runner (`ubuntu-latest`): this repository is human-only, so the
privileged runner only ever runs what a human pushed to `main`, the
same trust as the code repository's main CI. Its `FACTORYD_IMAGE`
digest follows factoryd: every factoryd roll updates it (and
`factory/schema/` when the types changed). `day_eur: 0` stops all spend.
Every activation is an append-only `policy_activations` row, so the
history of what was in force when stays in Postgres. `GET /policy` on
factoryd and the console's Policy page show the version in force.

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

Run it once on a new OpenBao (Rebuild step 7 has the fresh init); after
that the raft snapshot carries the role. The CronJob's policy only reads `sys/mounts`, `sys/auth` and
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
on its volumes: factoryd's viewer account (secret `signoz-factoryd`,
role `signoz-viewer`; its login proves it, otherwise it is created or its
password reset), the webhook channel `factoryd` (POST to factoryd's
`/webhooks/signoz` with the basic auth of secret `signoz-webhook`, user
`signoz`), the dashboards in `signoz/dashboards/*.json` (by title),
the alert rules in `signoz/alerts/*.json` (by name; a file holds the rule
as SigNoz returns it, so an untouched rule compares equal), every
project's alert rules and the retention of traces, metrics and logs
through SigNoz's TTL settings API. Edits made in the UI are overwritten
on the next run.

The factory's own namespaces are projects' too (ruling 180):
`namespaces.yaml` labels `factory` for `ai-software-factory-code` (its
rules in that repository's `k8s/alerts`) and `platform` and `forgejo` for
`ai-software-factory-infra` (`signoz/project-rules`: ClickHouse disk above
80 %, a CNPG instance not ready for 5 minutes, Forgejo's 5xx rate from its
router log, and `Job failed` bound to each), each with
`factory/objects: seed`, which keeps factoryd's admission policy out of
them. The infra project is on agents none: its alerts file human-lane
issues here; the label `noise` on such an issue when it is closed makes
the alert noise, any other close by a writer real.

A project's alert rules are project code (ruling 159): a ConfigMap in its
deploy directory labelled `factory/signoz-rules: "true"`, one rule per
key in SigNoz v0.143.0's `v2alpha1` shape. The job lists these
ConfigMaps in the namespaces labelled `factory/project` (ClusterRole
`signoz-objects`: list namespaces and ConfigMaps) and binds each rule to
its namespace: every builder query's filter becomes
`(resource.k8s.namespace.name = '<ns>' OR attribute.k8s.namespace.name = '<ns>') AND (<the rule's filter>)` (Kubernetes events carry the namespace as a log attribute only), the labels
`namespace` and `project` are set from the namespace, annotation `value`
carries `{{$value}}` unless the rule sets it, and every threshold
notifies the channel `factoryd` (`usePolicy: false`). Only builder
queries and formulas on metrics, traces and logs are taken, with filters
whose brackets and quotes close within themselves and no backslash, so no
filter reaches past the bound. factoryd files a firing alert as a `bug`
issue on the project's repository, found by the label `namespace`. The
bound rule's sha256 in annotation `factory_rule_sha256` tells an
unchanged rule; a rule no ConfigMap holds any more is deleted. A refused
rule (also a second key naming an alert already taken in the namespace)
is logged and its namespace's rules stay as they are; the run does not
fail on it, since the platform's `Job failed` alert is not the project's
to answer. Edits
made in the UI to a project's rule stay until its ConfigMap changes.
SigNoz's links (`ruleSource`, the webhook's `generatorURL`) name
`https://signoz.aisoftwarefactory.world` through
`signoz_alertmanager_signoz_external__url` in the HelmRelease. The run fails, and
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
  failure; a failed Job the CronJob keeps does not hold it. It notifies
  no channel: the rule's state in SigNoz is the signal, and factoryd's
  alerts endpoint counts it for a project namespace (a project's failed
  Job holds its promotion for those 15 minutes). The rule routes by
  notification policy (`usePolicy`), because SigNoz refuses a rule that
  routes to its thresholds' channels when they list none.
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

## Home address change

Both firewalls admit the Kubernetes API (6443) and the Talos API (50000)
from the home address only: the Hetzner firewall (`home_cidr` in
`terraform.tfvars`) and the Talos `NetworkRuleConfig` `api-from-home` in
every machine config. When the home address changes, the controller is
locked out of both while git and the edge keep working. Recovery
(2026-09-29): set `home_cidr` to the new address and `tofu apply` (one
firewall change); then create a throwaway Hetzner server in the cluster's
private network (`node-mesh-tcp` admits 10.0.1.0/24) with its own SSH key
and a firewall for port 22 from the new address, copy `talos/talosconfig`
to it, and from there run `talosctl -e <node private ip> -n <same> patch
mc --mode=no-reboot --patch @patch.yaml` on each node, where the patch is a
`NetworkRuleConfig` document named `api-from-home` with the new subnet
under `ingress` (a strategic merge, so the old subnet may stay listed until
the next full apply). Delete the server, its firewall and its key.

Trap (2026-09-29, it cost the cluster): `hcloud_server.node` takes its
`user_data` from `talos/controlplane-*.yaml`, and Hetzner cannot change a
server's user data, so any edit of those files makes the next `tofu apply`
destroy and re-create the three nodes with empty disks. Never edit the
Talos config files while the cluster runs, and never apply a plan that
says anything other than "0 to add, 1 to change, 0 to destroy" for a
firewall change: read the "must be replaced" lines. Keep the home subnet
in the files equal to what the running nodes carry only through
`talosctl apply-config`, or leave the files alone until the next rebuild
and carry the subnet in `home_cidr` (`talos/README.md` regenerates the
configs from it).

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
sibling). The tree carries the pair for the next rebuild (origin `sf-cluster-v8`,
archive `sf-cluster-v9` since the Stage 9 close; v8's base backup is
20260929T074207 and its WAL archive runs to 17:52Z on 2026-09-29, the
last five minutes before the nodes were replaced, see below).

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
3. local-path, cert-manager, then, before any Certificate can be issued,
   restore the edge TLS secrets from the newest `tls/edge-tls-*.yaml` in the
   backups bucket into `forgejo` (`kubectl create -f`; `kubectl apply` would copy the private keys into the last-applied annotation): Let's Encrypt allows five
   certificates per exact name set in seven days, and the rebuilds of one week
   hit that limit once (2026-09-28, an interim certificate under another name
   set bridged it). Then the CNPG operator and plugin, `cluster.yaml`. [cert-manager's CRDs must exist before the plugin
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
   repositories from the dump's `repos/` into `/data/git/gitea-repositories`
   (a fresh volume lacks the directory: create it first).
   Without a dump (2026-09-29: the close lost the nodes first), every
   repository row stands with no bare repository behind it, and a push
   fails with "Could not read from remote repository". Forgejo has no
   command that re-creates one (`doctor`'s checks repair hooks and
   settings; "adopt" is the reverse case). For each row
   (`select u.lower_name, r.lower_name from repository r join "user" u
   on u.id = r.owner_id`): `git init --bare --initial-branch=main
   /data/git/gitea-repositories/<owner>/<name>.git` in the forgejo
   container, then `forgejo doctor check --run hooks --fix` and `--run
   enable-push-options --fix`. `fix-push-mirrors-without-git-remote --fix`
   deletes the push mirror rows (none has its remote now); CronJob
   `push-mirrors` makes them anew. The merged pull requests' refs are
   gone too, and factoryd's revert pass fails on their diffs (500):
   `git update-ref refs/pull/<index>/head <merged_commit_id>^2` in the
   bare repository for each merged row of `pull_request`. A protected
   `deploy` branch refuses every push but the deploy key's: the project's
   own main CI starts it again (`roll.sh`: "no deploy branch yet").
   Forgejo's SSH host key is new with the volume; factoryd's reconcile of
   such a project stops at "branch deploy" (500) before it sets
   `FACTORY_SSH_HOST_KEY`, so PUT that Actions secret from
   `/data/ssh/gitea.rsa.pub` by hand before the staging job runs.
5. Fast-forward push every repository from the local clones to `origin`
   NOW, before Flux's first sync. [Pushes made while Forgejo was down
   reached GitHub only; Flux otherwise converges to the dump's stale
   tree.]
6. Mint `runner-init`, `flux bootstrap` (pinned v2.9.5), let the cascade
   converge. `runner-init` is always an organisation registration token
   of `sf` (`GET /api/v1/orgs/sf/actions/runners/registration-token`),
   never an instance token: an instance runner takes every repository's
   jobs, which would put project jobs back on the privileged dind runner
   and break ruling 164's bound that a project's jobs land only on
   runners registered to its own repository. Actions secrets stay
   readable because the `SECRET_KEY` is pinned; after any key change,
   PUT them again. `runner-init` keys: `CONFIG_NAME=sf-runner`,
   `CONFIG_INSTANCE=https://git.aisoftwarefactory.world`, `CONFIG_TOKEN`.
   `flux bootstrap gitea --token-auth` takes a token in `GITEA_TOKEN`,
   not a password, and no copy of the first one is kept
   (`~/.git-credentials` holds sebastian's password): mint one, `POST
   /api/v1/users/sebastian/tokens` with scopes `read:misc` and
   `write:repository`, piped through `jq` into a mode-600 file. [flux
   prints the value it was given in its "access token does not exist"
   error: never hand it a password.]
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
   Without a snapshot of the current seed (none taken at the close, or
   one older than the tokens), start a fresh OpenBao instead (2026-09-29):
   `kubectl -n platform exec openbao-0 -- bao operator init
   -key-shares=1 -key-threshold=1 -format=json` into a mode-600 file;
   write its unseal key and root token into `.env.seed` as
   `OPENBAO_UNSEAL_KEY` and `OPENBAO_ROOT_TOKEN`, and keep the old pair
   under other names for as long as a snapshot taken under it is kept
   (it cannot be unsealed without them); shred the file; unseal with the
   new key; run `scripts/openbao-config-bootstrap.sh` with the new root
   token. It writes the engine, a new CA, both roles and both policies;
   the next `openbao-config` run logs `no change`. OpenBao holds nothing
   else, so the seed and the bootstrap are the whole restore.
8. Re-create what restores do not carry: the `factory` namespace
   secrets, `forgejo-pat` in `flux-system`, a fresh `factoryd-intake`
   token, `factoryd-webhook` from `FORGEJO_WEBHOOK_SECRET`, and a freshly
   minted `forgejo-ci-registrar` token (user `factory-ci`,
   `write:repository`, scoped to the code repository only) and a freshly
   minted `forgejo-ci-org-read` token (user `factory-ci`, scope
   `read:organization` only, no repository), a freshly minted
   `forgejo-projects` token (user `factory-projects`, `write:repository`,
   token name `factory-projects`: revoke the restored one first; factoryd
   cannot boot without it), a freshly minted
   `forgejo-config` token (user `factory-config`, a read collaborator on
   this repository only, `read:repository` limited to it: factoryd reads
   `factory/` with it and cannot boot without it, nor without a project
   file listing its own namespace `factory` (`projects/ai-software-factory-code.yaml`); `scripts/seed-secrets.sh`
   makes the user, the collaborator, the token and the secret once Forgejo
   answers, lets `factory-agent` read this repository to file the
   `config_rejected` issues, and PUTs this repository's Actions secrets
   `REGISTRY_USER` and `REGISTRY_PASSWORD` for the config check, and makes
   this repository's webhook to factoryd (issue events, the intake secret;
   factoryd reports it) and the team `factory-issues-infra` in org `sf`
   (units `repo.issues` write, `repo.code` read, set again and read back on
   every run, this repository only, member `factory-agent`; other members
   or repositories are logged, not removed): with it factoryd, as the bot,
   creates this repository's labels and sets the `state/*` labels on its
   human-lane issues; code read and `main`'s unchanged push whitelist keep
   it from pushing), and a freshly minted `forgejo-registry-read` token
   (user `factory-registry-read`, the single scope `read:package`, no
   repository; member of team `factory-registry-read` in org `sf`, whose
   one unit is `repo.packages` read on no repository, set again and read
   back on every run, since org `sf` is private and Forgejo 15 grants its
   packages to team members only; the script makes the user, the team,
   the membership, the token and the secret, key `token`; factoryd's
   roller reads main CI's images with it and cannot overwrite a tag,
   while the `forgejo-registry` pull secret serves image pulls only;
   factoryd cannot boot without it and reads it once at boot, so a
   rotation is: delete the secret, rerun the script, restart factoryd), `gateway-tool-keys`,
   `hetzner-agent` and `hetzner-ci` from `.env.tools` and a fresh
   `gateway-factoryd` token. Three CronJobs (every 10 minutes, one log
   line per run, `no change` once converged) take the rest: `console-oauth`
   in `forgejo` finds `console-oauth` missing, regenerates the client
   secret of sebastian's OAuth app `factory-console` with `PATCH
   /api/v1/user/applications/oauth2/{id}` (or creates the app), mints a
   `session_key`, writes the secret and restarts factoryd, which cannot
   start without it; `push-mirrors` in `forgejo` keeps one healthy
   push mirror to GitHub on both repositories (ruling 126, sync_on_commit,
   8 h interval) with the token from `github-mirror` (step 4's seed; until
   that secret exists the job idles and logs `push-mirrors: secret
   github-mirror missing, nothing to do`), and
   recreates a mirror whose `last_error` is a credential failure
   (`Authentication failed`, `Repository not found`, `could not read
   Username`, `Invalid username or token`, `Permission to ... denied`,
   `returned error: 401` or `403`). Any other error a new
   token cannot fix: the run logs `<mirror> left alone, sync failing:
   <first line>` and exits 0, and the mirror retries on its next sync. A
   still-valid old token never fails, so after a restore or a token
   change delete both mirrors once (Settings -> Mirror Settings); the
   next run posts them with the new token, and the Forgejo dump after
   that point carries it. A sync fails with `GH007: Your push would
   publish a private email address` until GitHub's email privacy block on
   the account is lifted or the pushed commits carry a noreply address;
   the job leaves such a mirror alone, and only the run that creates a
   mirror whose sync then fails with a credential failure or an empty
   `last_error` ends Failed (`Job failed` alert); `signoz-objects` in `platform` writes SigNoz's
   viewer account for factoryd, the webhook channel, dashboards, alert
   rules (the platform's and every project's) and retention (see
   Telemetry), which SigNoz loses with its volumes. `signoz-root` came with step 4's seed (`scripts/seed-secrets.sh`
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
