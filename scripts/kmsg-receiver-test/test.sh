#!/usr/bin/env bash
# Test of the otel-agent's kernel-log receiver (k8s/platform/k8s-infra/
# helmrelease.yaml): the receiver tcplog/kmsg as the HelmRelease writes it
# runs in the HelmRelease's collector image with a file exporter. Two lines
# as Talos's KmsgLogConfig sends them (JSON lines over TCP), the memory
# guard's SIGKILL line and the kernel's oom-kill line, must come out with
# the line as body, talos-time as the record's time and service.name
# talos-kmsg. The tools run in alpine/k8s of the code repository's
# upstream-images.txt. On a host with docker:
#   scripts/kmsg-receiver-test/test.sh
set -euo pipefail
TOOLS=docker.io/alpine/k8s:1.36.1@sha256:51865f04b31c2f1d18db2c0964f4186d359007beedb9e478d342a7e504c0a3f3
net=kmsg-test-$$ subnet=172.31.248
t=$(cd "$(dirname "$0")" && pwd)
w=$(mktemp -d)
cleanup() {
  status=$?
  docker rm -f "$net-collector" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  rm -r "$w"
  exit "$status"
}
trap cleanup EXIT
# the collector runs as its image's user
chmod 755 "$w" && mkdir "$w/out" && chmod 777 "$w/out"
tools() { docker run --rm --entrypoint "$1" -v "$t:/t:ro" -v "$w:/w" "${@:2}"; }

cp "$t/../../k8s/platform/k8s-infra/helmrelease.yaml" "$w/helmrelease.yaml"
agent=$(tools yq "$TOOLS" -r 'select(.kind == "HelmRelease") | .spec.values.otelAgent.image | .repository + ":" + .tag' /w/helmrelease.yaml)
collector=docker.io/$agent
tools yq "$TOOLS" -o=json 'select(.kind == "HelmRelease") | .spec.values.otelAgent' /w/helmrelease.yaml >"$w/values.json"
tools python3 "$TOOLS" -I /t/build.py /w/values.json /w/config.yaml
echo "PASS the agent's logs pipeline takes tcplog/kmsg on its hostPort 5170"

docker network create --subnet "$subnet.0/24" "$net" >/dev/null
docker run -d --name "$net-collector" --network "$net" --ip "$subnet.11" \
  -v "$w:/w:ro" -v "$w/out:/out" "$collector" --config /w/config.yaml >/dev/null
for _ in $(seq 40); do
  docker logs "$net-collector" 2>&1 | grep -q "Everything is ready" && break
  sleep 1
done
docker logs "$net-collector" 2>&1 | grep -q "Everything is ready" || { docker logs "$net-collector" 2>&1 | tail -20; exit 1; }
docker run --rm --network "$net" --ip "$subnet.12" --entrypoint python3 -v "$t:/t:ro" "$TOOLS" -I /t/send.py "$subnet.11" 5170
sleep 3
docker stop -t 10 "$net-collector" >/dev/null
tools python3 "$TOOLS" -I /t/check.py /w/out/logs.json
