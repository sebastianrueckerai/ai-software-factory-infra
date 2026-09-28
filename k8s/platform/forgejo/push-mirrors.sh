#!/bin/sh
# Forgejo push mirrors to GitHub (ruling 126): one healthy mirror per
# repository. A mirror with a last_error (a rotated token shows up only
# there: Forgejo never returns the stored password) is deleted and posted
# again with the token from secret github-mirror.
set -eu
api=http://forgejo-http.forgejo.svc.cluster.local:3000/api/v1
owner=sebastianrueckerai
umask 077
printf 'Authorization: Basic %s\n' "$(printf '%s:%s' "$FORGEJO_USER" "$FORGEJO_PASSWORD" | base64 | tr -d '\n')" >/tmp/auth
f() { curl -fsS -H @/tmp/auth -H 'Content-Type: application/json' "$@"; }
log=""
failed=0
for repo in ai-software-factory-code ai-software-factory-infra; do
  want=https://github.com/$owner/$repo.git
  base=$api/repos/sf/$repo/push_mirrors
  mirrors=$(f "$base?limit=50" | jq -c --arg want "$want" \
    '[.[] | select((.remote_address | ascii_downcase | rtrimstr(".git")) == ($want | ascii_downcase | rtrimstr(".git")))]')
  keep=$(printf '%s' "$mirrors" | jq -r '[.[] | select((.last_error // "") == "")][0].remote_name // ""')
  did=""
  for name in $(printf '%s' "$mirrors" | jq -r --arg keep "$keep" '.[] | select(.remote_name != $keep) | .remote_name'); do
    f -X DELETE "$base/$name" >/dev/null
    did="$did deleted $name"
  done
  if [ -z "$keep" ]; then
    jq -n --arg a "$want" --arg u "$owner" \
      '{remote_address: $a, remote_username: $u, remote_password: $ENV.GITHUB_TOKEN, interval: "8h0m0s", sync_on_commit: true}' |
      f -X POST "$base" -d @- >/dev/null
    if f -X POST "$api/repos/sf/$repo/push_mirrors-sync" >/dev/null 2>&1; then
      did="$did created, synced"
    else
      did="$did created, sync failed (see the mirror's last_error)"
      failed=1
    fi
  fi
  [ -z "$did" ] || log="$log $repo:$did;"
done
echo "push-mirrors:${log:- no change}"
exit "$failed"
