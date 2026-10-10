#!/bin/sh
# Offline test of k8s/platform/forgejo/console-oauth.sh against stub curl and kubectl, in the CronJob image:
#   docker run --rm --user 1000:1000 -v "$PWD/scripts/console-oauth-test:/t:ro" -v "$PWD/k8s/platform/forgejo:/s:ro" --entrypoint sh alpine/k8s:1.36.1@sha256:692239d739589247c4a791205ed9619c28ae85a21286e19a6211c04a62c56668 /t/test.sh
export PATH="/t/bin:$PATH" FORGEJO_USER=u FORGEJO_PASSWORD=p
pass=0; fail=0
APP='[{"id":7,"name":"factory-console","client_id":"c1"}]'
sec() { jq -nc --arg i "$1" --arg s "$2" '{data: {client_id: ($i | @base64), client_secret: ($s | @base64), session_key: ("k" | @base64)}}'; }
# case NAME SECRET_JSON ACCEPTED_SECRET DOWN WANT_EXIT WANT_LOG WANT_CALLS
case_() {
  STATE=$(mktemp -d); export STATE
  echo "$APP" > "$STATE"/app.json; echo "$3" > "$STATE"/valid
  [ -z "$2" ] || echo "$2" > "$STATE"/secret.json
  [ -z "$4" ] || : > "$STATE"/down
  : > "$STATE"/calls
  out=$(sh /s/console-oauth.sh 2>&1); rc=$?
  calls=$(grep -v '^GET' "$STATE"/calls | tr '\n' ';')
  if [ "$rc" = "$5" ] && [ "$out" = "$6" ] && [ "$calls" = "$7" ]; then pass=$((pass+1)); echo "PASS $1"
  else fail=$((fail+1)); printf 'FAIL %s\n  rc=%s want %s\n  out=%s\n want=%s\n  calls=%s\n want=%s\n' "$1" "$rc" "$5" "$out" "$6" "$calls" "$7"; fi
}
case_ healthy "$(sec c1 s1)" s1 "" 0 "console-oauth: no change" "POST /login/oauth/access_token;"
case_ secret-rejected "$(sec c1 stale)" s1 "" 0 \
  "console-oauth: client secret rejected, client secret regenerated, session_key minted, secret written, factoryd restarted" \
  "POST /login/oauth/access_token;PATCH /api/v1/user/applications/oauth2/7;replace s2;restart;"
case_ forgejo-down "$(sec c1 s1)" s1 down 7 "curl: (7) Failed to connect
console-oauth: failed" "POST /login/oauth/access_token;"
case_ secret-missing "" s1 "" 0 \
  "console-oauth: secret missing, client secret regenerated, session_key minted, secret written, factoryd restarted" \
  "PATCH /api/v1/user/applications/oauth2/7;create s2;restart;"
case_ client-id-mismatch "$(sec c0 s1)" s1 "" 0 \
  "console-oauth: client_id mismatch, client secret regenerated, session_key minted, secret written, factoryd restarted" \
  "PATCH /api/v1/user/applications/oauth2/7;replace s2;restart;"
echo "pass=$pass fail=$fail"; [ $fail = 0 ]
