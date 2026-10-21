#!/usr/bin/env bash
# shellcheck disable=SC1090
# The merge bot factory-merge, the approver bot factory-gate, the chat bot
# factory-chat and main's protection on the code repository (rulings 109
# and R59, README "The merge bot"), idempotent: creates each user if
# missing, makes it a write collaborator on its repositories, keeps the
# token in its secret (factory/forgejo-merge, factory/forgejo-gate,
# factory/forgejo-chat, key token) while that token reads main of each of
# them and otherwise revokes the older tokens of its name and mints a new
# one, and sets main's protection, then prints it; sets infra main's push
# and merge whitelists (ruling 239). A run that finds everything in place
# changes nothing and says so on every line. Logs in as the machine
# admin factory-admin (FORGEJO_FACTORY_ADMIN_PASSWORD from the seed env
# $SEED_ENV, Forgejo at $FORGEJO_URL) and needs kubectl context admin@sf.
# Prints no secret values.
set -euo pipefail
set -a; source "${SEED_ENV:-$HOME/repos/ai-software-factory/.env.seed}"; set +a
F=${FORGEJO_URL:-https://git.aisoftwarefactory.world}/api/v1
R=sf/ai-software-factory-code
A="factory-admin:$FORGEJO_FACTORY_ADMIN_PASSWORD"
c() { curl -sS -u "$A" -H 'Content-Type: application/json' "$@"; }
I=sf/ai-software-factory-infra
# 0. Forgejo drops a user without write from a whitelist: the controller must
# be a writer on both repositories (seed-secrets.sh) before anything changes
for r in $R $I; do
  perm=$(c "$F/repos/$r/collaborators/controller/permission" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("permission", ""))' || true)
  case $perm in write | admin) ;; *) echo "controller is not a writer on $r (\"$perm\"): run seed-secrets.sh first; nothing changed"; exit 1 ;; esac
