#!/usr/bin/env bash
# Makes the factory's cosign key pair (roadmap 46, README "Image signing")
# and writes its private half and password to OpenBao as factory/cosign.
# Both exist only in the tmpfs of a throwaway container (read-only root,
# no network, no log) and go by pipe into `bao kv put` in openbao-0; a
# second such container reads them back by pipe and checks they make the
# public half, the one file written: <code checkout>/k8s/cosign.pub.
# Refuses over an existing pair unless --rotate. cosign comes from the
# checkout's Dockerfile.runner (stage cosign), jq and the shell from a
# line of its upstream-images.txt, at the upstream: the store may not
# serve yet, and a workstation holds no login to it. Reads BAO_TOKEN (the root
# token) from the environment; it goes over stdin, never into an argument,
# and nothing prints it.
#   set -a; . ~/repos/ai-software-factory/.env.seed; set +a
#   BAO_TOKEN="$OPENBAO_ROOT_TOKEN" scripts/cosign-keygen.sh [--rotate] <code checkout>
set -euo pipefail
: "${BAO_TOKEN:?set BAO_TOKEN to the OpenBao root token}"
rotate=false
if [ "${1:-}" = --rotate ]; then
  rotate=true
  shift
fi
code=${1:?usage: BAO_TOKEN=<root token> $0 [--rotate] <code checkout>}
[ -f "$code/Dockerfile.runner" ] && [ -d "$code/k8s" ] || { echo "cosign-keygen: $code is no checkout of the code repository"; exit 1; }
out=$(mktemp -d)
trap '[ $? = 0 ] || echo "cosign-keygen: failed; $code/k8s/cosign.pub untouched"; rm -r "$out"' EXIT
# <script>: runs it in openbao-0 with the token, this function's stdin after it
in_bao() {
  { printf '%s\n' "$BAO_TOKEN"; cat; } | kubectl -n platform exec -i openbao-0 -- sh -c "IFS= read -r BAO_TOKEN; export BAO_TOKEN; $1"
}
# shellcheck disable=SC2016
state=$(in_bao 'if err=$(bao kv metadata get -mount=factory cosign 2>&1 >/dev/null); then echo exists
  else case $err in *"No value found"*) echo none ;; *) printf "%s\n" "$err" >&2 ;; esac; fi' </dev/null)
case $state in
  none) ;;
  exists) $rotate || { echo "cosign-keygen: OpenBao holds factory/cosign already; --rotate replaces it"; exit 1; } ;;
  *) echo "cosign-keygen: cannot read factory/cosign (OpenBao sealed, the token refused, or no mount factory)"; exit 1 ;;
esac
img=factory-cosign-keygen
docker build -q -f "$code/Dockerfile.runner" --target cosign -t $img:cosign "$code" >/dev/null
docker build -q -t $img - >/dev/null <<DOCKERFILE
FROM docker.io/alpine/k8s:1.36.1@sha256:51865f04b31c2f1d18db2c0964f4186d359007beedb9e478d342a7e504c0a3f3
COPY --from=$img:cosign /cosign /usr/local/bin/cosign
DOCKERFILE
run=(docker run --rm --read-only --network none --log-driver none --user "$(id -u):$(id -g)"
  --tmpfs /work:mode=1777 -e HOME=/work -w /work)
# shellcheck disable=SC2016
"${run[@]}" -v "$out:/out" $img sh -ec '
  COSIGN_PASSWORD=$(od -An -tx1 -N32 /dev/urandom | tr -d " \n"); export COSIGN_PASSWORD
  cosign generate-key-pair --output-key-prefix cosign >/dev/null 2>&1
  cp cosign.pub /out/
  jq -n --rawfile k cosign.key "{private_key: \$k, password: env.COSIGN_PASSWORD}"' |
  in_bao 'bao kv put -mount=factory cosign - >/dev/null'
# shellcheck disable=SC2016
in_bao 'bao kv get -mount=factory -format=json cosign' </dev/null |
  "${run[@]}" -i -v "$out:/out:ro" $img sh -ec '
  j=$(cat)
  COSIGN_PRIVATE_KEY=$(printf "%s" "$j" | jq -r .data.data.private_key) COSIGN_PASSWORD=$(printf "%s" "$j" | jq -r .data.data.password) \
    cosign public-key --key env://COSIGN_PRIVATE_KEY 2>/dev/null | cmp -s - /out/cosign.pub'
cp "$out/cosign.pub" "$code/k8s/cosign.pub"
echo "cosign-keygen: factory/cosign written to OpenBao and checked; its public half is $code/k8s/cosign.pub"
