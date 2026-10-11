#!/usr/bin/env bash
# smoke.sh <staging url>: main's CI runs it against staging after each roll. The card that owns deploy/ fills
# authenticated_write with the spec's write and reads its token from the environment, where the project's Secrets
# arrive: : "${ADMIN_TOKEN:?missing Secret ADMIN_TOKEN}" makes a missing Secret a red check.
set -euo pipefail

authenticated_write() {
  echo "no authenticated write defined yet: the card that owns deploy/ fills authenticated_write with the spec's write"
}

url=${1:?usage: smoke.sh <staging url>}
url=${url%/}
# shellcheck source=/dev/null
if [ -n "${STAGING_SECRETS:-}" ]; then
  set -a; source <(printf '%s\n' "$STAGING_SECRETS"); set +a
fi

tmp=$(mktemp -d)
trap 'rm -r "$tmp"' EXIT
get() { : > "$tmp/body"; curl -sS -m 10 -o "$tmp/body" -w '%{http_code}' "$1" 2> "$tmp/err" || true; }
seen() { printf '%s %s: %s%s\n' "$1" "$2" "$(head -c 300 "$tmp/body")" "$(head -c 300 "$tmp/err")"; }

for try in 1 2 3 4 5 6; do
  code=$(get "$url/healthz")
  if [ "$code" = 200 ]; then break; fi
  if [ "$try" = 6 ]; then seen healthz "$code"; exit 1; fi
  echo "$(seen healthz "$code"); again in 10 s"
  sleep 10
done
echo "healthz 200"

code=$(get "$url/app/")
if [ "$code" != 200 ] || ! grep -q 'id="root"' "$tmp/body"; then
  echo 'the app page must answer 200 with id="root"'; seen "app page" "$code"; exit 1
fi
echo "app page 200 with id=\"root\""

authenticated_write "$url"
echo "smoke test of $url passed"
