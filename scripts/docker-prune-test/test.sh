#!/bin/sh
# Offline test of k8s/platform/forgejo/runner-chart/docker-prune.sh against a stub docker, du, date and sleep, in the sidecar's image:
#   docker run --rm -v "$PWD/scripts/docker-prune-test:/t:ro" -v "$PWD/k8s/platform/forgejo/runner-chart:/s:ro" --entrypoint sh docker:29.5.2-dind@sha256:6b9cd914eb9c6b342c040a49a27a5eb3804453bae6ecc90f7ff96133595a95e8 /t/test.sh
export PATH="/t/bin:$PATH" KEEP=24h EVERY=3600 CHECK=60 MAX_GIB=24
pass=0; fail=0
ok() { if eval "$2"; then pass=$((pass+1)); echo "PASS $1"; else fail=$((fail+1)); echo "FAIL $1: $2"; fi; }
GIB=1048576
AGE="builder prune -af --filter until=24h;container prune -f --filter until=24h;network prune -f --filter until=24h;"
SHRINK="builder prune -af;container prune -f --filter until=10m;"
# new PASSES KIB: a daemon at second 100000 with no image and no container
new() {
  STATE=$(mktemp -d); export STATE
  echo 100000 > "$STATE/now"; echo 0 > "$STATE/n"; echo "$1" > "$STATE/passes"; echo "$2" > "$STATE/kb"
  : > "$STATE/images"; : > "$STATE/containers"; : > "$STATE/calls"
}
run() { out=$(timeout 10 sh /s/docker-prune.sh 2>&1); rc=$?; calls=$(tr '\n' ';' < "$STATE/calls"); }
images() { cut -d' ' -f1 "$STATE/images" | sort | tr '\n' ' '; }
removed() { grep '^image rm' "$STATE/calls" | sort | tr '\n' ';'; }

new 3 $((10 * GIB)); run
ok "under the threshold: SIGTERM ends it with 0" '[ $rc = 0 ]'
ok "under the threshold: the age prune once, then only checks" '[ "$calls" = "$AGE-- pass 1;-- pass 2;-- pass 3;" ]'
ok "under the threshold: nothing logged" '[ -z "$out" ]'

new 62 $((10 * GIB)); run
ok "the age prune keeps its hour: passes 1 and 61 of 62 a minute apart" '[ "$(grep -c "until=24h" "$STATE/calls")" = 6 ] && case "$calls" in *"-- pass 60;$AGE-- pass 61;-- pass 62;") true ;; *) false ;; esac'

new 2 $((10 * GIB)); touch "$STATE/down"; echo 'rm "$STATE/down"' > "$STATE/hook1"; run
ok "dind down: the age prune runs at the next check, not an hour on" '[ "$calls" = "-- pass 1;$AGE-- pass 2;" ] && [ $rc = 0 ]'

new 1 $((24 * GIB - 1)); run
ok "one KiB under 24 GiB: no size prune" '[ "$calls" = "$AGE-- pass 1;" ] && [ -z "$out" ]'
new 1 $((24 * GIB)); run
ok "at 24 GiB: the size prune" '[ "$calls" = "$AGE$SHRINK-- pass 1;" ]'
ok "at 24 GiB: logged" '[ "$out" = "docker-prune: /var/lib/docker holds 25165824 KiB, over 24 GiB: pruning" ]'

new 1 0; rm "$STATE/kb"; echo 1 > "$STATE/du.rc"; echo "du: /var/lib/docker: No such file or directory" > "$STATE/du.err"; run
ok "an unreadable size counts as over" '[ "$calls" = "$AGE$SHRINK-- pass 1;" ]'
ok "an unreadable size: logged as such" '[ "$out" = "docker-prune: /var/lib/docker holds ? KiB, over 24 GiB: pruning" ]'

new 1 $((10 * GIB)); echo 1 > "$STATE/du.rc"
echo "du: /var/lib/docker/containerd/daemon/io.containerd.snapshotter.v1.overlayfs/snapshots/80/fs/tmp/x: No such file or directory" > "$STATE/du.err"; run
ok "files gone mid-walk: du's total still counts" '[ "$calls" = "$AGE-- pass 1;" ] && [ -z "$out" ]'

