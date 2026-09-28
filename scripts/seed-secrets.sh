#!/usr/bin/env bash
# Creates every imperative secret of the rebuild recipe from .env.tools/.env.seed. Prints no values.
set -euo pipefail
set -a; source ~/repos/ai-software-factory/.env.tools; source ~/repos/ai-software-factory/.env.seed; set +a
kubectl apply -f ~/repos/ai-software-factory-infra/k8s/platform/namespaces.yaml >/dev/null
k() { kubectl "$@" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; }
P=platform
k -n $P create secret generic sf-cluster-superuser --type=kubernetes.io/basic-auth --from-literal=username=postgres --from-literal=password="$SF_PG_SUPERUSER_PASSWORD"
k -n $P create secret generic app-secret --type=kubernetes.io/basic-auth --from-literal=username=app --from-literal=password="$SF_PG_APP_PASSWORD"
for r in forgejo litellm temporal; do
  v=SF_PG_${r^^}_PASSWORD
  k -n $P create secret generic pg-$r --type=kubernetes.io/basic-auth --from-literal=username=$r --from-literal=password="${!v}"
  kubectl -n $P label secret pg-$r cnpg.io/reload=true --overwrite >/dev/null
done
k -n $P create secret generic cnpg-s3-creds --from-literal=ACCESS_KEY_ID="$HETZNER_S3_ACCESS_KEY_ID" --from-literal=ACCESS_SECRET_KEY="$HETZNER_S3_SECRET_ACCESS_KEY"
k -n $P create secret generic litellm-master-key --from-literal=masterkey="$LITELLM_MASTER_KEY"
k -n $P create secret generic litellm-deepseek --from-literal=DEEPSEEK_API_KEY="$DEEPSEEK_KEY"
k -n $P create secret generic litellm-qwen --from-literal=ALIBABA_CLOUD_KEY="$ALIBABA_CLOUD_KEY"
k -n $P create secret generic litellm-glm --from-literal=Z_AI_KEY="$Z_AI_KEY"
F=forgejo
k -n $F create secret generic forgejo-secret-key --from-literal=SECRET_KEY="$FORGEJO_SECRET_KEY"
k -n $F create secret generic forgejo-admin-secret --from-literal=username=sebastian --from-literal=password="$FORGEJO_ADMIN_PASSWORD"
k -n $F create secret generic forgejo-db-creds --from-literal=password="$SF_PG_FORGEJO_PASSWORD"
if [ -n "${GITHUB_MIRROR_PAT:-}" ]; then
  k -n $F create secret generic github-mirror --from-literal=token="$GITHUB_MIRROR_PAT"
else
  echo "github-mirror: skipped, GITHUB_MIRROR_PAT is not in .env.tools (CronJob push-mirrors waits for it)"
fi
k -n $F create secret generic hetzner-s3-creds --from-literal=access-key="$HETZNER_S3_ACCESS_KEY_ID" --from-literal=secret-key="$HETZNER_S3_SECRET_ACCESS_KEY"
A=factory
k -n $A create secret generic factory-db-creds --from-literal=username=gateway --from-literal=password="$SF_PG_GATEWAY_PASSWORD"
k -n $A create secret generic litellm-master-key --from-literal=masterkey="$LITELLM_MASTER_KEY"
k -n $A create secret docker-registry forgejo-registry --docker-server=git.aisoftwarefactory.world --docker-username=sebastian --docker-password="$FORGEJO_CI_REGISTRY_PAT"
k -n $A create secret generic forgejo-bot-creds --from-literal=password="$FORGEJO_BOT_PASSWORD"
k -n $A create secret generic factory-s3-creds --from-literal=access-key-id="$HETZNER_S3_ACCESS_KEY_ID" --from-literal=secret-access-key="$HETZNER_S3_SECRET_ACCESS_KEY"
k -n $A create secret generic factoryd-webhook --from-literal=secret="$FORGEJO_WEBHOOK_SECRET"
kubectl -n $A get secret factoryd-intake >/dev/null 2>&1 || k -n $A create secret generic factoryd-intake --from-literal=token="$(openssl rand -hex 32)"
kubectl -n $A get secret gateway-factoryd >/dev/null 2>&1 || k -n $A create secret generic gateway-factoryd --from-literal=token="$(openssl rand -hex 32)"
k -n $A create secret generic gateway-tool-keys --from-literal=FIRECRAWL_KEY="$FIRECRAWL_KEY" --from-literal=REPLICATE_KEY="$REPLICATE_KEY" --from-literal=FAL_AI_KEY="$FAL_AI_KEY"
k -n $A create secret generic hetzner-ci --from-literal=token="$HETZNER_CI_KEY"
k -n $A create secret generic hetzner-agent --from-literal=token="$HETZNER_AGENT_KEY"
k -n $P create secret generic signoz-root --from-literal=email=mail@sebastianruecker.com --from-literal=password="$SIGNOZ_ADMIN_PASSWORD"
# forgejo-pat (flux-system) is the Flux bootstrap PAT from ~/.git-credentials; runner-init and forgejo-ci-* are minted after Forgejo is up (see the infra README); CronJob console-oauth makes console-oauth.
for n in $P $F $A; do echo "$n: $(kubectl -n "$n" get secret -o name | wc -l) secrets"; done
