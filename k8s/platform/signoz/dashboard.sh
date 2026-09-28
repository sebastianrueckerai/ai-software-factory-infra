#!/bin/sh
# shellcheck shell=busybox
# Puts dashboards/factory-pipeline.json into SigNoz: SigNoz keeps dashboards
# in its own database on a local-path volume, which a rebuild loses. The
# file holds the spec exactly as SigNoz v0.143.0 GET returns it, so an untouched
# dashboard compares equal and is left alone.
set -euo pipefail
trap '[ $? = 0 ] || echo "signoz-dashboard: failed"' EXIT
base=http://signoz.platform.svc.cluster.local:8080
file=/dashboards/factory-pipeline.json
title=$(jq -r .spec.display.name "$file")
ORG_ID=$(curl -fsS -G "$base/api/v2/sessions/context" --data-urlencode "email=$SIGNOZ_EMAIL" --data-urlencode "ref=$base" |
  jq -er '.data.orgs[0].id')
export ORG_ID
umask 077
jq -nc '{email: $ENV.SIGNOZ_EMAIL, password: $ENV.SIGNOZ_PASSWORD, orgId: $ENV.ORG_ID}' |
  curl -fsS -X POST "$base/api/v2/sessions/email_password" -H 'Content-Type: application/json' -d @- |
  jq -r '"Authorization: Bearer " + .data.accessToken' >/tmp/auth
f() { curl -fsS -H @/tmp/auth -H 'Content-Type: application/json' "$@"; }
id=$(f "$base/api/v2/dashboards?limit=200" | jq -r --arg t "$title" '[.data.dashboards[] | select(.spec.display.name == $t)][0].id // ""')
if [ -z "$id" ]; then
  id=$(f -X POST "$base/api/v2/dashboards" -d @"$file" | jq -er .data.id)
  echo "signoz-dashboard: created '$title' ($id)"
elif [ "$(f "$base/api/v2/dashboards/$id" | jq -S .data.spec)" = "$(jq -S .spec "$file")" ]; then
  echo "signoz-dashboard: no change"
else
  f -X PUT "$base/api/v2/dashboards/$id" -d @"$file" >/dev/null
  echo "signoz-dashboard: updated '$title' ($id)"
fi
