#!/usr/bin/env bash
# scripts/affected-packages.sh prints nothing for an empty change, so
# `bash check changed` ends after its static checks, and ./... when a non-Go
# input changed.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git init -q -b main "$tmp/origin"
mkdir -p "$tmp/origin/scripts"
cp "$here/scripts/affected-packages.sh" "$tmp/origin/scripts/"
cp "$here/check" "$tmp/origin/check"
git -C "$tmp/origin" -c user.name=t -c user.email=t@t add -A
git -C "$tmp/origin" -c user.name=t -c user.email=t@t commit -q -m base
git clone -q "$tmp/origin" "$tmp/clone"
base=$(git -C "$tmp/clone" merge-base HEAD refs/remotes/origin/HEAD)

out=$(cd "$tmp/clone" && bash scripts/affected-packages.sh "$base" 2>"$tmp/err")
[ -z "$out" ] || { echo "empty change printed '$out', want nothing"; exit 1; }
grep -q "empty diff: nothing to test" "$tmp/err" || { echo "empty change gave no reason:"; cat "$tmp/err"; exit 1; }

echo x >"$tmp/clone/Dockerfile"
out=$(cd "$tmp/clone" && bash scripts/affected-packages.sh "$base" 2>/dev/null)
[ "$out" = "./..." ] || { echo "a non-Go change printed '$out', want ./..."; exit 1; }

echo ok
