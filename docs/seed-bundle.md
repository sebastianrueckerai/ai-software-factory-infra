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
- [x] factoryd intake token — secret factoryd-intake (key token,
      namespace factory). Not a seed value: generate a fresh one on
      re-seed (`openssl rand -hex 32`) before factoryd starts; callers
      read it from the secret.
- [x] Forgejo CI runner-registrar token (Task 41) — secret
      forgejo-ci-registrar (key token, namespace factory). Not a seed
      value: mint a fresh Forgejo access token scoped to the code repo's
      Actions runner registration (register/list/delete runners only,
      never repository or registry write) before factoryd starts; its
      spawner uses this to stand up ephemeral `pr-untrusted` runner
      pods and never mounts it into one.
- [x] Forgejo webhook secret (Task 42) — secret factoryd-webhook (key
      secret, namespace factory), value `FORGEJO_WEBHOOK_SECRET` in the
      seed env: the code repo's `POST /webhooks/forgejo` webhook lives
      in Forgejo's database and comes back with the restore holding the
      same value. A fresh value must also be set on that webhook
      (HMAC-SHA256 signing secret) so deliveries verify.
