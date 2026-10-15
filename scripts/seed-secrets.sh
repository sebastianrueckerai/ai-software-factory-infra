#!/usr/bin/env bash
# shellcheck disable=SC1090
# Creates every missing imperative secret of the rebuild recipe from .env.tools/.env.seed and leaves
# an existing one as it is (to replace one, delete it first). Prints names, no values.
set -euo pipefail
TOOLS_ENV=${TOOLS_ENV:-$HOME/repos/ai-software-factory/.env.tools}
SEED_ENV=${SEED_ENV:-$HOME/repos/ai-software-factory/.env.seed}
set -a; source "$TOOLS_ENV"; source "$SEED_ENV"; set +a
# The machine accounts' passwords (ruling 229) are generated into the seed env
# once, never printed.
for key in FORGEJO_FACTORY_ADMIN_PASSWORD FORGEJO_CONTROLLER_PASSWORD; do
  if [ -z "${!key:-}" ]; then
    v=$(openssl rand -hex 16)
    printf -v "$key" '%s' "$v"
    printf '\n%s=%s\n' "$key" "${!key}" >>"$SEED_ENV"
    echo "$SEED_ENV: $key generated"
  fi
done
unset v
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
k -n $P create secret generic litellm-qwen --from-literal=ALIBABA_CLOUD_KEY="$ALIBABA_CLOUD_KEY"
# The GLM Coding Plan trial (roadmap 207): the subscription key. A dedicated
# ZAI_CODING_KEY once the console holds one; today the plan's only key (the
# probe's Z_AI_KEY) carries the trial.
k -n $P create secret generic litellm-zai --from-literal=ZAI_CODING_KEY="${ZAI_CODING_KEY:-$Z_AI_KEY}"
F=forgejo
k -n $F create secret generic forgejo-secret-key --from-literal=SECRET_KEY="$FORGEJO_SECRET_KEY"
# The chart's site admin: the machine account factory-admin (ruling 229),
# which every tool of the factory logs in as; no tool uses sebastian's account.
k -n $F create secret generic forgejo-admin-secret --from-literal=username=factory-admin --from-literal=password="$FORGEJO_FACTORY_ADMIN_PASSWORD"
# factory/forgejo-admin in OpenBao: the same login, which factoryd's
# registration reads (role factoryd, ruling 212); the raft snapshot carries it
# across a rebuild. Root token and password go over stdin; an existing
# secret is left as it is unless it names another user: then its versions
# are destroyed and it is written anew. Needs OpenBao unsealed with the
# factory mount (Rebuild step 7): before that it is skipped.
bao_admin() {
  # shellcheck disable=SC2016
  printf '%s\n%s\n' "$OPENBAO_ROOT_TOKEN" "$FORGEJO_FACTORY_ADMIN_PASSWORD" | kubectl -n $P exec -i openbao-0 -- sh -c '
    IFS= read -r BAO_TOKEN; IFS= read -r pw; export BAO_TOKEN
    if ! bao secrets list -format=json 2>/dev/null | grep -q "\"factory/\""; then
      echo "openbao factory/forgejo-admin: skipped, OpenBao is sealed, refuses OPENBAO_ROOT_TOKEN or has no mount factory yet; run this script again after step 7"
    else
      had=$(bao kv get -mount=factory -field=username forgejo-admin 2>/dev/null || true)
      if [ "$had" = factory-admin ]; then
        echo "openbao factory/forgejo-admin: exists"
      else
        [ -z "$had" ] || bao kv metadata delete -mount=factory forgejo-admin >/dev/null
        printf "%s" "$pw" | bao kv put -mount=factory forgejo-admin username=factory-admin password=- >/dev/null
        if [ -n "$had" ]; then echo "openbao factory/forgejo-admin: rewritten for factory-admin (it held $had)"; else echo "openbao factory/forgejo-admin: created"; fi
      fi
    fi'
}
if [ -z "${OPENBAO_ROOT_TOKEN:-}" ]; then
  echo "openbao factory/forgejo-admin: skipped, OPENBAO_ROOT_TOKEN is not in .env.seed"
else
  bao_admin || echo "openbao factory/forgejo-admin: skipped, openbao-0 does not answer; run this script again after step 7"
