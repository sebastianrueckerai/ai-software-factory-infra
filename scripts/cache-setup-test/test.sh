#!/bin/sh
# Test of k8s/platform/local-path/setup.sh on a throwaway tree, in the helper pod's image:
#   docker run --rm -v "$PWD/scripts/cache-setup-test:/t:ro" -v "$PWD/k8s/platform/local-path:/s:ro" busybox sh /t/test.sh
root=/var/lib/factory-cache other=/var/mnt/local-path-provisioner
now=$(date +%s) day=86400
pass=0; fail=0
ok() { if eval "$2"; then pass=$((pass+1)); echo "PASS $1"; else fail=$((fail+1)); echo "FAIL $1: $2"; fi; }
aged() { touch -d "@$((now - $2 * day))" "$1"; }
mib2() { dd if=/dev/zero of="$1" bs=1M count=2 2>/dev/null; }
claim() { VOL_DIR=$1 sh /s/setup.sh -p "$1" -s 1073741824 -m Filesystem -a create; }
fresh() { [ -n "$(find "$1" -mmin -2 2>/dev/null)" ]; }

mkdir -p "$root/.claimed" "$root/cache-old" "$root/cache-young" "$root/cache-legacy" \
  "$root/cache-me/go-build/aa" "$root/cache-me/go/pkg/mod/m@v1" "$other/pvc-1_ns_data"
mib2 "$root/cache-old/x"
touch "$root/.claimed/cache-old" "$root/.claimed/cache-young" "$root/.claimed/cache-me"
aged "$root/.claimed/cache-old" 15; aged "$root/.claimed/cache-young" 13; aged "$root/.claimed/cache-me" 15
mib2 "$root/cache-me/go-build/aa/old-d"; aged "$root/cache-me/go-build/aa/old-d" 4
mib2 "$root/cache-me/go-build/aa/new-d"
mib2 "$root/cache-me/go/pkg/mod/m@v1/a.go"; aged "$root/cache-me/go/pkg/mod/m@v1/a.go" 4
mib2 "$root/cache-young/old-d"; aged "$root/cache-young/old-d" 4
mib2 "$other/pvc-1_ns_data/old"; aged "$other/pvc-1_ns_data/old" 4

FACTORY_CACHE_CAP_MB=1 claim "$other/pvc-1_ns_data"; rc=$?
ok "another class: exit 0" '[ $rc = 0 ]'
ok "another class: a sibling claimed 15 days ago under the cache root stays" '[ -e "$root/cache-old/x" ]'
ok "another class: its own idle file stays above the cap" '[ -e "$other/pvc-1_ns_data/old" ]'
ok "another class: no stamp" '[ ! -e "$other/.claimed" ] && [ ! -e "$root/.claimed/pvc-1_ns_data" ]'

FACTORY_CACHE_CAP_MB=1 claim "$root/cache-me"; rc=$?
ok "re-claim: exit 0" '[ $rc = 0 ]'
ok "a sibling claimed 15 days ago is removed with its stamp" '[ ! -e "$root/cache-old" ] && [ ! -e "$root/.claimed/cache-old" ]'
ok "a sibling claimed 13 days ago stays" '[ -e "$root/cache-young/old-d" ] && [ -e "$root/.claimed/cache-young" ]'
ok "a sibling without a stamp stays and is stamped now" '[ -d "$root/cache-legacy" ] && fresh "$root/.claimed/cache-legacy"'
ok "the claimed cache stays though idle 15 days, its stamp renewed" '[ -d "$root/cache-me" ] && fresh "$root/.claimed/cache-me"'
ok "above the cap a file idle 4 days is removed" '[ ! -e "$root/cache-me/go-build/aa/old-d" ]'
ok "above the cap a fresh file stays" '[ -e "$root/cache-me/go-build/aa/new-d" ]'
ok "above the cap the module cache stays whole" '[ -e "$root/cache-me/go/pkg/mod/m@v1/a.go" ]'
ok "above the cap the directories stay" '[ -d "$root/cache-me/go-build/aa" ]'

claim "$root/cache-young"; rc=$?
ok "default cap: exit 0" '[ $rc = 0 ]'
ok "below the default cap a file idle 4 days stays" '[ -e "$root/cache-young/old-d" ]'

claim "$root/cache-new"; rc=$?
ok "first claim: exit 0" '[ $rc = 0 ]'
ok "first claim: the directory is made 0777" '[ "$(stat -c %a "$root/cache-new")" = 777 ]'
ok "first claim: stamped" 'fresh "$root/.claimed/cache-new"'
ok "the stamps are not in a cache" '[ ! -e "$root/cache-new/.claimed" ] && [ ! -e "$root/cache-me/.claimed" ]'

echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
