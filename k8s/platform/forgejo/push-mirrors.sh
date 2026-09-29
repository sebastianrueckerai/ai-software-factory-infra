#!/bin/sh
# shellcheck shell=busybox
# Forgejo push mirrors to GitHub (ruling 126): one mirror per repository.
# A mirror whose last_error is a credential failure (a rotated token shows
# up only there: Forgejo never returns the stored password) is deleted and
# posted again with the token from secret github-mirror. Any other error
# (GH007, a GitHub outage) a new token cannot fix: it is logged and the
# mirror is left to its own next sync.
set -euo pipefail
trap '[ $? = 0 ] || echo "push-mirrors: failed"' EXIT
if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "push-mirrors: secret github-mirror missing, nothing to do"
  exit 0
fi
api=http://forgejo-http.forgejo.svc.cluster.local:3000/api/v1
owner=sebastianrueckerai
umask 077
printf 'Authorization: Basic %s\n' "$(printf '%s:%s' "$FORGEJO_USER" "$FORGEJO_PASSWORD" | base64 | tr -d '\n')" >/tmp/auth
f() { curl -fsS -H @/tmp/auth -H 'Content-Type: application/json' "$@"; }
log=""
failed=0
cred='Authentication failed|Repository not found|could not read Username|Invalid username or token|Permission to .* denied|returned error: 40[13]'
ours() { jq -c --arg want "$want" '[.[] | select((.remote_address | ascii_downcase | rtrimstr(".git")) == ($want | ascii_downcase | rtrimstr(".git")))]'; }
first() { jq -r '.last_error // "" | split("\n")[0] // "" | .[0:200]'; }
for repo in ai-software-factory-code ai-software-factory-infra; do
  want=https://github.com/$owner/$repo.git
  base=$api/repos/sf/$repo/push_mirrors
  mirrors=$(f "$base?limit=50" | ours)
  keep=$(printf '%s' "$mirrors" | jq -c --arg cred "$cred" '[.[] | select(.last_error // "" | test($cred; "i") | not)] | sort_by(.last_error // "" != "") | .[0] // empty')
  name=$(printf '%s' "$keep" | jq -r '.remote_name // ""')
  did=""
  for other in $(printf '%s' "$mirrors" | jq -r --arg keep "$name" '.[] | select(.remote_name != $keep) | .remote_name'); do
    f -X DELETE "$base/$other" >/dev/null
    did="$did deleted $other"
  done
  if [ -n "$name" ]; then
    err=$(printf '%s' "$keep" | first)
    [ -z "$err" ] || did="$did $name left alone, sync failing: $err"
  else
    jq -n --arg a "$want" --arg u "$owner" \
      '{remote_address: $a, remote_username: $u, remote_password: $ENV.GITHUB_TOKEN, interval: "8h0m0s", sync_on_commit: true}' |
      f -X POST "$base" -d @- >/dev/null
    if f -X POST "$api/repos/sf/$repo/push_mirrors-sync" >/dev/null 2>&1; then
      did="$did created, synced"
    else
      made=$(f "$base?limit=50" | ours | jq -c '.[0] // {}')
      err=$(printf '%s' "$made" | first)
      did="$did created, sync failed: ${err:-no last_error}"
      printf '%s' "$made" | jq -e --arg cred "$cred" '.last_error // "" | . == "" or test($cred; "i")' >/dev/null && failed=1
    fi
  fi
  [ -z "$did" ] || log="$log $repo:$did;"
done
echo "push-mirrors:${log:- no change}"
trap - EXIT
exit "$failed"
