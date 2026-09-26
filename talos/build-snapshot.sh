#!/usr/bin/env bash
# Builds the Hetzner Talos snapshot the servers boot from (see README.md).
# Needs HCLOUD_TOKEN in the environment; HOME_CIDR defaults to this host's
# public address.
set -euo pipefail

VERSION=1.14.1
SID=$(curl -fsS -X POST --data-binary @"$(dirname "$0")/schematic.yaml" https://factory.talos.dev/schematics | jq -r .id)
[ "$SID" = d9ff89777e246792e7642abd3220a616afb4e49822382e4213a2e528ab826fe5 ] || { echo "schematic ID drifted: $SID" >&2; exit 1; }
: "${HCLOUD_TOKEN:?HCLOUD_TOKEN is required}"
HOME_CIDR=${HOME_CIDR:-$(curl -fsS https://api.ipify.org)/32}
NAME=talos-snapshot-build
API=https://api.hetzner.cloud/v1
WORK=$(mktemp -d)
IMG=$WORK/hcloud-amd64.raw.xz
SSH=(ssh -i "$WORK/key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o ServerAliveInterval=15)

hc() { curl -fsS --max-time 60 -H "Authorization: Bearer $HCLOUD_TOKEN" -H "Content-Type: application/json" "$@"; }
status() { hc "$API/servers/$SRV" | jq -r .server.status; }

SRV= FW= KEY=
teardown() {
  [ -n "$SRV" ] && hc -X DELETE "$API/servers/$SRV" >/dev/null && \
    while hc "$API/servers/$SRV" >/dev/null 2>&1; do sleep 5; done
  [ -n "$FW" ] && hc -X DELETE "$API/firewalls/$FW" >/dev/null
  [ -n "$KEY" ] && hc -X DELETE "$API/ssh_keys/$KEY" >/dev/null
  rm -rf "$WORK"
}
trap teardown EXIT

echo "[1] download and verify the image locally"
curl -fL --retry 3 -o "$IMG" "https://factory.talos.dev/image/$SID/v$VERSION/hcloud-amd64.raw.xz"
xz -t "$IMG"

echo "[2] throwaway key, firewall and server"
ssh-keygen -t ed25519 -N '' -f "$WORK/key" -C "$NAME" -q
KEY=$(hc -X POST "$API/ssh_keys" -d "$(jq -n --arg n "$NAME" --arg k "$(cat "$WORK/key.pub")" '{name:$n, public_key:$k}')" | jq -r .ssh_key.id)
FW=$(hc -X POST "$API/firewalls" -d "$(jq -n --arg n "$NAME" --arg c "$HOME_CIDR" \
  '{name:$n, rules:[{direction:"in", protocol:"tcp", port:"22", source_ips:[$c]}]}')" | jq -r .firewall.id)
SRV=$(hc -X POST "$API/servers" -d "$(jq -n --arg n "$NAME" --argjson k "$KEY" --argjson f "$FW" \
  '{name:$n, server_type:"cx23", image:"ubuntu-24.04", location:"fsn1", ssh_keys:[$k], firewalls:[{firewall:$f}], public_net:{enable_ipv4:true, enable_ipv6:false}}')" | jq -r .server.id)
IP=$(hc "$API/servers/$SRV" | jq -r .server.public_net.ipv4.ip)

echo "[3] boot a fresh rescue on $IP (a rescue that already streamed an image wedges; never reuse one)"
until [ "$(status)" = running ]; do sleep 5; done
hc -X POST "$API/servers/$SRV/actions/enable_rescue" -d "{\"type\":\"linux64\",\"ssh_keys\":[$KEY]}" >/dev/null
hc -X POST "$API/servers/$SRV/actions/reset" >/dev/null
sleep 20
until "${SSH[@]}" "root@$IP" 'grep -q rescue /etc/hostname' 2>/dev/null; do sleep 5; done

echo "[4] ship the image"
xz -dc "$IMG" | "${SSH[@]}" "root@$IP" 'dd of=/dev/sda bs=4M conv=fsync status=none && sync'
"${SSH[@]}" "root@$IP" 'echo o > /proc/sysrq-trigger' || true
until [ "$(status)" = off ]; do sleep 5; done

echo "[5] snapshot"
IMAGE=$(hc -X POST "$API/servers/$SRV/actions/create_image" -d "$(jq -n --arg s "${SID:0:16}" --arg v "$VERSION" \
  '{type:"snapshot", description:("talos-"+$v+"-amd64-"+$s), labels:{os:"talos", version:$v, arch:"amd64", schematic:$s}}')" | jq -r .image.id)
until [ "$(hc "$API/images/$IMAGE" | jq -r .image.status)" = available ]; do sleep 10; done
echo "snapshot $IMAGE ready (schematic=${SID:0:16})"
