#!/usr/bin/env bash
# End-to-end test of scripts/cosign-keygen.sh against a throwaway OpenBao
# 2.6.3 (the cluster's) in docker, kubectl stubbed onto it; needs docker
# and a checkout of the code repository for Dockerfile.runner:
#   scripts/cosign-keygen-test/test.sh ~/repos/ai-software-factory-code
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
code=${1:?usage: $0 <code checkout>}
t=$(mktemp -d)
mkdir -p "$t/tmp" "$t/code/k8s"
cp "$code/Dockerfile.runner" "$t/code/"
export TMPDIR=$t/tmp PATH="$here/bin:$PATH" BAO_CONTAINER=cosign-keygen-test-$$
docker run -d --rm --name "$BAO_CONTAINER" -e BAO_DEV_ROOT_TOKEN_ID=root-test -e BAO_ADDR=http://127.0.0.1:8200 \
  quay.io/openbao/openbao:2.6.3@sha256:a60afafda36337abe833c4a63894bf1095098f29abea4091e7e555a33dd52889 server -dev >/dev/null
trap 'docker stop "$BAO_CONTAINER" >/dev/null; rm -r "$t"' EXIT
until docker exec "$BAO_CONTAINER" bao status >/dev/null 2>&1; do sleep 1; done
bao() { docker exec -i -e BAO_TOKEN=root-test "$BAO_CONTAINER" bao "$@"; }
bao secrets enable -path=factory -version=2 kv >/dev/null
version() { bao kv metadata get -mount=factory -format=json cosign 2>/dev/null | jq -r .data.current_version; }
# the pair OpenBao holds makes k8s/cosign.pub, checked apart from the script
derives() {
  bao kv get -mount=factory -format=json cosign |
    docker run --rm -i --read-only --network none --log-driver none --tmpfs /work:mode=1777 -e HOME=/work \
      -v "$t/code/k8s:/k8s:ro" factory-cosign-keygen sh -ec '
      j=$(cat)
      COSIGN_PRIVATE_KEY=$(printf "%s" "$j" | jq -r .data.data.private_key) COSIGN_PASSWORD=$(printf "%s" "$j" | jq -r .data.data.password) \
        cosign public-key --key env://COSIGN_PRIVATE_KEY 2>/dev/null | cmp -s - /k8s/cosign.pub'
}
pass=0 fail=0
# case NAME TOKEN WANT_EXIT WANT_LINE WANT_VERSION WANT_PUB(new|same) ARGS...
case_() {
  local name=$1 token=$2 want_rc=$3 want_out=$4 want_version=$5 want_pub=$6; shift 6
  local before rc out why=""
  before=$(cat "$t/code/k8s/cosign.pub" 2>/dev/null)
  out=$(BAO_TOKEN=$token "$here/../cosign-keygen.sh" "$@" "$t/code" 2>&1); rc=$?
  [ "$rc" = "$want_rc" ] || why="$why exit $rc, want $want_rc;"
  grep -qxF -- "$want_out" <<<"$out" || why="$why no line [$want_out];"
  [ "$(version)" = "$want_version" ] || why="$why version [$(version)], want [$want_version];"
  if [ "$want_pub" = new ]; then
    { [ "$(cat "$t/code/k8s/cosign.pub")" != "$before" ] && head -n1 "$t/code/k8s/cosign.pub" | grep -qx -- '-----BEGIN PUBLIC KEY-----' && derives; } ||
      why="$why no new cosign.pub of the stored pair;"
  else
    [ "$(cat "$t/code/k8s/cosign.pub" 2>/dev/null)" = "$before" ] || why="$why cosign.pub changed;"
  fi
  [ -z "$(ls -A "$TMPDIR")" ] || why="$why left $(ls -A "$TMPDIR") in TMPDIR;"
  ! grep -rqs "PRIVATE KEY" "$t" || why="$why a private key in a file;"
  if [ -z "$why" ]; then pass=$((pass+1)); echo "PASS $name"; else fail=$((fail+1)); printf 'FAIL %s:%s\n%s\n' "$name" "$why" "$out"; fi
}
case_ fresh root-test 0 "cosign-keygen: factory/cosign written to OpenBao and checked; its public half is $t/code/k8s/cosign.pub" 1 new
case_ exists-without-rotate root-test 1 "cosign-keygen: OpenBao holds factory/cosign already; --rotate replaces it" 1 same
case_ rotate root-test 0 "cosign-keygen: factory/cosign written to OpenBao and checked; its public half is $t/code/k8s/cosign.pub" 2 new --rotate
case_ token-refused wrong-token 1 "cosign-keygen: cannot read factory/cosign (OpenBao sealed, the token refused, or no mount factory)" 2 same --rotate
echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
