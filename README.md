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
  `litellm-deepseek`, `litellm-qwen` (key ALIBABA_CLOUD_KEY), `litellm-glm` (keys Z_AI_KEY), `forgejo-secret-key` (namespace `forgejo`, the pinned Forgejo `SECRET_KEY`; a new key makes every stored Actions secret unreadable)) are imperative and stay out of the tree. In `factory`: `factory-db-creds` (keys `username`/`password`, the CNPG `gateway` role), a copy of `litellm-master-key` (key `masterkey`), and the `forgejo-registry` pull secret (username `sebastian`, the CI registry PAT), `factoryd-intake` (key `token`, the bearer token for factoryd's task intake; no stored value, a re-seed generates a fresh one with `openssl rand -hex 32`), `factoryd-webhook` (key `secret`, task 42: the HMAC-SHA256 secret shared with Forgejo's webhook config for `POST /webhooks/forgejo`; value `FORGEJO_WEBHOOK_SECRET` in the seed env, because the webhook itself lives in Forgejo's database and comes back with the restore; a fresh value must be set on the webhook too), and `forgejo-ci-registrar` (key `token`, tasks 41 and 46, rulings 101 and 101a: a `write:repository` token of the dedicated Forgejo user `factory-ci` scoped to the code repository; Forgejo's repository runner API demands the repository owner, so `factory-ci` is a member of org `sf`'s Owners team, and `main`'s push and merge whitelist, which applies to admins, excludes it, so the token can neither push nor merge `main`; factoryd's CI spawner uses it to stand up the ephemeral `pr-untrusted` runner pods and its intake uses it to read collaborator permissions; no stored value: the user comes back with the database restore, mint a fresh token on re-seed, never mount it into a runner pod itself) — pods cannot read secrets across namespaces, so the master key exists in `platform` and `factory` and rotation must replace both. `forgejo-pat` in `flux-system` (a copy of the bootstrap sync credentials) authenticates the `factory-code` GitRepository. The `gateway` role itself was created imperatively on `sf-cluster` (`CREATE ROLE gateway LOGIN PASSWORD ...`, value `SF_PG_GATEWAY_PASSWORD` in the seed env); CNPG's Database CR cannot create its owner role. The S3
  keys exist in two namespaces — `cnpg-s3-creds` in `platform` for CNPG
  backups, `hetzner-s3-creds` in `forgejo` for the nightly dump — and
  rotation must replace both. Rotating `litellm-master-key` or
  `litellm-deepseek` also requires `kubectl -n platform rollout restart
  deployment/litellm`, because no reloader watches those secrets.

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
   new API endpoint. Then the full `tofu apply`. The image selector
   requires the `schematic` label, so only the gVisor snapshot from
   `talos/build-snapshot.sh` can boot. Wait for the nodes, `talosctl
   bootstrap`, fetch the kubeconfig (strip stale `sf*` entries first).
   [Nodes installed from the schematic image register with the
   control-plane taint: remove it from all three.]
2. Cilium, imperatively (see above). The connectivity suite is optional;
   its one known failure is the node-to-node DNS check.
3. local-path, the CNPG operator and plugin, `cluster.yaml`. The recovery
   runs from the origin generation. [Origin and archive must differ, or
   the plugin refuses with an empty-archive error.] Apply the four
   Database CRs.
4. The bootstrap slice by hand: namespaces, every seeded secret from the
   list above (`forgejo-secret-key` first), Forgejo. Restore the
   repositories from the dump's `repos/` into `gitea-repositories`.
5. Fast-forward push every repository from the local clones to `origin`
   NOW, before Flux's first sync. [Pushes made while Forgejo was down
   reached GitHub only; Flux otherwise converges to the dump's stale
   tree.]
6. Mint `runner-init`, `flux bootstrap` (pinned v2.9.5), let the cascade
   converge. Actions secrets stay readable because the `SECRET_KEY` is
   pinned; after any key change, PUT them again.
7. OpenBao: throwaway init, ship the snapshot, `bao operator raft
   snapshot restore -force`, restart, unseal with the original key.
8. Re-create what restores do not carry: the `factory` namespace
   secrets, `forgejo-pat` in `flux-system`, a fresh `factoryd-intake`
   token, `factoryd-webhook` from `FORGEJO_WEBHOOK_SECRET`, and a freshly
   minted `forgejo-ci-registrar` token (user `factory-ci`,
   `write:repository`, scoped to the code repository only). PUT the Actions secret
   `REGISTRY_PASSWORD` (value `FORGEJO_CI_REGISTRY_PAT`) again if the
   `SECRET_KEY` changed. Check what the database restore should have
   brought back, and create it only if missing: the `gateway` role, the
   `factory-agent` bot as a write collaborator on the code repository,
   the `factory-ci` user in org `sf`'s Owners team (Forgejo's repository
   runner API demands the owner; rulings 101 and 101a), the code
   repository's webhook to factoryd (task
   42, all issue and pull-request events, JSON), and `main`'s branch
   protection (push and merge whitelisted to sebastian only, applied to
   admins too, one approval, no file patterns).
   factoryd itself recreates, at boot, the issue labels (`agent`,
   `human`, `state/*`) and the bot's private fork
   `factory-agent/ai-software-factory-code` that agent PRs come from
   (ruling 97).
9. Gate: every restored repository's HEAD matches the last pushed commit,
   the Stage 2 exit tests pass, CI on `main` is green, and one task
   through the authenticated intake runs to a fork PR whose checks run
   on the untrusted runner: the workflow completes with `job-env-audit`
   green (the job token's push refused); merged by the human, the task
   ends `done` and Finish deletes the fork branch.

Budget about five hours.

## Push ritual

After every task commit:

    git push origin main && git push github main

Forgejo (`origin`) is primary and is what Flux reads; GitHub (`github`)
is the off-site backup.
