#!/bin/sh
# local-path's setup, run as root in a helper pod at every claim with the
# class's node path mounted. A factory-cache claim also prunes, never
# failing the claim: caches unclaimed for 14 days go, and a cache above
# FACTORY_CACHE_CAP_MB loses its files unchanged for 3 days. The stamps sit
# outside every cache, where no pod can age or freshen them. The chmod
# repairs a claim directory that kubelet made 0755 after a sweep removed it.
set -eu
mkdir -m 0777 -p "$VOL_DIR"
root=/var/lib/factory-cache
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
if [ "$(du -sm "$VOL_DIR" | cut -f1)" -gt "${FACTORY_CACHE_CAP_MB:-10240}" ]; then
  find "$VOL_DIR" -type f -mmin +4320 -exec rm -f {} +
fi
exit 0
