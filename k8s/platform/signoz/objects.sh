#!/bin/sh
# shellcheck shell=busybox
# Puts SigNoz's objects from Git into SigNoz: factoryd's viewer account,
# the webhook channel factoryd, the dashboards (dashboards/*.json), the
# platform's alert rules (alerts/*.json), every project's alert rules (the
# ConfigMaps labelled factory/signoz-rules=true in its namespaces, ruling
# 159) and the retention of traces, metrics and logs (on the local volume
# for HOT_DAYS, then on the S3 volume, deleted after RETENTION_DAYS).
# SigNoz keeps all of it on local-path volumes, which a rebuild loses. Each
# platform file holds its object as SigNoz v0.143.0 returns it, so an
# untouched object compares equal and is left alone.
set -euo pipefail
rc=0
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

# factoryd reads the alerts as a viewer (secret signoz-factoryd): its login
# proves the account; otherwise it is created, or its password reset.
viewer_login() {
  jq -nc '{email: $ENV.VIEWER_EMAIL, password: $ENV.VIEWER_PASSWORD, orgId: $ENV.ORG_ID}' |
    curl -fsS -o /dev/null -X POST "$base/api/v2/sessions/email_password" -H 'Content-Type: application/json' -d @- 2>/dev/null
}
if viewer_login; then
  say "viewer $VIEWER_EMAIL no change"
else
  uid=$(f "$base/api/v2/users" | jq -r '[.data[] | select(.email == $ENV.VIEWER_EMAIL)][0].id // ""')
  if [ -z "$uid" ]; then
    role=$(f "$base/api/v1/roles" | jq -er '[.data[] | select(.name == "signoz-viewer")][0].id')
    uid=$(jq -nc --arg r "$role" '{displayName: "factoryd", email: $ENV.VIEWER_EMAIL, userRoles: [{id: $r}]}' |
      f -X POST "$base/api/v2/users" -d @- | jq -er .data.id)
    say "viewer $VIEWER_EMAIL created ($uid)"
  fi
  f "$base/api/v2/users/$uid/reset_password_tokens" | jq -c '{token: .data.token, password: $ENV.VIEWER_PASSWORD}' |
    f -X POST "$base/api/v2/factor_password/reset" -d @- >/dev/null
  viewer_login
  say "viewer $VIEWER_EMAIL password set"
fi

# The webhook channel factoryd: SigNoz posts firing and resolved alerts to
# factoryd's intake with the basic auth of secret signoz-webhook.
jq -nc '{name: "factoryd", webhook_configs: [{send_resolved: true,
    url: "http://factoryd.factory.svc.cluster.local:8080/webhooks/signoz",
    http_config: {basic_auth: {username: "signoz", password: $ENV.SIGNOZ_WEBHOOK_PASSWORD}}}]}' >/tmp/channel
f "$base/api/v1/channels" >/tmp/channels
id=$(jq -r '[.data[] | select(.name == "factoryd")][0].id // ""' /tmp/channels)
shape='.webhook_configs[0] | [.url, .send_resolved, .http_config.basic_auth.username, .http_config.basic_auth.password]'
if [ -z "$id" ]; then
  f -X POST "$base/api/v1/channels" -d @/tmp/channel >/dev/null
  say "channel factoryd created"