# a job starts in pass 2 on the base image, with an image appearing in the
# same pass; in pass 3 it builds ci-runner:test and leaves a dangling image;
# in pass 4 (second 100180) the store is over
new 4 $((10 * GIB))
cat > "$STATE/images" <<'X'
sha256:base catthehacker/ubuntu:act-22.04
sha256:old factory-gateway:abc1234
sha256:stopped opencode-worker:abc1234
sha256:dang <none>
sha256:created ci-runner:abc1234
X
cat > "$STATE/containers" <<'X'
cstopped sha256:stopped exited 96400
ccreated sha256:created created 99940
X
cat > "$STATE/hook1" <<'X'
echo "cjob sha256:base running 100060" >> "$STATE/containers"; echo "sha256:same factory-gateway:def5678" >> "$STATE/images"
X
echo 'echo "sha256:built ci-runner:test" >> "$STATE/images"; echo "sha256:dang2 <none>" >> "$STATE/images"' > "$STATE/hook2"
echo "echo $((30 * GIB)) > \"\$STATE/kb\"" > "$STATE/hook3"
run
ok "over while a job runs: the size prune in pass 4 only" '[ "$(grep -v "^image rm" "$STATE/calls" | tr "\n" ";")" = "$AGE-- pass 1;-- pass 2;-- pass 3;$SHRINK-- pass 4;" ]'
ok "over while a job runs: logged" '[ "$out" = "docker-prune: /var/lib/docker holds 31457280 KiB, over 24 GiB: pruning" ]'
ok "the hourly prune takes the dangling image in pass 1" '[ "$(sed -n "1,/-- pass 1/p" "$STATE/calls" | grep "^image rm")" = "image rm sha256:dang" ]'
ok "over: the dangling image of the job's pass goes, unused images seen before the job too, one whose stopped container went past 10 minutes among them" '[ "$(sed -n "/-- pass 3/,/-- pass 4/p" "$STATE/calls" | grep "^image rm" | sort | tr "\n" ";")" = "image rm sha256:dang2;image rm sha256:old;image rm sha256:stopped;" ]'
ok "the job's base image, the job's build, an image first seen with the job and one under a just-created container stay" '[ "$(images)" = "sha256:base sha256:built sha256:created sha256:same " ]'
ok "the job's container and the just-created one stay, the hour-old stopped one goes" '[ "$(cut -d" " -f1 "$STATE/containers" | sort | tr "\n" " ")" = "ccreated cjob " ]'

# no job runs: every unused image goes, also one first seen this pass
new 2 $((10 * GIB))
echo "sha256:a app:1" > "$STATE/images"; echo "sha256:c app:3" >> "$STATE/images"
cat > "$STATE/hook1" <<X
echo "sha256:b app:2" >> "\$STATE/images"; echo "cstopped sha256:c exited 100060" >> "\$STATE/containers"; echo $((30 * GIB)) > "\$STATE/kb"
X
run
ok "no job running: every unused image goes, one a stopped container uses stays" '[ "$(removed)" = "image rm sha256:a;image rm sha256:b;" ] && [ "$(images)" = "sha256:c " ]'

# a cancelled image job's buildkitd outlives it: with no job running it
# goes with its state, while a job runs every builder stays, and a dind
# that cannot answer keeps them all
new 1 $((10 * GIB))
echo "cbk sha256:bk running 99000 buildx_buildkit_image-runner0" > "$STATE/containers"; run
ok "no job running: the leftover buildkitd and its state go" '[ "$calls" = "rm -f buildx_buildkit_image-runner0;volume rm buildx_buildkit_image-runner0_state;$AGE-- pass 1;" ]'
new 1 $((10 * GIB))
printf '%s\n' "cbk sha256:bk running 99000 buildx_buildkit_image-runner0" "cjob sha256:base running 99500 FORGEJO-ACTIONS-TASK-9487_JOB-image-runner" > "$STATE/containers"; run
ok "a job running: every builder stays" '[ "$calls" = "$AGE-- pass 1;" ]'
new 2 $((10 * GIB)); touch "$STATE/down"; echo 'rm "$STATE/down"' > "$STATE/hook1"
echo "cbk sha256:bk running 99000 buildx_buildkit_image-runner0" > "$STATE/containers"; run
ok "dind down: nothing removed until it answers" '[ "$calls" = "-- pass 1;rm -f buildx_buildkit_image-runner0;volume rm buildx_buildkit_image-runner0_state;$AGE-- pass 2;" ]'

echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
