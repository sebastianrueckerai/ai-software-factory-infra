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
