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
k -n $P create secret generic litellm-groq --from-literal=GROQ_KEY="$GROQ_KEY"
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
# forgejo-config (factory): factoryd reads the configuration tree factory/ of
# this repository with it (ruling 183). The user factory-config is a read
# collaborator on this repository and nothing else, its token read:repository
# limited to it. The same pass lets factory-agent (read) file the
# config_rejected issues here and gives the config-check workflow its
# registry login. Needs Forgejo up: before that it is skipped, run again after
# step 6.
FJ=https://git.aisoftwarefactory.world/api/v1
IR=sf/ai-software-factory-infra
fj() { curl -sS -u "sebastian:$FORGEJO_ADMIN_PASSWORD" -H 'Content-Type: application/json' "$@"; }
if [ "$(fj -o /dev/null -w '%{http_code}' $FJ/repos/$IR)" != 200 ]; then
  echo "$A/forgejo-config: skipped, Forgejo does not answer for $IR yet; run this script again after step 6"
else
  if [ "$(fj -o /dev/null -w '%{http_code}' $FJ/users/factory-config)" != 200 ]; then
    fj -o /dev/null -w 'factory-config user: %{http_code}\n' -X POST $FJ/admin/users \
      -d "{\"username\":\"factory-config\",\"email\":\"factory-config@factory.local\",\"password\":\"$(openssl rand -hex 24)\",\"must_change_password\":false,\"visibility\":\"private\"}"
  fi
  # idempotent: every run converges them
  fj -o /dev/null -w 'factory-config read collaborator: %{http_code}\n' -X PUT $FJ/repos/$IR/collaborators/factory-config -d '{"permission":"read"}'
  fj -o /dev/null -w 'factory-agent read collaborator: %{http_code}\n' -X PUT $FJ/repos/$IR/collaborators/factory-agent -d '{"permission":"read"}'
  for kv in "REGISTRY_USER=sebastian" "REGISTRY_PASSWORD=$FORGEJO_CI_REGISTRY_PAT"; do
    V="${kv#*=}" python3 -c 'import json,os; print(json.dumps({"data": os.environ["V"]}))' |
      fj -o /dev/null -w "$IR Actions secret ${kv%%=*}: %{http_code}\n" -X PUT "$FJ/repos/$IR/actions/secrets/${kv%%=*}" -d @-
  done
  if kubectl -n $A get secret forgejo-config >/dev/null 2>&1; then
    echo "$A/forgejo-config: exists"
  else
    for id in $(fj "$FJ/users/factory-config/tokens?sudo=factory-config" | python3 -c 'import json,sys; print(" ".join(str(t["id"]) for t in json.load(sys.stdin) if t["name"]=="factory-config"))'); do
      fj -o /dev/null -w "factory-config revoke token $id: %{http_code}\n" -X DELETE "$FJ/users/factory-config/tokens/$id?sudo=factory-config"
    done
    tok=$(fj -X POST "$FJ/users/factory-config/tokens?sudo=factory-config" \
      -d '{"name":"factory-config","scopes":["read:repository"],"repositories":[{"owner":"sf","name":"ai-software-factory-infra"}]}' |
      python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin).get("sha1", ""))' || true)
    [ -n "$tok" ] || { echo "$A/forgejo-config: mint failed, no secret written"; exit 1; }
    kubectl -n $A create secret generic forgejo-config --from-literal=token="$tok" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    echo "$A/forgejo-config: created (${#tok} chars)"
    unset tok
  fi
  # The infra repository is a seed project (ruling 179, agents none): the
  # seed owns its webhook to factoryd, so its issues reach the human lane,
  # and its labels. factoryd only reports them. Idempotent: an existing hook to factoryd is left alone.
  HOOK=http://factoryd.factory.svc.cluster.local:8080/webhooks/forgejo
  if fj "$FJ/repos/$IR/hooks" | python3 -c 'import json,sys; sys.exit(0 if any(h["config"]["url"]==sys.argv[1] for h in json.load(sys.stdin)) else 1)' "$HOOK"; then
    echo "$IR webhook to factoryd: exists"
  else
    V="$FORGEJO_WEBHOOK_SECRET" python3 -c 'import json,os,sys; print(json.dumps({"type":"forgejo","active":True,"branch_filter":"*",
      "events":["issues","issue_assign","issue_label","issue_milestone","issue_comment"],
      "config":{"url":sys.argv[1],"content_type":"json","secret":os.environ["V"]}}))' "$HOOK" |
      fj -o /dev/null -w "$IR webhook to factoryd: %{http_code}\n" -X POST "$FJ/repos/$IR/hooks" -d @-
  fi
  # Team factory-issues-infra in org sf: issues write, code read, on this
  # repository only, member factory-agent. The bot sets the state labels on
  # this repository's human-lane issues with it; code read and main's push
  # whitelist (unchanged) keep it from pushing. Forgejo 15's units_map sets
  # each unit's access on its own.
  tid=$(fj "$FJ/orgs/sf/teams?limit=50" | python3 -c 'import json,sys; print(next((str(t["id"]) for t in json.load(sys.stdin) if t["name"]=="factory-issues-infra"), ""))')
  if [ -z "$tid" ]; then
    tid=$(fj -X POST "$FJ/orgs/sf/teams" -d '{"name":"factory-issues-infra","description":"factory-agent: issue labels on the infra repository (ruling 179)","includes_all_repositories":false,"can_create_org_repo":false,"units":["repo.code","repo.issues"],"units_map":{"repo.code":"read","repo.issues":"write"}}' |
      python3 -c 'import json,sys; print(json.load(sys.stdin).get("id", ""))' || true)
    [ -n "$tid" ] || { echo "team factory-issues-infra: create failed"; exit 1; }
    echo "team factory-issues-infra: created ($tid)"
  fi
  fj -o /dev/null -w "team factory-issues-infra repository $IR: %{http_code}\n" -X PUT "$FJ/teams/$tid/repos/$IR"
  fj -o /dev/null -w "team factory-issues-infra member factory-agent: %{http_code}\n" -X PUT "$FJ/teams/$tid/members/factory-agent"
  have=$(fj "$FJ/repos/$IR/labels?limit=100" | python3 -c 'import json,sys; print(" ".join(l["name"] for l in json.load(sys.stdin)))')
  # factoryd.BootLabels
  for kv in agent=ededed human=c2e0c6 bug=cf222e improvement=0e8a16 state/suggested=c5def5 state/queued=ededed \
    state/running=1f6feb state/waiting-human=d4a72c state/waiting-poster=fbca04 state/in-review=8250df state/done=2da44e \
    state/failed=cf222e state/closed=6e7781 priority/p0=b60205 priority/p1=d93f0b priority/p2=fbca04 priority/p3=c5def5 \
    severity/critical=b60205 severity/high=d93f0b severity/medium=fbca04 severity/low=c5def5; do
    case " $have " in *" ${kv%%=*} "*) continue ;; esac
    fj -o /dev/null -w "$IR label ${kv%%=*}: %{http_code}\n" -X POST "$FJ/repos/$IR/labels" -d "{\"name\":\"${kv%%=*}\",\"color\":\"#${kv#*=}\"}"
  done
fi
# forgejo-pat (flux-system) is the Flux bootstrap PAT from ~/.git-credentials; runner-init and forgejo-ci-* are minted after Forgejo is up (see the infra README); CronJob console-oauth makes console-oauth.
for n in $P $F $A; do echo "$n: $(kubectl -n "$n" get secret -o name | wc -l) secrets"; done
