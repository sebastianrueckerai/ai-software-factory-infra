#!/usr/bin/env bash
# shellcheck disable=SC1090
# Creates every missing imperative secret of the rebuild recipe from .env.tools/.env.seed and leaves
# an existing one as it is (to replace one, delete it first). Prints names, no values.
set -euo pipefail
set -a; source ~/repos/ai-software-factory/.env.tools; source ~/repos/ai-software-factory/.env.seed; set +a
kubectl apply -f ~/repos/ai-software-factory-infra/k8s/platform/namespaces.yaml >/dev/null
k() { # -n <namespace> create secret <type> <name> ...
  if kubectl -n "$2" get secret "$6" >/dev/null 2>&1; then
    echo "$2/$6: exists"
  else
    kubectl "$@" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    echo "$2/$6: created"
  fi
}
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
k -n $A create secret generic factoryd-intake --from-literal=token="$(openssl rand -hex 32)"
k -n $A create secret generic gateway-factoryd --from-literal=token="$(openssl rand -hex 32)"
k -n $A create secret generic gateway-tool-keys --from-literal=FIRECRAWL_KEY="$FIRECRAWL_KEY" --from-literal=REPLICATE_KEY="$REPLICATE_KEY" --from-literal=FAL_AI_KEY="$FAL_AI_KEY"
k -n $A create secret generic hetzner-ci --from-literal=token="$HETZNER_CI_KEY"
k -n $A create secret generic hetzner-agent --from-literal=token="$HETZNER_AGENT_KEY"
# ClickHouse reads the cold-storage key pair as XML through include_from (config.d/storage.xml in the SigNoz HelmRelease).
k -n $P create secret generic signoz-s3 --from-literal=s3.xml="<clickhouse><signoz_s3_access_key_id>$HETZNER_S3_ACCESS_KEY_ID</signoz_s3_access_key_id><signoz_s3_secret_access_key>$HETZNER_S3_SECRET_ACCESS_KEY</signoz_s3_secret_access_key></clickhouse>"
k -n $P create secret generic signoz-root --from-literal=email=mail@sebastianruecker.com --from-literal=password="$SIGNOZ_ADMIN_PASSWORD"
# Secrets two namespaces read with one value: the value comes from the copy
# that exists, else it is minted, and the missing copy is created.
shared() { # <name> <key> <namespace>...: prints the value
  local name=$1 key=$2 n v=""; shift 2
  for n in "$@"; do
    v=$(kubectl -n "$n" get secret "$name" -o "jsonpath={.data.$key}" 2>/dev/null | base64 -d) && [ -n "$v" ] && break
  done
  # the suffix meets SigNoz's password rule (upper, lower, digit, symbol)
  printf '%s' "${v:-$(openssl rand -hex 30)Aa1-}"
}
# SigNoz's webhook channel factoryd authenticates to factoryd with it; the signoz-objects job writes the channel.
pw=$(shared signoz-webhook password $A $P)
for n in $A $P; do k -n "$n" create secret generic signoz-webhook --from-literal=password="$pw"; done
# factoryd's SigNoz viewer; the signoz-objects job creates the account from the platform copy.
pw=$(shared signoz-factoryd password $A $P)
for n in $A $P; do k -n "$n" create secret generic signoz-factoryd --from-literal=email=factoryd@aisoftwarefactory.world --from-literal=password="$pw"; done
unset pw
# forgejo-pat (flux-system) is the Flux bootstrap PAT from ~/.git-credentials; runner-init and forgejo-ci-* are minted after Forgejo is up (see the infra README); CronJob console-oauth makes console-oauth.
for n in $P $F $A; do echo "$n: $(kubectl -n "$n" get secret -o name | wc -l) secrets"; done
