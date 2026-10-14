# shellcheck shell=busybox
# The trusted runner's docker-prune sidecar. dind's store is an emptyDir,
# and the kubelet evicts the pod once the volume passes its sizeLimit.
# Every EVERY seconds build cache goes by last use (builder prune's until),
# stopped containers and unused networks by age, images only when
# dangling: a base image pulled today may be years old. Every CHECK seconds
# the volume is measured as the kubelet measures it (blocks on one
# filesystem, hard links once), and from MAX_GIB on all that no running job
# needs goes: build cache no build holds, stopped containers older than a
# job's create-to-start gap, dangling images, and unused images seen before
# the oldest running container. An unreadable size counts as over. Every
# CHECK seconds with no job running, a buildkitd a cancelled image job left
# goes too. Retries each check while dind is down; exits on SIGTERM.
trap 'exit 0' TERM INT
seen='' next=0
# "id seconds" per line: when this sidecar first saw each image and
# running container
sight() {
  ids=$(docker image ls -q --no-trunc && docker ps -q --no-trunc) || return
  seen=$(echo "$ids" | SEEN=$seen awk -v now="$now" '
    BEGIN { n = split(ENVIRON["SEEN"], l, "\n"); for (i = 1; i <= n; i++) { split(l[i], f, " "); t[f[1]] = f[2] } }
    $1 != "" && !d[$1]++ { print $1, ($1 in t ? t[$1] : now) }')
}
# docker image prune, even one that matches nothing, drops the lease of
# every pull under way and fails it (docker 29, containerd store); an image
# rm leaves them be
rmi() { while read -r id; do docker image rm "$id" >/dev/null 2>&1; done; }
dangling() { docker image ls -q --no-trunc --filter dangling=true; }
# A cancelled image job leaves its buildkitd running: the cancel kills the
# job's container, so its step's EXIT trap never removes the builder. With
# no job running no builder is any job's; a failed read keeps them all.
leftovers() {
  jobs=$(docker ps -q --filter name=FORGEJO-ACTIONS-TASK-) || return
  [ -z "$jobs" ] || return
  builders=$(docker ps -a --filter name=buildx_buildkit_ --format '{{.Names}}') || return
  for b in $builders; do
    docker rm -f "$b" >/dev/null && docker volume rm "${b}_state" >/dev/null
  done
}
# A job builds or pulls its images after its container starts, so an image
# seen before the oldest running container is no running job's, and no job
# waits on it between its build and its run or push.
stale() {
  running=$(docker ps -q --no-trunc) || return
  echo "$seen" | RUNNING=$running awk -v now="$now" '
    BEGIN { n = split(ENVIRON["RUNNING"], r, "\n"); for (i = 1; i <= n; i++) up[r[i]]; oldest = now + 1 }
    { t[$1] = $2; if ($1 in up && $2 < oldest) oldest = $2 }
    END { for (id in t) if (id ~ /^sha256:/ && t[id] < oldest) print id }'
}
while :; do
  now=$(date +%s)
  sight
  leftovers
  if [ "$now" -ge "$next" ] &&
    docker builder prune -af --filter "until=$KEEP" >/dev/null &&
    docker container prune -f --filter "until=$KEEP" >/dev/null &&
    docker network prune -f --filter "until=$KEEP" >/dev/null; then
    dangling | rmi
    next=$((now + EVERY))
  fi
  # du exits 1 over files a build removes mid-walk; its total stands, as
  # the kubelet skips them too
  kb=$(du -skx /var/lib/docker 2>/dev/null | cut -f1)
  case $kb in *[!0-9]*) kb= ;; esac
  if [ -z "$kb" ] || [ "$kb" -ge $((MAX_GIB * 1048576)) ]; then
    echo "docker-prune: /var/lib/docker holds ${kb:-?} KiB, over $MAX_GIB GiB: pruning"
    docker builder prune -af >/dev/null
    docker container prune -f --filter until=10m >/dev/null
    # the daemon refuses an image a container uses, a running job's base
    { dangling; stale; } | rmi
  fi
  sleep "$CHECK" & wait $!
done
