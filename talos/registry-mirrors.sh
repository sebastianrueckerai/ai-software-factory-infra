#!/bin/sh
# Patches every node with patches.yaml's registry mirrors, which pull an
# outside image from the factory's store first, and with the store's read
# login: RegistryAuthConfig git.aisoftwarefactory.world, factory-registry-
# read's token from secret factory/forgejo-registry-read, which
# scripts/seed-secrets.sh mints. No reboot. Run from the repository root
# after the seed's Forgejo pass and again whenever the seed mints the
# token anew; on nodes generated with the mirrors only the login changes:
#   sh talos/registry-mirrors.sh <node address>...
set -eu
[ $# -gt 0 ] || { echo "usage: sh talos/registry-mirrors.sh <node address>..."; exit 2; }
tok=$(kubectl -n factory get secret forgejo-registry-read -o 'jsonpath={.data.token}' | base64 -d)
[ -n "$tok" ] || { echo "factory/forgejo-registry-read holds no token: run scripts/seed-secrets.sh first"; exit 1; }
patch=$(mktemp)
trap 'rm -f "$patch"' EXIT
awk 'BEGIN { RS = "\n---\n" } /kind: RegistryMirrorConfig/ { printf "%s\n---\n", $0 }' talos/patches.yaml > "$patch"
printf 'apiVersion: v1alpha1\nkind: RegistryAuthConfig\nname: git.aisoftwarefactory.world\nusername: factory-registry-read\npassword: %s\n' "$tok" >> "$patch"
unset tok
for n in "$@"; do
  talosctl --talosconfig talos/talosconfig -e "$n" -n "$n" patch mc --mode=no-reboot --patch @"$patch"
done
