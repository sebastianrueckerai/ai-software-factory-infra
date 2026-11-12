#!/bin/sh
# Test of k8s/platform/local-path/setup.sh on a throwaway tree, in the helper pod's image:
#   docker run --rm -v "$PWD/scripts/cache-setup-test:/t:ro" -v "$PWD/k8s/platform/local-path:/s:ro" busybox sh /t/test.sh
# and sh scripts/cache-setup-test/keys.sh k8s/platform/local-path (with kubectl): every ConfigMap key a volume names exists in the rendered kustomization
root=/var/lib/factory-cache other=/var/mnt/local-path-provisioner
now=$(date +%s) day=86400
pass=0; fail=0
ok() { if eval "$2"; then pass=$((pass+1)); echo "PASS $1"; else fail=$((fail+1)); echo "FAIL $1: $2"; fi; }
aged() { touch -d "@$((now - $2 * day))" "$1"; }
mib2() { dd if=/dev/zero of="$1" bs=1M count=2 2>/dev/null; }
claim() { VOL_DIR=$1 sh /s/setup.sh -p "$1" -s 1073741824 -m Filesystem -a create; }
fresh() { [ -n "$(find "$1" -mmin -2 2>/dev/null)" ]; }

mkdir -p "$root/.claimed" "$root/cache-old" "$root/cache-young" "$root/cache-legacy" \
  "$root/cache-me/go-build/aa" "$other/pvc-1_ns_data"
chmod 0755 "$root/cache-me"
mib2 "$root/cache-old/x"
touch "$root/.claimed/cache-old" "$root/.claimed/cache-young" "$root/.claimed/cache-me"
aged "$root/.claimed/cache-old" 15; aged "$root/.claimed/cache-young" 13; aged "$root/.claimed/cache-me" 15
mib2 "$root/cache-me/go-build/aa/old-d"; aged "$root/cache-me/go-build/aa/old-d" 4
mib2 "$root/cache-me/go-build/aa/new-d"
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
ok "a claim directory made 0755 (kubelet's DirectoryOrCreate) is 0777 after the claim" '[ "$(stat -c %a "$root/cache-me")" = 777 ]'
ok "above the cap a file idle 4 days is removed" '[ ! -e "$root/cache-me/go-build/aa/old-d" ]'
ok "above the cap a fresh file stays" '[ -e "$root/cache-me/go-build/aa/new-d" ]'
ok "above the cap the directories stay" '[ -d "$root/cache-me/go-build/aa" ]'

claim "$root/cache-young"; rc=$?
ok "default cap: exit 0" '[ $rc = 0 ]'
ok "below the default cap a file idle 4 days stays" '[ -e "$root/cache-young/old-d" ]'

claim "$root/cache-new"; rc=$?
ok "first claim: exit 0" '[ $rc = 0 ]'
ok "first claim: the directory is made 0777" '[ "$(stat -c %a "$root/cache-new")" = 777 ]'
ok "first claim: stamped" 'fresh "$root/.claimed/cache-new"'
ok "the stamps are not in a cache" '[ ! -e "$root/cache-new/.claimed" ] && [ ! -e "$root/cache-me/.claimed" ]'

