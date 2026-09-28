# Seed bundle checklist

The bundle lives in the offline password manager plus a printed copy.
No value below ever enters Git. Re-seed restores from Git plus S3 plus
this bundle.

- [ ] Hetzner Cloud API token (lives in terraform.tfvars on the seed
      machine, never in Git)
- [x] Hetzner Object Storage access keys (S3)
- [ ] Namecheap account access, registrar and DNS for
      aisoftwarefactory.world
- [ ] Model provider keys: DeepSeek, Alibaba, z.ai, Groq
- [ ] Tool provider keys: Replicate, Firecrawl, fal.ai
- [x] Hetzner agent project token (`HETZNER_AGENT_KEY` in `.env.tools`,
      task 53): secret hetzner-agent (key token, namespace factory),
      mounted by the gateway only; the project holds nothing but
      agent-commissioned resources, and the gateway's collector deletes
      anything there its registry does not know.
- [x] OpenBao unseal keys (created in Stage 2, one key per OpenBao's
      threshold-1 init; values in the Stage 2 task reports, task 17)
- [x] Talos secrets bundle (created in Stage 1, secrets.yaml)
- [x] CNPG passwords (superuser, app, forgejo, litellm, temporal,
      gateway — `SF_PG_GATEWAY_PASSWORD`, the imperative `gateway` role)
- [x] Forgejo admin password
- [x] LiteLLM master key (created in Stage 2, secret litellm-master-key
      in namespace platform)
- [x] Forgejo SECRET_KEY — imperative secret forgejo-secret-key in
      namespace forgejo, value `FORGEJO_SECRET_KEY` in the seed env
      (Ruling 85); re-PUT the Actions secrets after any key change
      (Task 34)
- [x] Forgejo bot account `factory-agent` (`FORGEJO_BOT_PASSWORD`): the
      factory's task-token minting identity — write collaborator on the
      code repo, password in secret forgejo-bot-creds (namespace
      factory). The live wire mints per-task tokens via basic auth on
      /api/v1/users/factory-agent/tokens (Task 36); recreate with the
      admin API before factoryd starts.
- [x] Object-storage bucket aisoftwarefactory-sessions (fsn1) — session
      records; access keys in secret factory-s3-creds (namespace
      factory).
- [ ] Object-storage bucket signoz-cold (fsn1) — SigNoz's cold tier
      (ClickHouse disk `s3`, prefix `data/`), lifecycle rule: expire
      objects after 31 days; access keys in secret signoz-s3 (key s3.xml,
      namespace platform), made by `scripts/seed-secrets.sh` from the
      same S3 key pair.
- [x] factoryd intake token — secret factoryd-intake (key token,
      namespace factory). Not a seed value: generate a fresh one on
      re-seed (`openssl rand -hex 32`) before factoryd starts; callers
      read it from the secret.
- [x] Forgejo CI registrar token (Tasks 41, 46; rulings 101, 101a) —
      secret forgejo-ci-registrar (key token, namespace factory). Not a
      seed value: the dedicated user `factory-ci` (member of org `sf`'s
      Owners team, because Forgejo's repository runner API demands the
      owner; not in `main`'s push/merge whitelist, which applies to
      admins) comes back with the database restore; mint it a fresh
      `write:repository` token scoped to the code repo only before
      factoryd starts. The spawner registers ephemeral `pr-untrusted`
      runner pods with it and never mounts it into one; the intake
      reads the code repository's collaborators and assignees with it.
- [x] Forgejo CI org-read token (Task 47, ruling 108) — secret
      forgejo-ci-org-read (key token, namespace factory). Not a seed
      value: mint `factory-ci` a fresh token with the single scope
      `read:organization` and no repository (Forgejo refuses that scope on
      a repository-limited token) before factoryd starts. factoryd's trust
      gate reads org `sf`'s teams, their repositories and members with it.
- [x] Forgejo merge token (Task 55, ruling 109) — secret forgejo-merge
      (key token, namespace factory). Not a seed value: the dedicated user
      `factory-merge` (a write collaborator on the code repository, on
      `main`'s merge whitelist and not its push whitelist) and `main`'s
      protection come back with the database restore; mint it a fresh
      `write:repository` token scoped to the code repository only (admin
      basic auth with `?sudo=factory-merge`) before factoryd starts.
      factoryd's `Merge` activity merges approved pull requests with it;
      Forgejo refuses the merge without a whitelisted human's approval.
- [x] Forgejo webhook secret (Task 42) — secret factoryd-webhook (key
      secret, namespace factory), value `FORGEJO_WEBHOOK_SECRET` in the
      seed env: the code repo's `POST /webhooks/forgejo` webhook lives
      in Forgejo's database and comes back with the restore holding the
      same value. A fresh value must also be set on that webhook
      (HMAC-SHA256 signing secret) so deliveries verify.
- [x] SigNoz root login — secret signoz-root (keys email, password,
      namespace platform), value `SIGNOZ_ADMIN_PASSWORD` in the seed env;
      `scripts/seed-secrets.sh` creates it. The SigNoz HelmRelease fails until it
      exists.
- [x] Console OAuth2 client — secret console-oauth (keys client_id,
      client_secret, session_key, namespace factory). Not a seed value:
      CronJob `console-oauth` in `forgejo` makes it from the Forgejo
      OAuth2 app `factory-console` (regenerates its client secret, mints
      the session_key) and restarts factoryd.
- [x] GitHub push mirror token — secret github-mirror (key token,
      namespace forgejo), value `GITHUB_MIRROR_PAT` in `.env.tools`: a
      fine-grained GitHub token, the two repositories only, contents
      read and write (ruling 144). `scripts/seed-secrets.sh` creates it,
      or prints one line and skips it when the key is missing; CronJob
      `push-mirrors` fails until it exists.
