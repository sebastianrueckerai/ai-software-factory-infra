#!/bin/sh
# Renders a kustomization and checks that every ConfigMap key a volume item
# names exists in the rendered ConfigMap of that name. The busybox test of
# setup.sh cannot see this: kubelet refuses a volume whose item key its
# ConfigMap lacks, and the pod never starts.
#   sh scripts/cache-setup-test/keys.sh k8s/platform/local-path
# Check that the check bites: sh scripts/cache-setup-test/keys.sh --self-test
set -eu
check() {
  awk '
    function doc(  i) { if (kind == "ConfigMap") for (i = 0; i < nd; i++) have[name SUBSEP dk[i]] = 1; nd = 0; kind = ""; name = ""; indata = 0; inmeta = 0 }
    function flush(  i) { for (i = 0; i < n; i++) want[ref SUBSEP pk[i]] = 1; n = 0; ref = ""; incm = 0 }
    /^---/ { if (incm) flush(); doc(); next }
    /^kind: / { kind = $2 }
    /^metadata:/ { inmeta = 1; next }
    inmeta && /^  name: / { name = $2; inmeta = 0 }
    /^data:/ { indata = 1; next }
    indata && /^[^ ]/ { indata = 0 }
    indata && /^  [^ ]+:/ { k = $1; sub(/:$/, "", k); dk[nd++] = k }
    /^ *(- )?configMap:$/ { if (incm) flush(); incm = 1; n = 0; ref = ""; base = index($0, "configMap:"); next }
    incm && match($0, /[^ ]/) <= base { flush() }
    incm && /^ *name: / { ref = $2; next }
    incm && /^ *- key: / { pk[n++] = $3; next }
    END {
      if (incm) flush()
      doc()
      for (w in want) if (!(w in have)) { split(w, p, SUBSEP); printf "ConfigMap %s has no key %s\n", p[1], p[2]; bad = 1 }
      exit bad
    }'
}
if [ "${1:-}" = --self-test ]; then
  f=$(mktemp)
  printf '%s\n' 'data:' '  setup.sh: |' '    x' 'kind: ConfigMap' 'metadata:' '  name: c' '---' 'kind: DaemonSet' 'spec:' '  volumes:' '  - name: s' '    configMap:' '      items:' '      - key: setup' '        path: setup.sh' '      name: c' > "$f"
  if check < "$f" > /dev/null; then echo "FAIL the check passes a missing key"; rm -f "$f"; exit 1; fi
  sed -i 's/key: setup$/key: setup.sh/' "$f"
  check < "$f" || { echo "FAIL the check refuses a present key"; rm -f "$f"; exit 1; }
  rm -f "$f"; echo "PASS keys.sh self-test"; exit 0
fi
kubectl kustomize "$1" | check && echo "PASS every ConfigMap volume key of $1 exists"