hours() { touch -d "@$((now - $2 * 3600))" "$1"; }
mkdir -p "$root/cache-busy/go-build/bb" "$root/cache-busy/go/bin" "$root/cache-calm/go-build/cc"
for f in 30h 3h 1h; do mib2 "$root/cache-busy/go-build/bb/$f-d"; hours "$root/cache-busy/go-build/bb/$f-d" "${f%h}"; done
mib2 "$root/cache-busy/go/bin/tool"; hours "$root/cache-busy/go/bin/tool" 30
FACTORY_CACHE_CAP_MB=3 claim "$root/cache-busy"; rc=$?
ok "a cache all younger than 3 days above the cap: exit 0" '[ $rc = 0 ]'
ok "above the cap a build cache file unchanged 30 hours is removed" '[ ! -e "$root/cache-busy/go-build/bb/30h-d" ]'
ok "still above the cap a build cache file unchanged 3 hours is removed" '[ ! -e "$root/cache-busy/go-build/bb/3h-d" ]'
ok "a build cache file used within 2 hours stays, though above the cap" '[ -e "$root/cache-busy/go-build/bb/1h-d" ]'
ok "an installed binary younger than 3 days stays" '[ -e "$root/cache-busy/go/bin/tool" ]'
for f in 30h 3h 1h; do mib2 "$root/cache-calm/go-build/cc/$f-d"; hours "$root/cache-calm/go-build/cc/$f-d" "${f%h}"; done
FACTORY_CACHE_CAP_MB=6 claim "$root/cache-calm"; rc=$?
ok "a cache 6 MiB plus its directories above a 6 MiB cap: exit 0" '[ $rc = 0 ]'
ok "the oldest build cache file goes first" '[ ! -e "$root/cache-calm/go-build/cc/30h-d" ]'
ok "under the cap again, the younger ones stay" '[ -e "$root/cache-calm/go-build/cc/3h-d" ] && [ -e "$root/cache-calm/go-build/cc/1h-d" ]'

mv "$root/.claimed" /tmp/stamps; : > "$root/.claimed"
claim "$root/cache-err"; rc=$?
ok "a failing prune (the stamps directory is a file): exit 0" '[ $rc = 0 ]'
ok "a failing prune: the claim directory is made 0777" '[ "$(stat -c %a "$root/cache-err")" = 777 ]'

# the sweep never removes under go/bin, and does not follow a symlink out of a cache
mkdir -p "$root/cache-tool/go/bin" "$root/cache-tool/link-home" "$root/cache-victim"
mib2 "$root/cache-tool/go/bin/tool"; aged "$root/cache-tool/go/bin/tool" 5
mib2 "$root/cache-tool/old-d"; aged "$root/cache-tool/old-d" 5
mib2 "$root/cache-victim/old-d"; aged "$root/cache-victim/old-d" 5
ln -s "$root/cache-victim" "$root/cache-tool/link-home/out"
FACTORY_CACHE_CAP_MB=3 FACTORY_CACHE_SWEEP_SECONDS=1 timeout 3 sh /s/setup.sh sweep
ok "the sweep keeps an installed binary idle 5 days, above the cap" '[ -e "$root/cache-tool/go/bin/tool" ]'
ok "the sweep still removes another file idle 5 days above the cap" '[ ! -e "$root/cache-tool/old-d" ]'
ok "the sweep does not follow a symlink into another cache" '[ -e "$root/cache-victim/old-d" ] && [ -L "$root/cache-tool/link-home/out" ]'

# the sweep prunes every cache directory without a claim, and a failing pass does not end the loop
rm -rf "$root"/cache-*; rm -rf "$root/.claimed"; mkdir -p "$root/cache-sw/go-build/dd" "$root/cache-sw2" "$root/.claimed"
mib2 "$root/cache-sw/go-build/dd/old-d"; hours "$root/cache-sw/go-build/dd/old-d" 30
mib2 "$root/cache-sw/go-build/dd/new-d"; hours "$root/cache-sw/go-build/dd/new-d" 1
mib2 "$root/cache-sw2/stale"; aged "$root/cache-sw2/stale" 4
FACTORY_CACHE_CAP_MB=3 FACTORY_CACHE_SWEEP_SECONDS=1 timeout 4 sh /s/setup.sh sweep; rc=$?
ok "the sweep keeps running until the timeout ends it (143, SIGTERM)" '[ $rc = 143 ]'
ok "the sweep prunes a cache above the cap that no claim touched: the oldest build file goes" '[ ! -e "$root/cache-sw/go-build/dd/old-d" ]'
ok "the sweep keeps a file used within 2 hours" '[ -e "$root/cache-sw/go-build/dd/new-d" ]'
ok "the sweep leaves a cache under the cap alone" '[ -e "$root/cache-sw2/stale" ]'
ok "the sweep makes no stamp" '[ -z "$(ls "$root/.claimed")" ]'

echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
