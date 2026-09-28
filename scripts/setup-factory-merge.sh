#!/usr/bin/env bash
# The merge bot factory-merge and main's protection on the code repository
# (ruling 109, README "The merge bot"), idempotent: creates the user if
# missing, makes it a write collaborator, mints a FRESH token into secret
# factory/forgejo-merge (key token, older tokens revoked) and sets main's
# protection, then prints the protection. Needs FORGEJO_ADMIN_PASSWORD
# (sebastian) from the seed env ($SEED_ENV) and kubectl context admin@sf.
# Prints no secret values.
set -euo pipefail
set -a; source "${SEED_ENV:-$HOME/repos/ai-software-factory/.env.seed}"; set +a
F=https://git.aisoftwarefactory.world/api/v1
R=sf/ai-software-factory-code
A="sebastian:$FORGEJO_ADMIN_PASSWORD"
c() { curl -sS -u "$A" -H 'Content-Type: application/json' "$@"; }
# 1. the user (site admin API); its password is random and discarded: the token is minted with sudo
if [ "$(c -o /dev/null -w '%{http_code}' $F/users/factory-merge)" != 200 ]; then
  pw=$(openssl rand -hex 24)
  c -o /dev/null -w 'create user: %{http_code}\n' -X POST $F/admin/users \
    -d "{\"username\":\"factory-merge\",\"email\":\"factory-merge@factory.local\",\"password\":\"$pw\",\"must_change_password\":false,\"visibility\":\"private\"}"
  unset pw
fi
# 2. write collaborator on the code repository only
c -o /dev/null -w 'collaborator write: %{http_code}\n' -X PUT $F/repos/$R/collaborators/factory-merge -d '{"permission":"write"}'
# 3. a fresh token: write:repository on the code repository only; older ones revoked
for id in $(c "$F/users/factory-merge/tokens?sudo=factory-merge" | python3 -c 'import json,sys; print(" ".join(str(t["id"]) for t in json.load(sys.stdin) if t["name"]=="factory-merge"))'); do
  c -o /dev/null -w "revoke token $id: %{http_code}\n" -X DELETE "$F/users/factory-merge/tokens/$id?sudo=factory-merge"
done
c -X POST "$F/users/factory-merge/tokens?sudo=factory-merge" \
  -d '{"name":"factory-merge","scopes":["write:repository"],"repositories":[{"owner":"sf","name":"ai-software-factory-code"}]}' |
  python3 -c 'import json,sys; t=json.load(sys.stdin); open("/dev/stdout","w").write(t["sha1"])' |
  { tok=$(cat); kubectl --context admin@sf -n factory create secret generic forgejo-merge --from-literal=token="$tok" --dry-run=client -o yaml | kubectl --context admin@sf apply -f - >/dev/null; echo "secret factory/forgejo-merge: token written (${#tok} chars)"; }
# 4. main's protection
c -o /dev/null -w 'protection main: %{http_code}\n' -X PATCH $F/repos/$R/branch_protections/main -d '{
  "enable_push": true, "enable_push_whitelist": true, "push_whitelist_usernames": ["sebastian"], "push_whitelist_teams": [],
  "enable_merge_whitelist": true, "merge_whitelist_usernames": ["sebastian", "factory-merge"], "merge_whitelist_teams": [],
  "enable_approvals_whitelist": true, "approvals_whitelist_username": ["sebastian"], "approvals_whitelist_teams": [],
  "required_approvals": 1, "apply_to_admins": true, "block_on_rejected_reviews": true, "dismiss_stale_approvals": true,
  "protected_file_patterns": "", "unprotected_file_patterns": ""}'
c $F/repos/$R/branch_protections/main | python3 -c 'import json,sys; d=json.load(sys.stdin); print({k: d[k] for k in ["enable_push_whitelist","push_whitelist_usernames","enable_merge_whitelist","merge_whitelist_usernames","enable_approvals_whitelist","approvals_whitelist_username","required_approvals","apply_to_admins","block_on_rejected_reviews","dismiss_stale_approvals","protected_file_patterns","enable_status_check"]})'