done
# 1. the bots: <user> <secret> <scopes, comma-separated> <repository>....
# The user comes from the site admin API, its password random and discarded
# (its token is minted with sudo); a write collaborator on the repositories
# and nowhere else; its one token, the scopes on those repositories only.
# factoryd reads the token at boot: after a new one, restart factoryd.
bot() {
  local u=$1 s=$2 scopes=$3 tok r live
  shift 3
  if [ "$(c -o /dev/null -w '%{http_code}' "$F/users/$u")" = 200 ]; then
    echo "user $u: exists"
  else
    pw=$(openssl rand -hex 24)
    c -o /dev/null -w "user $u: %{http_code}\n" -X POST "$F/admin/users" \
      -d "{\"username\":\"$u\",\"email\":\"$u@factory.local\",\"password\":\"$pw\",\"must_change_password\":false,\"visibility\":\"private\"}"
    unset pw
  fi
  for r in "$@"; do
    if [ "$(c -o /dev/null -w '%{http_code}' "$F/repos/$r/collaborators/$u")" = 204 ] &&
      [ "$(c "$F/repos/$r/collaborators/$u/permission" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("permission", ""))')" = write ]; then
      echo "$u collaborator write on $r: no change"
    else
      c -o /dev/null -w "$u collaborator write on $r: %{http_code}\n" -X PUT "$F/repos/$r/collaborators/$u" -d '{"permission":"write"}'
    fi
  done
  tok=$(kubectl --context admin@sf -n factory get secret "$s" -o 'jsonpath={.data.token}' 2>/dev/null | base64 -d || true)
  live=${tok:+yes}
  for r in "$@"; do
    [ -n "$live" ] && [ "$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: token $tok" "$F/repos/$r/branches/main")" = 200 ] || live=
  done
  if [ -n "$live" ]; then
    echo "secret factory/$s: no change"
    return
  fi
  for id in $(c "$F/users/$u/tokens?sudo=$u" | python3 -c 'import json,sys; print(" ".join(str(t["id"]) for t in json.load(sys.stdin) if t["name"]==sys.argv[1]))' "$u"); do
    c -o /dev/null -w "$u revoke token $id: %{http_code}\n" -X DELETE "$F/users/$u/tokens/$id?sudo=$u"
  done
  tok=$(c -X POST "$F/users/$u/tokens?sudo=$u" -d "$(python3 -c 'import json,sys
u, scopes, *repos = sys.argv[1:]
print(json.dumps({"name": u, "scopes": scopes.split(","), "repositories": [dict(zip(("owner", "name"), r.split("/"))) for r in repos]}))' "$u" "$scopes" "$@")" |
    python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin).get("sha1", ""))' || true)
  [ -n "$tok" ] || { echo "secret factory/$s: mint failed, nothing written"; exit 1; }
  kubectl --context admin@sf -n factory create secret generic "$s" --from-literal=token="$tok" --dry-run=client -o yaml | kubectl --context admin@sf apply -f - >/dev/null
  echo "secret factory/$s: token written (${#tok} chars)"
}
bot factory-merge forgejo-merge write:repository $R
bot factory-gate forgejo-gate write:repository $R
# factory-chat: the project agent's own identity in every turn no member
# started; it comments, files and closes issues on both repositories (the
# infra project has a chat too) and is on no whitelist below
bot factory-chat forgejo-chat write:repository,write:issue $R $I
# <repository> <want, JSON>: PATCHes main's protection only when a field
# differs from want (lists compared as sets)
protect() {
  if c "$F/repos/$1/branch_protections/main" | python3 -c 'import json,sys
live, want = json.load(sys.stdin), json.loads(sys.argv[1])
same = lambda a, b: sorted(a or []) == sorted(b) if isinstance(b, list) else a == b
sys.exit(0 if all(same(live.get(k), v) for k, v in want.items()) else 1)' "$2"; then
    echo "protection $1 main: no change"
  else
    c -o /dev/null -w "protection $1 main: %{http_code}\n" -X PATCH "$F/repos/$1/branch_protections/main" -d "$2"
  fi
}
# 2. main's protection: factory-merge merges, factory-gate and the humans
# approve (Forgejo drops a user without write from a whitelist: the bots are
# writers by now)
protect $R '{
  "enable_push": true, "enable_push_whitelist": true, "push_whitelist_usernames": ["sebastian", "controller"], "push_whitelist_teams": [],
  "enable_merge_whitelist": true, "merge_whitelist_usernames": ["sebastian", "factory-merge"], "merge_whitelist_teams": [],
  "enable_approvals_whitelist": true, "approvals_whitelist_username": ["sebastian", "controller", "factory-gate"], "approvals_whitelist_teams": [],
  "required_approvals": 1, "apply_to_admins": true, "block_on_rejected_reviews": true, "dismiss_stale_approvals": true,
  "protected_file_patterns": "", "unprotected_file_patterns": ""}'
c "$F/repos/$R/branch_protections/main" | python3 -c 'import json,sys
d = json.load(sys.stdin)
print({k: d[k] for k in ["enable_push_whitelist","push_whitelist_usernames","enable_merge_whitelist","merge_whitelist_usernames","enable_approvals_whitelist","approvals_whitelist_username","required_approvals","apply_to_admins","block_on_rejected_reviews","dismiss_stale_approvals","protected_file_patterns","enable_status_check"]})
want = {"push_whitelist_usernames": ["controller", "sebastian"], "merge_whitelist_usernames": ["factory-merge", "sebastian"], "approvals_whitelist_username": ["controller", "factory-gate", "sebastian"]}
for k, v in want.items():
    if sorted(d[k] or []) != v: sys.exit("protection main: %s is %s, want %s" % (k, d[k], v))'
# 3. infra main (ruling 239): only its push and merge whitelists; the rest
# (no approvals, apply_to_admins) stays as it is
protect $I '{"push_whitelist_usernames": ["sebastian", "controller"], "merge_whitelist_usernames": ["sebastian", "controller"]}'
c "$F/repos/$I/branch_protections/main" | python3 -c 'import json,sys
d = json.load(sys.stdin)
print("infra", {k: d[k] for k in ["enable_push_whitelist","push_whitelist_usernames","enable_merge_whitelist","merge_whitelist_usernames","required_approvals","apply_to_admins"]})
for k in ["push_whitelist_usernames", "merge_whitelist_usernames"]:
    if sorted(d[k] or []) != ["controller", "sebastian"]: sys.exit("protection infra main: %s is %s, want [controller, sebastian]" % (k, d[k]))'
