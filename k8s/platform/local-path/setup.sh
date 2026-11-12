#!/bin/sh
# local-path's setup, run as root in a helper pod at every claim with the
# class's node path mounted, and, as `setup.sh sweep`, by the factory-cache
# DaemonSet's loop. A factory-cache claim also prunes, never failing the
# claim: caches unclaimed for 14 days go, and a cache above
# FACTORY_CACHE_CAP_MB loses its files unchanged for 3 days, then its Go
# build cache files unchanged longest, in steps down to 2 hours, until it
# is under the cap: cmd/go refreshes a cache file's mtime at most hourly
# as it uses it, so a build in flight reads younger ones. go install's
# binaries (go/bin, on every job's PATH) are never removed. The sweep runs
# that prune on every cache directory each FACTORY_CACHE_SWEEP_SECONDS
# (600), so a directory that pods grew past the cap while they ran is held
# to it within one pass and the age of its files. The stamps
# sit outside every cache, where no pod can age or freshen them. The chmod
# repairs a claim directory that kubelet made 0755 after a sweep removed it.
set -eu
root=/var/lib/factory-cache
over() { [ "$(du -sm "$1" | cut -f1)" -gt "${FACTORY_CACHE_CAP_MB:-10240}" ]; }
prune() {
  if over "$1"; then
    find "$1" -path "$1/go/bin" -prune -o -type f -mmin +4320 -exec rm -f {} +
    for h in 48 24 12 6 4 2; do
      over "$1" && [ -d "$1/go-build" ] || break
      find "$1/go-build" -type f -mmin +$((h * 60)) -exec rm -f {} +
    done
  fi
}
if [ "${1:-}" = sweep ]; then
  set +e
  while :; do
    for d in "$root"/*/; do
      [ -d "$d" ] && prune "${d%/}"
    done
    sleep "${FACTORY_CACHE_SWEEP_SECONDS:-600}"
  done
fi
mkdir -m 0777 -p "$VOL_DIR"
[ "$(dirname "$VOL_DIR")" = "$root" ] || exit 0
chmod 0777 "$VOL_DIR"
set +e
stamps=$root/.claimed
mkdir -p "$stamps"
touch "$stamps/$(basename "$VOL_DIR")"
for d in "$root"/*/; do
  s=$stamps/$(basename "$d")
  [ -e "$s" ] || touch "$s"
done
find "$stamps" -type f -mmin +20160 | while read -r s; do
  rm -rf "$root/$(basename "$s")" "$s"
done
prune "$VOL_DIR"
exit 0
