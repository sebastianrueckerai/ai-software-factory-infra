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
  `litellm-deepseek`, `litellm-qwen` (key ALIBABA_CLOUD_KEY), `litellm-glm` (keys Z_AI_KEY), `forgejo-secret-key` (platform, replicated into forgejo)) are imperative and stay out of the tree. In `factory`: `factory-db-creds` (keys `username`/`password`, the CNPG `gateway` role), a copy of `litellm-master-key` (key `masterkey`), and the `forgejo-registry` pull secret (username `sebastian`, the CI registry PAT) — pods cannot read secrets across namespaces, so the master key exists in `platform` and `factory` and rotation must replace both. `forgejo-pat` in `flux-system` (a copy of the bootstrap sync credentials) authenticates the `factory-code` GitRepository. The `gateway` role itself was created imperatively on `sf-cluster` (`CREATE ROLE gateway LOGIN PASSWORD ...`, value `SF_PG_GATEWAY_PASSWORD` in the seed env); CNPG's Database CR cannot create its owner role. The S3
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

## Push ritual

After every task commit:

    git push origin main && git push github main

Forgejo (`origin`) is primary and is what Flux reads; GitHub (`github`)
is the off-site backup.