elif [ "$(jq -c "[.data[] | select(.id == \"$id\")][0].data | fromjson | $shape" /tmp/channels)" = "$(jq -c "$shape" /tmp/channel)" ]; then
  say "channel factoryd no change"
else
  f -X PUT "$base/api/v1/channels/$id" -d @/tmp/channel >/dev/null
  say "channel factoryd updated ($id)"
fi

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
  jq -c --arg t "$title" '[.data.rules[] | select(.alert == $t and (.labels.project // "") == "")][0] // empty' /tmp/rules >/tmp/rule
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

# A project's rules (ruling 159): each key of a ConfigMap labelled
# factory/signoz-rules=true in a namespace labelled factory/project is one
# rule in SigNoz's v2alpha1 shape, bound to that namespace: every builder
# query filters on it, as a resource attribute (spans, metrics, pod logs)
# or a log attribute (the collector's Kubernetes events carry it only so;
# the bare key resolves to the resource alone), the labels namespace and project are set, the value
# is annotation value, and it notifies the channel factoryd. Only builder
# queries and formulas are taken, and filters whose brackets and quotes
# close within themselves, so none reaches past the bound, and one key per
# alert name in a namespace. A refused rule is the project's to fix: the
# run logs it and leaves its namespace's rules as they are, and does not
# fail (the platform's Job failed alert is not a project's). The rule's
# sha256 in annotation factory_rule_sha256 tells an unchanged rule,
# whatever SigNoz adds to its stored form; a rule no ConfigMap holds any
# more is deleted.
kubectl get namespaces -l factory/project -o json |
  jq -c '[.items[] | {key: .metadata.name, value: .metadata.labels["factory/project"]}] | from_entries' >/tmp/projects
kubectl get configmaps -A -l factory/signoz-rules=true -o json |
  jq -c --slurpfile p /tmp/projects '.items[] | .metadata.namespace as $ns | select($p[0][$ns]) |
    (.data // {}) | to_entries[] | {ns: $ns, project: $p[0][$ns], key, text: .value}' >/tmp/project-rules
cat >/tmp/bind.jq <<'JQ'
def closed:
  reduce (explode[] | [.] | implode) as $c ({d: 0, q: null, ok: true};
    if .q != null then (if $c == .q then .q = null else . end)
    elif $c == "'" or $c == "\"" then .q = $c
    elif $c == "(" then .d += 1
    elif $c == ")" then (.d -= 1 | if .d < 0 then .ok = false else . end)
    else . end)
  | .ok and .d == 0 and .q == null;
.ns as $ns | .project as $project | (.text | fromjson) as $r
| if ($r | type) != "object" or ($r.alert | type) != "string" or $r.alert == "" then error("no alert name")
  elif $r.schemaVersion != "v2alpha1" then error("schemaVersion must be v2alpha1")
  elif $r.condition.compositeQuery.queryType != "builder" then error("queryType must be builder")
  elif any($r.condition.compositeQuery.queries[]; .type != "builder_query" and .type != "builder_formula") then error("only builder queries and formulas")
  elif any($r.condition.compositeQuery.queries[] | select(.type == "builder_query");
      (.spec.signal | IN("metrics", "traces", "logs") | not)
      or ((.spec.filter.expression // "") | test("\\\\") or (closed | not))) then error("a query's signal or filter is refused")
  else $r
    | .labels = ((.labels // {}) + {namespace: $ns, project: $project})
    | .annotations = ({value: "{{$value}}"} + (.annotations // {}))
    | .condition.compositeQuery.queries |= map(if .type == "builder_query" then
        .spec.filter.expression = ("(resource.k8s.namespace.name = '" + $ns + "' OR attribute.k8s.namespace.name = '" + $ns + "')" +
          (if (.spec.filter.expression // "") == "" then "" else " AND (" + .spec.filter.expression + ")" end))
      else . end)
    | .condition.thresholds.spec |= map(.channels = ["factoryd"])
    | .notificationSettings = ((.notificationSettings // {}) + {usePolicy: false})
  end
JQ
: >/tmp/held
: >/tmp/wanted
while read -r entry; do
  where=$(echo "$entry" | jq -r '.ns + "/" + .key')
  if ! rule=$(echo "$entry" | jq -c -f /tmp/bind.jq 2>/tmp/why); then
    say "project rule $where refused: $(tail -c 300 /tmp/why)"
    echo "$entry" | jq -r .ns >>/tmp/held
    continue
  fi
  sha=$(printf '%s' "$rule" | sha256sum | cut -c1-64)
  echo "$rule" | jq -c --arg s "$sha" '.annotations.factory_rule_sha256 = $s' >/tmp/rule-new
  title=$(jq -r .alert /tmp/rule-new) ns=$(jq -r .labels.namespace /tmp/rule-new)
  key=$(jq -c '{alert, ns: .labels.namespace}' /tmp/rule-new)
  if grep -qxF "$key" /tmp/wanted; then
    say "project rule $where refused: another key in $ns names the alert '$title'"
    echo "$ns" >>/tmp/held
    continue
  fi
  echo "$key" >>/tmp/wanted
  jq -c --arg t "$title" --arg ns "$ns" '[.data.rules[] | select(.alert == $t and .labels.namespace == $ns and .labels.project != null)][0] // empty' /tmp/rules >/tmp/rule
  if [ ! -s /tmp/rule ]; then
    id=$(f -X POST "$base/api/v1/rules" -d @/tmp/rule-new | jq -er .data.id)
    say "project rule '$title' in $ns created ($id)"
  elif [ "$(jq -r '.annotations.factory_rule_sha256 // ""' /tmp/rule)" = "$sha" ]; then
    say "project rule '$title' in $ns no change"
  else
    id=$(jq -r .id /tmp/rule)
    f -X PUT "$base/api/v1/rules/$id" -d @/tmp/rule-new >/dev/null
    say "project rule '$title' in $ns updated ($id)"
  fi
done </tmp/project-rules
jq -r --slurpfile w /tmp/wanted --rawfile h /tmp/held '.data.rules[] | select(.labels.project != null)
    | {alert, ns: .labels.namespace} as $k | select(($w | index($k)) == null and ($h | split("\n") | index($k.ns)) == null)
    | [.id, $k.ns, .alert] | @tsv' /tmp/rules |
  while IFS="$(printf '\t')" read -r id ns title; do
    f -X DELETE "$base/api/v1/rules/$id" >/dev/null
    say "project rule '$title' in $ns deleted ($id): no ConfigMap holds it"
  done

# SigNoz records a TTL's status. A set lasts seconds, so a pending one ten
# minutes later is stuck: SigNoz refuses every set until its row is gone
# (README, Telemetry). A failed one is applied again. Both fail this run.
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
