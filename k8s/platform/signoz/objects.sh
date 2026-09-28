#!/bin/sh
# shellcheck shell=busybox
# Puts SigNoz's objects from Git into SigNoz: the dashboards
# (dashboards/*.json), the alert rules (alerts/*.json) and the retention of
# traces, metrics and logs (on the local volume for HOT_DAYS, then on the S3
# volume, deleted after RETENTION_DAYS). SigNoz keeps all three on
# local-path volumes, which a rebuild loses. Each file holds its object as
# SigNoz v0.143.0 returns it, so an untouched object compares equal and is
# left alone.
set -euo pipefail
trap '[ $? = 0 ] || echo "signoz-objects: failed"' EXIT
base=http://signoz.platform.svc.cluster.local:8080
ORG_ID=$(curl -fsS -G "$base/api/v2/sessions/context" --data-urlencode "email=$SIGNOZ_EMAIL" --data-urlencode "ref=$base" |
  jq -er '.data.orgs[0].id')
export ORG_ID
umask 077
jq -nc '{email: $ENV.SIGNOZ_EMAIL, password: $ENV.SIGNOZ_PASSWORD, orgId: $ENV.ORG_ID}' |
  curl -fsS -X POST "$base/api/v2/sessions/email_password" -H 'Content-Type: application/json' -d @- |
  jq -r '"Authorization: Bearer " + .data.accessToken' >/tmp/auth
f() { curl -fsS -H @/tmp/auth -H 'Content-Type: application/json' "$@"; }
say() { echo "signoz-objects: $*"; }

f "$base/api/v2/dashboards?limit=200" >/tmp/dashboards
for file in /dashboards/*.json; do
  title=$(jq -r .spec.display.name "$file")
  id=$(jq -r --arg t "$title" '[.data.dashboards[] | select(.spec.display.name == $t)][0].id // ""' /tmp/dashboards)
  if [ -z "$id" ]; then
    id=$(f -X POST "$base/api/v2/dashboards" -d @"$file" | jq -er .data.id)
    say "dashboard '$title' created ($id)"
  elif [ "$(f "$base/api/v2/dashboards/$id" | jq -S .data.spec)" = "$(jq -S .spec "$file")" ]; then
    say "dashboard '$title' no change"
  else
    f -X PUT "$base/api/v2/dashboards/$id" -d @"$file" >/dev/null
    say "dashboard '$title' updated ($id)"
  fi
done

f "$base/api/v1/rules" >/tmp/rules
for file in /alerts/*.json; do
  title=$(jq -r .alert "$file")
  jq -c --arg t "$title" '[.data.rules[] | select(.alert == $t)][0] // empty' /tmp/rules >/tmp/rule
  if [ ! -s /tmp/rule ]; then
    id=$(f -X POST "$base/api/v1/rules" -d @"$file" | jq -er .data.id)
    say "alert rule '$title' created ($id)"
  elif [ "$(jq -S 'del(.id, .state, .createAt, .createBy, .updateAt, .updateBy)' /tmp/rule)" = "$(jq -S . "$file")" ]; then
    say "alert rule '$title' no change"
  else
    id=$(jq -r .id /tmp/rule)
    f -X PUT "$base/api/v1/rules/$id" -d @"$file" >/dev/null
    say "alert rule '$title' updated ($id)"
  fi
done

# SigNoz records a TTL's status. A set lasts seconds, so a pending one ten
# minutes later is stuck: SigNoz refuses every set until its row is gone
# (README, Telemetry). A failed one is applied again. Both fail this run.
rc=0
retention() { # signal, [delete, move] as SigNoz reports it, as wanted, status, the call that sets it
  sig=$1 have=$2 want=$3 status=$4
  shift 4
  if [ "$status" = pending ] && [ "$have" = "$want" ]; then
    say "retention $sig no change"
  elif [ "$status" = pending ]; then
    say "retention $sig pending: SigNoz holds a stuck TTL row"
    rc=1
  elif [ "$status" != failed ] && [ "$have" = "$want" ]; then
    say "retention $sig no change"
  else
    [ "$status" = failed ] && { say "retention $sig: the last set failed"; rc=1; }
    "$@" >/dev/null
    say "retention $sig set: to S3 after $HOT_DAYS days, deleted after $RETENTION_DAYS days"
  fi
}
for sig in traces metrics; do
  f "$base/api/v1/settings/ttl?type=$sig" >/tmp/ttl
  retention "$sig" "$(jq -c --arg s "$sig" '[.[$s + "_ttl_duration_hrs"], .[$s + "_move_ttl_duration_hrs"]]' /tmp/ttl)" \
    "[$((RETENTION_DAYS * 24)),$((HOT_DAYS * 24))]" "$(jq -r .status /tmp/ttl)" \
    f -X POST "$base/api/v1/settings/ttl?type=$sig&duration=$((RETENTION_DAYS * 24))h&coldStorage=s3&toColdDuration=$((HOT_DAYS * 24))h"
done
f "$base/api/v2/settings/ttl" >/tmp/ttl
retention logs "$(jq -c '[.default_ttl_days, .cold_storage_ttl_days]' /tmp/ttl)" \
  "[$RETENTION_DAYS,$HOT_DAYS]" "$(jq -r .status /tmp/ttl)" \
  f -X POST "$base/api/v2/settings/ttl" -d "$(jq -nc --argjson d "$RETENTION_DAYS" --argjson h "$HOT_DAYS" \
    '{type: "logs", defaultTTLDays: $d, ttlConditions: [], coldStorageVolume: "s3", coldStorageDurationDays: $h}')"
exit $rc
