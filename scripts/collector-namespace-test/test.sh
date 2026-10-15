#!/usr/bin/env bash
# Test of SigNoz's collector config (k8s/platform/signoz/helmrelease.yaml):
# an app cannot name another namespace in its telemetry. The app pipelines
# as the HelmRelease writes them run in the HelmRelease's collector image,
# file exporters in place of ClickHouse, against a stub Kubernetes API that
# knows one pod, tenant-a's app-0. The collector starts before the API:
# while it cannot read the pods it takes no telemetry. Then that pod's
# address sends a log, a metric and a span that name namespace victim on
# the resource and on the record, in both forms the alert routing reads;
# an address no pod has sends the same; the k8s-infra port gets a log
# naming victim, which it must keep. The tools run in alpine/k8s of the
# code repository's upstream-images.txt. On a host with docker:
#   scripts/collector-namespace-test/test.sh
set -euo pipefail
TOOLS=docker.io/alpine/k8s:1.36.1@sha256:51865f04b31c2f1d18db2c0964f4186d359007beedb9e478d342a7e504c0a3f3
net=collector-ns-test-$$ subnet=172.31.247
t=$(cd "$(dirname "$0")" && pwd)
w=$(mktemp -d)
cleanup() {
  status=$?
  docker rm -f "$net-api" "$net-collector" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  rm -r "$w"
  exit "$status"
}
trap cleanup EXIT
# the collector runs as its image's user
chmod 755 "$w" && mkdir "$w/out" && chmod 777 "$w/out"
tools() { docker run --rm --entrypoint "$1" -v "$t:/t:ro" -v "$w:/w" "${@:2}"; }

helmrelease=$t/../../k8s/platform/signoz/helmrelease.yaml
cp "$helmrelease" "$w/helmrelease.yaml"
collector=docker.io/$(tools yq "$TOOLS" -r 'select(.kind == "HelmRelease") | .spec.values.otelCollector.image | .repository + ":" + .tag' /w/helmrelease.yaml)
tools yq "$TOOLS" -o=json 'select(.kind == "HelmRelease") | .spec.values.otelCollector.config' /w/helmrelease.yaml >"$w/values.json"
# the test's collector: the HelmRelease's receiver of the k8s-infra port, its
# processors (k8sattributes reading the stub through a kubeconfig) and each
# pipeline's processors that the HelmRelease defines, in its order
tools python3 "$TOOLS" -c '
import json
v = json.load(open("/w/values.json"))
procs, pipes = v["processors"], v["service"]["pipelines"]
for s in ("logs", "metrics", "traces"):
    first = pipes[s]["processors"][:3]
    assert first == ["resource/namespace", "attributes/namespace", "k8sattributes/namespace"], (s, first)
procs["k8sattributes/namespace"]["auth_type"] = "kubeConfig"
own = lambda s: [p for p in pipes[s]["processors"] if p in procs]
pipelines = {s: {"receivers": ["otlp"], "processors": own(s), "exporters": ["file/app"]} for s in ("logs", "metrics", "traces")}
pipelines["logs/k8s-infra"] = {"receivers": pipes["logs/k8s-infra"]["receivers"], "processors": own("logs/k8s-infra"), "exporters": ["file/k8s-infra"]}
json.dump({"receivers": {"otlp": {"protocols": {"http": {"endpoint": "0.0.0.0:4318"}}}, "otlp/k8s-infra": v["receivers"]["otlp/k8s-infra"]},
           "processors": procs, "exporters": {"file/app": {"path": "/out/app.json"}, "file/k8s-infra": {"path": "/out/k8s-infra.json"}},
           "service": {"pipelines": pipelines}}, open("/w/config.yaml", "w"))
'
echo "PASS the app pipelines run resource/namespace, attributes/namespace and k8sattributes/namespace first"
cat >"$w/kubeconfig" <<KUBE
apiVersion: v1
kind: Config
clusters: [{name: stub, cluster: {server: "http://$subnet.10:8080"}}]
users: [{name: stub, user: {}}]
contexts: [{name: stub, context: {cluster: stub, user: stub}}]
current-context: stub
KUBE
chmod 644 "$w/kubeconfig"

docker network create --subnet "$subnet.0/24" "$net" >/dev/null
docker run -d --name "$net-collector" --network "$net" --ip "$subnet.11" -e KUBECONFIG=/w/kubeconfig \
  -v "$w:/w:ro" -v "$w/out:/out" "$collector" --config /w/config.yaml --copy-path /out/copy.yaml >/dev/null
send() { docker run --rm --network "$net" --ip "$1" --entrypoint python3 -v "$t:/t:ro" "$TOOLS" /t/send.py "${@:2}"; }
sleep 5
if send "$subnet.12" "http://$subnet.11:4318" app-a logs 2>/dev/null; then
  echo "FAIL the collector took telemetry before it could read the pods"; exit 1
fi
echo "PASS the collector takes no telemetry while it cannot read the pods"
docker run -d --name "$net-api" --network "$net" --ip "$subnet.10" -e POD_IP="$subnet.12" --entrypoint python3 \
  -v "$t:/t:ro" "$TOOLS" -u /t/stub.py >/dev/null
for _ in $(seq 40); do
  docker logs "$net-collector" 2>&1 | grep -q "Everything is ready" && break
  sleep 1
done
docker logs "$net-collector" 2>&1 | grep -q "Everything is ready" || { docker logs "$net-collector" 2>&1 | tail -20; exit 1; }
send "$subnet.12" "http://$subnet.11:4318" app-a
send "$subnet.13" "http://$subnet.11:4318" stranger
send "$subnet.13" "http://$subnet.11:4319" k8s-infra logs
sleep 3
docker stop -t 10 "$net-collector" >/dev/null
tools python3 "$TOOLS" /t/check.py /w/out/app.json /w/out/k8s-infra.json