fi
k -n $F create secret generic forgejo-db-creds --from-literal=password="$SF_PG_FORGEJO_PASSWORD"
# The token's duty is a write (push branches, open pull requests on GitHub),
# so a rotation is verified by a write-shaped probe: a throwaway pull request,
# opened and closed (roadmap 190). A read-only token never passes. Runs at
# creation only: to replace the token, delete the secret and run again.
if [ -n "${GITHUB_MIRROR_PAT:-}" ]; then
  if kubectl -n $F get secret github-mirror >/dev/null 2>&1; then
    echo "$F/github-mirror: exists"
  else
    GR=sebastianrueckerai/ai-software-factory-code
    gh() { curl -sS -H "Authorization: Bearer $GITHUB_MIRROR_PAT" -H 'Accept: application/vnd.github+json' "$@"; }
    body=$(mktemp)
    code=$(gh -o "$body" -w '%{http_code}' "https://api.github.com/repos/$GR")
    [ "$code" = 200 ] || { echo "github-mirror: GITHUB_MIRROR_PAT cannot read $GR (HTTP $code): the write probe cannot run; not stored"; rm -f "$body"; exit 1; }
    db=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("default_branch", "main"))' "$body")
    rm -f "$body"
    # the first branch without an open pull request (such a head answers 422)
    hb=""
    for b in $(gh "https://api.github.com/repos/$GR/branches?per_page=100" |
      python3 -c 'import json,sys
try:
    bs = json.load(sys.stdin)
    print("\n".join(b["name"] for b in bs if isinstance(bs, list) and b["name"] != sys.argv[1]))
except ValueError:
    pass' "$db"); do
      open=$(gh "https://api.github.com/repos/$GR/pulls?state=open&head=sebastianrueckerai:$b" |
        python3 -c 'import json,sys
try: print(len(json.load(sys.stdin)))
except ValueError: print(0)')
      [ "$open" = 0 ] && { hb=$b; break; }
    done
    [ -n "$hb" ] || { echo "github-mirror: no branch on $GR without an open pull request to probe from; not stored"; exit 1; }
    body=$(mktemp)
    code=$(gh -o "$body" -w '%{http_code}' -X POST -d "{\"title\":\"throwaway token probe (seed-secrets)\",\"head\":\"$hb\",\"base\":\"$db\"}" "https://api.github.com/repos/$GR/pulls")
    if [ "$code" != 201 ]; then
      rm -f "$body"
      echo "github-mirror: GITHUB_MIRROR_PAT cannot open a pull request on $GR (HTTP $code): a token with a write duty is verified by a write; not stored"
      exit 1
    fi
    n=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["number"])' "$body")
    rm -f "$body"
    code=$(gh -o /dev/null -w '%{http_code}' -X PATCH -d '{"state":"closed"}' "https://api.github.com/repos/$GR/pulls/$n")
    [ "$code" = 200 ] || { echo "github-mirror: throwaway pull request #$n opened but would not close (HTTP $code); not stored"; exit 1; }
    echo "github-mirror: probe passed (throwaway pull request #$n on $GR opened and closed)"
    k -n $F create secret generic github-mirror --from-literal=token="$GITHUB_MIRROR_PAT"
    unset db hb b open body code n
  fi
else
  echo "github-mirror: skipped, GITHUB_MIRROR_PAT is not in .env.tools (CronJob push-mirrors waits for it)"
fi
k -n $F create secret generic hetzner-s3-creds --from-literal=access-key="$HETZNER_S3_ACCESS_KEY_ID" --from-literal=secret-key="$HETZNER_S3_SECRET_ACCESS_KEY"
A=factory
k -n $A create secret generic factory-db-creds --from-literal=username=gateway --from-literal=password="$SF_PG_GATEWAY_PASSWORD"
k -n $A create secret generic litellm-master-key --from-literal=masterkey="$LITELLM_MASTER_KEY"
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
# ClickHouse's user admin, as which SigNoz's server, collector and schema migrator log in (the SigNoz HelmRelease's
# valuesFrom); hex, since it stands in their DSNs.
k -n $P create secret generic signoz-clickhouse --from-literal=password="$(openssl rand -hex 32)"
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
# The Forgejo pass, as factory-admin. Needs Forgejo up with factory-admin
# (the chart makes it at Forgejo's start from forgejo-admin-secret): before
# that it is skipped, run again after step 6.
FJ=${FORGEJO_URL:-https://git.aisoftwarefactory.world}/api/v1
IR=sf/ai-software-factory-infra
fj() { curl -sS -u "factory-admin:$FORGEJO_FACTORY_ADMIN_PASSWORD" -H 'Content-Type: application/json' "$@"; }
# <login> <email> <variable holding the password> <site admin true|false>:
# created when missing, never touched when it exists
account() {
  if [ "$(fj -o /dev/null -w '%{http_code}' "$FJ/users/$1")" = 200 ]; then
    echo "user $1: exists"
    return
  fi
  V=${!3} jq -n --arg u "$1" --arg e "$2" '{username: $u, email: $e, password: $ENV.V, must_change_password: false}' |
    fj -o /dev/null -w "user $1: %{http_code}\n" -X POST "$FJ/admin/users" -d @-
  [ "$4" = false ] || fj -o /dev/null -w "user $1 site admin: %{http_code}\n" -X PATCH "$FJ/admin/users/$1" -d '{"admin":true}'
}
if [ "$(fj -o /dev/null -w '%{http_code}' "$FJ/repos/$IR")" != 200 ]; then
  echo "forgejo: skipped, Forgejo does not answer for $IR as factory-admin yet; run this script again after step 6"
else
  # the human (no tool logs in as him) and the controller's own account
  account sebastian admin@aisoftwarefactory.world FORGEJO_ADMIN_PASSWORD true
  account controller controller@aisoftwarefactory.world FORGEJO_CONTROLLER_PASSWORD false
  # idempotent: every run converges them
  for r in sf/ai-software-factory-code $IR sf/ai-software-factory; do
    fj -o /dev/null -w "controller write collaborator on $r: %{http_code}\n" -X PUT "$FJ/repos/$r/collaborators/controller" -d '{"permission":"write"}'
  done
  # forgejo-config (factory): factoryd reads the configuration tree factory/
  # of this repository with it (ruling 183). The user factory-config is a read
  # collaborator on this repository and nothing else, its token
  # read:repository limited to it. The same pass lets factory-agent (read)
  # file the config_rejected issues here.
  if [ "$(fj -o /dev/null -w '%{http_code}' "$FJ/users/factory-config")" != 200 ]; then
    fj -o /dev/null -w 'factory-config user: %{http_code}\n' -X POST "$FJ/admin/users" \
      -d "{\"username\":\"factory-config\",\"email\":\"factory-config@factory.local\",\"password\":\"$(openssl rand -hex 24)\",\"must_change_password\":false,\"visibility\":\"private\"}"
  fi
  fj -o /dev/null -w 'factory-config read collaborator: %{http_code}\n' -X PUT "$FJ/repos/$IR/collaborators/factory-config" -d '{"permission":"read"}'
  fj -o /dev/null -w 'factory-agent read collaborator: %{http_code}\n' -X PUT "$FJ/repos/$IR/collaborators/factory-agent" -d '{"permission":"read"}'
  # <repository> <name> <value>: PUT an Actions secret; fails on any answer
  # but 201 or 204
  put_secret() {
    local code
    code=$(V=$3 jq -n '{data: $ENV.V}' | fj -o /dev/null -w '%{http_code}' -X PUT "$FJ/repos/$1/actions/secrets/$2" -d @-)
    echo "$1 Actions secret $2: $code"
    [ "$code" = 201 ] || [ "$code" = 204 ]
  }
  revoke() { # factory-admin's tokens named $1
    for id in $(fj "$FJ/users/factory-admin/tokens" | jq -r --arg n "$1" '.[] | select(.name == $n) | .id'); do
      fj -o /dev/null -w "factory-admin revoke token $1 $id: %{http_code}\n" -X DELETE "$FJ/users/factory-admin/tokens/$id"
    done
  }
  # The code repository's main CI pushes its images with factory-admin's
  # token factory-registry (write:package) in the Actions secrets
  # REGISTRY_USER and REGISTRY_PASSWORD. No copy is kept, so it is minted
  # and PUT only when it or one of the two secrets is missing (after a
  # SECRET_KEY change: delete one, run again); a failed PUT revokes it, so
  # the next run mints again.
  CR=sf/ai-software-factory-code
  have=$(fj "$FJ/repos/$CR/actions/secrets?limit=50" | jq -r '.[].name')
  if fj "$FJ/users/factory-admin/tokens" | jq -e 'any(.[]; .name == "factory-registry")' >/dev/null &&
    grep -qx REGISTRY_USER <<<"$have" && grep -qx REGISTRY_PASSWORD <<<"$have"; then
    echo "$CR registry Actions secrets: exist"
  else
    revoke factory-registry
    tok=$(fj -X POST "$FJ/users/factory-admin/tokens" -d '{"name":"factory-registry","scopes":["write:package"]}' | jq -r '.sha1 // empty' || true)
    [ -n "$tok" ] || { echo "$CR registry Actions secrets: mint failed, nothing written"; exit 1; }
    if ! { put_secret $CR REGISTRY_USER factory-admin && put_secret $CR REGISTRY_PASSWORD "$tok"; }; then
      revoke factory-registry
      exit 1
    fi
  fi
  unset have tok
  # main CI signs every image it pushes with the factory's cosign key
  # (roadmap 46). OpenBao keeps the pair's private half as factory/cosign
  # (private_key, the encrypted PEM cosign generate-key-pair writes, and
  # password), and the raft snapshot carries it across a rebuild; every run
  # PUTs it into the code repository's Actions secrets COSIGN_PRIVATE_KEY
  # and COSIGN_PASSWORD, which only main CI's image jobs read. Read with the
  # root token over stdin, never printed. No pair yet:
  # scripts/cosign-keygen.sh makes one.
  if [ -z "${OPENBAO_ROOT_TOKEN:-}" ]; then
    echo "$CR signing Actions secrets: skipped, OPENBAO_ROOT_TOKEN is not in .env.seed"
  elif ! cosign=$(printf '%s\n' "$OPENBAO_ROOT_TOKEN" | kubectl -n $P exec -i openbao-0 -- sh -c '
      IFS= read -r BAO_TOKEN; export BAO_TOKEN
      bao kv get -mount=factory -format=json cosign 2>/dev/null' |
    jq -ce '.data.data | select(.private_key != "" and .password != "")' 2>/dev/null); then
    echo "$CR signing Actions secrets: skipped, OpenBao holds no factory/cosign, is sealed or does not answer (scripts/cosign-keygen.sh makes the pair)"
  else
    put_secret $CR COSIGN_PRIVATE_KEY "$(printf '%s' "$cosign" | jq -r .private_key)" || exit 1
    put_secret $CR COSIGN_PASSWORD "$(printf '%s' "$cosign" | jq -r .password)" || exit 1
  fi
  unset cosign
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
  # forgejo-docs (factory): the chat's write_doc commits docs/ of the
  # document repository with it, straight to master (roadmap 239, the
  # 2026-10-13 plan). The user factory-docs is a write collaborator on
  # sf/ai-software-factory and nothing else, its token write:repository
  # limited to it. A new token passes a write probe before it is stored: a
  # file on a fresh branch, then the branch's delete; one that fails it is
  # revoked and no secret is written.
  DR=sf/ai-software-factory
  if [ "$(fj -o /dev/null -w '%{http_code}' "$FJ/users/factory-docs")" != 200 ]; then
    fj -o /dev/null -w 'factory-docs user: %{http_code}\n' -X POST "$FJ/admin/users" \
      -d "{\"username\":\"factory-docs\",\"email\":\"factory-docs@factory.local\",\"password\":\"$(openssl rand -hex 24)\",\"must_change_password\":false,\"visibility\":\"private\"}"
  fi
  fj -o /dev/null -w 'factory-docs write collaborator: %{http_code}\n' -X PUT "$FJ/repos/$DR/collaborators/factory-docs" -d '{"permission":"write"}'
  # an agent session of a project whose chat.doc_repo names it reads the
  # document repository's text files at /workspace/docs, through its read
  # token minted for factory-agent, so factory-agent reads it
  fj -o /dev/null -w 'factory-agent read collaborator: %{http_code}\n' -X PUT "$FJ/repos/$DR/collaborators/factory-agent" -d '{"permission":"read"}'
  if kubectl -n $A get secret forgejo-docs >/dev/null 2>&1; then
    echo "$A/forgejo-docs: exists"
  else
    revoke_docs() {
      for id in $(fj "$FJ/users/factory-docs/tokens?sudo=factory-docs" | jq -r '.[] | select(.name == "factory-docs") | .id'); do
        fj -o /dev/null -w "factory-docs revoke token $id: %{http_code}\n" -X DELETE "$FJ/users/factory-docs/tokens/$id?sudo=factory-docs"
      done
    }
    revoke_docs
    tok=$(fj -X POST "$FJ/users/factory-docs/tokens?sudo=factory-docs" \
      -d '{"name":"factory-docs","scopes":["write:repository"],"repositories":[{"owner":"sf","name":"ai-software-factory"}]}' | jq -r '.sha1 // empty' || true)
    [ -n "$tok" ] || { echo "$A/forgejo-docs: mint failed, no secret written"; exit 1; }
    probe=docs-probe-$(date +%s)
    code=$(jq -n --arg b "$probe" --arg c "$(printf 'write probe of the docs token' | base64)" \
      '{branch: "master", new_branch: $b, message: "docs token write probe", files: [{operation: "create", path: "probe.md", content: $c}]}' |
      curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: token $tok" -H 'Content-Type: application/json' -X POST "$FJ/repos/$DR/contents" -d @-)
    del=$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: token $tok" -X DELETE "$FJ/repos/$DR/branches/$probe")
    if [ "$code" != 201 ] || [ "$del" != 204 ]; then
      echo "$A/forgejo-docs: the write probe failed (commit $code, branch delete $del): token revoked, no secret written"
      revoke_docs
      exit 1
    fi
    kubectl -n $A create secret generic forgejo-docs --from-literal=token="$tok" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    echo "$A/forgejo-docs: created (${#tok} chars), the write probe passed"
    unset tok probe code del
  fi
  # The infra repository is a seed project (ruling 179, agents none): the
  # seed owns its webhook to factoryd, so its issues reach the human lane;
  # factoryd reports it. factoryd keeps the labels itself, as the bot,
  # with the issues write of team factory-issues-infra below. Idempotent: an existing hook to factoryd is left alone.
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
  # repository only, member factory-agent. With it the bot creates this
  # repository's labels and sets the state labels on its human-lane issues;
  # code read and main's push whitelist (unchanged) keep it from pushing.
  # Forgejo 15's units_map sets each unit's access on its own; every run
  # sets the units again and reads them back.
  tid=$(fj "$FJ/orgs/sf/teams?limit=50" | python3 -c 'import json,sys; print(next((str(t["id"]) for t in json.load(sys.stdin) if t["name"]=="factory-issues-infra"), ""))')
  if [ -z "$tid" ]; then
    tid=$(fj -X POST "$FJ/orgs/sf/teams" -d '{"name":"factory-issues-infra","description":"factory-agent: issue labels on the infra repository (ruling 179)","includes_all_repositories":false,"can_create_org_repo":false,"units":["repo.code","repo.issues"],"units_map":{"repo.code":"read","repo.issues":"write"}}' |
      python3 -c 'import json,sys; print(json.load(sys.stdin).get("id", ""))' || true)
    [ -n "$tid" ] || { echo "team factory-issues-infra: create failed"; exit 1; }
    echo "team factory-issues-infra: created ($tid)"
  fi
  UNITS='{"name":"factory-issues-infra","includes_all_repositories":false,"can_create_org_repo":false,"units":["repo.code","repo.issues"],"units_map":{"repo.code":"read","repo.issues":"write"}}'
  fj -o /dev/null -w "team factory-issues-infra units: %{http_code}\n" -X PATCH "$FJ/teams/$tid" -d "$UNITS"
  fj "$FJ/teams/$tid" | python3 -c 'import json,sys
t = json.load(sys.stdin)
units = {k: v for k, v in (t.get("units_map") or {}).items() if v != "none"}
if units != {"repo.code": "read", "repo.issues": "write"} or t.get("includes_all_repositories"):
    sys.exit("team factory-issues-infra: units %s, all repositories %s: want repo.code read, repo.issues write, this repository only" % (units, t.get("includes_all_repositories")))
print("team factory-issues-infra units: repo.code read, repo.issues write")'
  fj -o /dev/null -w "team factory-issues-infra repository $IR: %{http_code}\n" -X PUT "$FJ/teams/$tid/repos/$IR"
  fj -o /dev/null -w "team factory-issues-infra member factory-agent: %{http_code}\n" -X PUT "$FJ/teams/$tid/members/factory-agent"
  # anyone or anything else in the team is a human's doing: logged, left alone
  fj "$FJ/teams/$tid/members?limit=50" | python3 -c 'import json,sys
for u in json.load(sys.stdin):
    if u["login"] != "factory-agent": print("team factory-issues-infra: other member %s (left alone)" % u["login"])'
  fj "$FJ/teams/$tid/repos?limit=50" | python3 -c 'import json,sys
for r in json.load(sys.stdin):
    if r["full_name"] != sys.argv[1]: print("team factory-issues-infra: other repository %s (left alone)" % r["full_name"])' "$IR"
  # forgejo-registry-read (factory): the roller reads main CI's images with
  # it (review-task75 m1). User factory-registry-read is a member of team
  # factory-registry-read in org sf, whose one unit is repo.packages read on
  # no repository (org sf is private: Forgejo 15 grants its packages to team
  # members only, services/packages/perm.go); its token has the single scope
  # read:package, so it can overwrite no tag.
  if [ "$(fj -o /dev/null -w '%{http_code}' "$FJ/users/factory-registry-read")" != 200 ]; then
    fj -o /dev/null -w 'factory-registry-read user: %{http_code}\n' -X POST "$FJ/admin/users" \
      -d "{\"username\":\"factory-registry-read\",\"email\":\"factory-registry-read@factory.local\",\"password\":\"$(openssl rand -hex 24)\",\"must_change_password\":false,\"visibility\":\"private\"}"
  fi
  RUNITS='{"name":"factory-registry-read","description":"factory-registry-read: the roller reads main CI images (read:package)","includes_all_repositories":false,"can_create_org_repo":false,"permission":"read","units":["repo.packages"],"units_map":{"repo.packages":"read"}}'
  rtid=$(fj "$FJ/orgs/sf/teams?limit=50" | python3 -c 'import json,sys; print(next((str(t["id"]) for t in json.load(sys.stdin) if t["name"]=="factory-registry-read"), ""))')
  if [ -z "$rtid" ]; then
    rtid=$(fj -X POST "$FJ/orgs/sf/teams" -d "$RUNITS" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id", ""))' || true)
    [ -n "$rtid" ] || { echo "team factory-registry-read: create failed"; exit 1; }
    echo "team factory-registry-read: created ($rtid)"
  fi
  fj -o /dev/null -w "team factory-registry-read units: %{http_code}\n" -X PATCH "$FJ/teams/$rtid" -d "$RUNITS"
  fj "$FJ/teams/$rtid" | python3 -c 'import json,sys
t = json.load(sys.stdin)
units = {k: v for k, v in (t.get("units_map") or {}).items() if v != "none"}
if units != {"repo.packages": "read"} or t.get("includes_all_repositories") or t.get("permission") not in ("none", "read"):
    sys.exit("team factory-registry-read: units %s, all repositories %s, permission %s: want repo.packages read only" % (units, t.get("includes_all_repositories"), t.get("permission")))
print("team factory-registry-read units: repo.packages read")'
  fj -o /dev/null -w "team factory-registry-read member factory-registry-read: %{http_code}\n" -X PUT "$FJ/teams/$rtid/members/factory-registry-read"
  fj "$FJ/teams/$rtid/members?limit=50" | python3 -c 'import json,sys
logins = [u["login"] for u in json.load(sys.stdin)]
for l in logins:
    if l != "factory-registry-read": print("team factory-registry-read: other member %s (left alone)" % l)
if "factory-registry-read" not in logins: sys.exit("team factory-registry-read: factory-registry-read is not a member")
print("team factory-registry-read member: factory-registry-read")'
  fj "$FJ/teams/$rtid/repos?limit=50" | python3 -c 'import json,sys
for r in json.load(sys.stdin): print("team factory-registry-read: repository %s (left alone; the team needs none)" % r["full_name"])'
  if kubectl -n $A get secret forgejo-registry-read >/dev/null 2>&1; then
    echo "$A/forgejo-registry-read: exists"
  else
    for id in $(fj "$FJ/users/factory-registry-read/tokens?sudo=factory-registry-read" | python3 -c 'import json,sys; print(" ".join(str(t["id"]) for t in json.load(sys.stdin) if t["name"]=="factory-registry-read"))'); do
      fj -o /dev/null -w "factory-registry-read revoke token $id: %{http_code}\n" -X DELETE "$FJ/users/factory-registry-read/tokens/$id?sudo=factory-registry-read"
    done
    tok=$(fj -X POST "$FJ/users/factory-registry-read/tokens?sudo=factory-registry-read" -d '{"name":"factory-registry-read","scopes":["read:package"]}' |
      python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin).get("sha1", ""))' || true)
    [ -n "$tok" ] || { echo "$A/forgejo-registry-read: mint failed, no secret written"; exit 1; }
    kubectl -n $A create secret generic forgejo-registry-read --from-literal=token="$tok" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    echo "$A/forgejo-registry-read: created (${#tok} chars)"
    unset tok
  fi
  # Org upstream is the store of the outside images (the code repository's
  # upstream-images.txt, roadmap 203): visibility limited, so every
  # signed-in account reads its packages, factory-registry-read and a CI
  # job's token among them, and no anonymous caller does. The code
  # repository's main CI copies into it as factory-admin, its owner.
  if [ "$(fj -o /dev/null -w '%{http_code}' "$FJ/orgs/upstream")" != 200 ]; then
    fj -o /dev/null -w 'org upstream: %{http_code}\n' -X POST "$FJ/orgs" \
      -d '{"username":"upstream","visibility":"limited","description":"Copies of the outside images the factory uses (upstream-images.txt of the code repository)"}'
  fi
  vis=$(fj "$FJ/orgs/upstream" | jq -r .visibility)
  [ "$vis" = limited ] || { echo "org upstream: visibility $vis, want limited"; exit 1; }
  echo "org upstream: limited"
  # Image pulls (pull secret forgejo-registry: in factory, which factoryd
  # copies into every CI and agent namespace, in the namespaces whose pods
  # run the store's copies, and in flux-system, where the OCI charts come
  # from the store; forgejo-charts there is the same login as the username
  # and password the store's Helm repository takes) and the config check's
  # registry login (this repository's REGISTRY_USER and REGISTRY_PASSWORD)
  # only read: sf's images and upstream's copies. They take the same
  # read:package token, and follow it when it is minted again.
  rtok=$(kubectl -n $A get secret forgejo-registry-read -o 'jsonpath={.data.token}' | base64 -d)
  # before flux bootstrap makes it, so Flux's first sync reads the charts
  kubectl get namespace flux-system >/dev/null 2>&1 || kubectl create namespace flux-system >/dev/null
  if [ "$(kubectl -n flux-system get secret forgejo-charts -o 'jsonpath={.data.password}' 2>/dev/null | base64 -d)" = "$rtok" ]; then
    echo "flux-system/forgejo-charts: exists"
  else
    kubectl -n flux-system create secret generic forgejo-charts --from-literal=username=factory-registry-read --from-literal=password="$rtok" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    echo "flux-system/forgejo-charts: written for factory-registry-read"
  fi
  for n in $A $P $F k8s-infra flux-system; do
    pull=$(kubectl -n $n get secret forgejo-registry -o 'jsonpath={.data.\.dockerconfigjson}' 2>/dev/null | base64 -d | jq -c '[.auths[] | .username, .password]' 2>/dev/null || true)
    if [ "$pull" = "$(jq -nc --arg t "$rtok" '["factory-registry-read", $t]')" ]; then
      echo "$n/forgejo-registry: exists"
    else
      kubectl -n $n create secret docker-registry forgejo-registry --docker-server=git.aisoftwarefactory.world --docker-username=factory-registry-read --docker-password="$rtok" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
      echo "$n/forgejo-registry: written for factory-registry-read"
    fi
  done
  put_secret $IR REGISTRY_USER factory-registry-read || exit 1
  put_secret $IR REGISTRY_PASSWORD "$rtok" || exit 1
  unset rtok pull vis
fi
# forgejo-pat (flux-system) is a copy of Flux's bootstrap token, factory-admin's; runner-init and forgejo-ci-* are minted after Forgejo is up (see the infra README); CronJob console-oauth makes console-oauth.
for n in $P $F $A; do echo "$n: $(kubectl -n "$n" get secret -o name | wc -l) secrets"; done
