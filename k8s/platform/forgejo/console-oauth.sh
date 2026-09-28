#!/bin/sh
# shellcheck shell=busybox
# The console's Forgejo OAuth app (user sebastian) and secret
# factory/console-oauth. Forgejo shows a client secret once, so a missing
# secret, a missing key or a client_id that is not the app's means: create
# the app or regenerate its secret, mint a fresh session_key, write the
# secret, restart factoryd (it reads the keys at boot).
set -euo pipefail
trap '[ $? = 0 ] || echo "console-oauth: failed"' EXIT
api=http://forgejo-http.forgejo.svc.cluster.local:3000/api/v1
app_name=factory-console
redirect=https://console.aisoftwarefactory.world/auth/callback
umask 077
printf 'Authorization: Basic %s\n' "$(printf '%s:%s' "$FORGEJO_USER" "$FORGEJO_PASSWORD" | base64 | tr -d '\n')" >/tmp/auth
f() { curl -fsS -H @/tmp/auth -H 'Content-Type: application/json' "$@"; }
app=$(f "$api/user/applications/oauth2?limit=50" | jq -c --arg n "$app_name" '[.[] | select(.name == $n)][0] // empty')
secret=$(kubectl -n factory get secret console-oauth --ignore-not-found -o json)
have=$(printf '%s' "$secret" | jq -r '.data // {} | [.client_id, .client_secret, .session_key] | map(select(. != null and . != "")) | length' 2>/dev/null || echo 0)
secret_id=$(printf '%s' "$secret" | jq -r '.data.client_id // "" | @base64d' 2>/dev/null || true)
app_id=$(printf '%s' "$app" | jq -r '.client_id // ""')
if [ "$have" = 3 ] && [ -n "$app_id" ] && [ "$secret_id" = "$app_id" ]; then
  echo "console-oauth: no change"
  exit 0
fi
body=$(jq -nc --arg n "$app_name" --arg r "$redirect" '{name: $n, redirect_uris: [$r], confidential_client: true}')
if [ -z "$app_id" ]; then
  creds=$(printf '%s' "$body" | f -X POST "$api/user/applications/oauth2" -d @-)
  why="app $app_name created"
else
  creds=$(printf '%s' "$body" | f -X PATCH "$api/user/applications/oauth2/$(printf '%s' "$app" | jq -r .id)" -d @-)
  if [ -z "$secret" ]; then why="secret missing"; elif [ "$have" != 3 ]; then why="secret lacks keys"; else why="client_id mismatch"; fi
  why="$why, client secret regenerated"
fi
SESSION_KEY=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
export SESSION_KEY
manifest=$(printf '%s' "$creds" | jq -c '{apiVersion: "v1", kind: "Secret", type: "Opaque",
  metadata: {name: "console-oauth", namespace: "factory"},
  stringData: {client_id: .client_id, client_secret: .client_secret, session_key: $ENV.SESSION_KEY}}')
if [ -n "$secret" ]; then
  printf '%s' "$manifest" | kubectl replace -f - >/dev/null
else
  printf '%s' "$manifest" | kubectl create -f - >/dev/null
fi
if [ -n "$(kubectl -n factory get deployment factoryd --ignore-not-found -o name)" ]; then
  kubectl -n factory rollout restart deployment/factoryd >/dev/null || {
    echo "console-oauth: $why, secret written, factoryd restart FAILED: restart it by hand (kubectl -n factory rollout restart deployment/factoryd)"
    trap - EXIT
    exit 1
  }
  restarted="factoryd restarted"
else
  restarted="factoryd not deployed yet"
fi
echo "console-oauth: $why, session_key minted, secret written, $restarted"
