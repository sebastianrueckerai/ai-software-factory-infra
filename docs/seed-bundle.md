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
- [ ] OpenBao unseal keys (created in Stage 2)
- [x] Talos secrets bundle (created in Stage 1, secrets.yaml)
- [ ] CNPG passwords (superuser, app, forgejo, litellm, temporal)
- [x] Forgejo admin password
