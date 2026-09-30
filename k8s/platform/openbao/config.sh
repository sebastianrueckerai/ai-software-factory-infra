#!/bin/sh
# The SSH CA, the gateway's Kubernetes auth and factoryd's read of the
# Forgejo admin's login (see "OpenBao SSH CA" in the README). Idempotent.
# BAO_TOKEN set: run with it (the bootstrap's root token); unset: log in as
# role openbao-config with the pod's token.
set -eu
trap '[ $? = 0 ] || echo "openbao-config: failed"' EXIT
if [ -z "${BAO_TOKEN:-}" ]; then
  BAO_TOKEN=$(bao write -field=token auth/kubernetes/login role=openbao-config jwt=@/var/run/secrets/openbao/token)
  export BAO_TOKEN
fi
changed=""
state() { bao read -format=json "$1" </dev/null 2>/dev/null | grep -v '"request_id"' || true; }
put() {
  p=$1; shift
  before=$(state "$p")
  bao write "$p" "$@" >/dev/null
  [ "$before" = "$(state "$p")" ] || changed="$changed $p"
}
if ! bao secrets list -format=json | grep -q '"ssh-client-signer/"'; then
  bao secrets enable -path=ssh-client-signer ssh >/dev/null
  changed="$changed sys/mounts/ssh-client-signer"
fi
# A second write to config/ca makes a new CA the default and locks every
# running agent server out, so it runs only on the exact "no CA yet" answer.
# The CronJob's policy only reads config/ca; the bootstrap generates it.
if ! err=$(bao read ssh-client-signer/config/ca 2>&1 >/dev/null); then
  case $err in
    *"no default issuer currently configured"*) ;;
    *) printf '%s\n' "$err" >&2; exit 1 ;;
  esac
  bao write ssh-client-signer/config/ca generate_signing_key=true key_type=ssh-ed25519 >/dev/null
  changed="$changed ssh-client-signer/config/ca"
fi
# any principal: 2.6.3 has no glob; ruling 125 as amended binds a certificate by the
# server's AuthorizedPrincipalsFile plus the gateway signing only for the task's own server
put ssh-client-signer/roles/factory-agent - <<'JSON'
{"key_type": "ca", "allow_user_certificates": true, "allowed_users": "*", "default_user": "unassigned",
 "ttl": "30m", "max_ttl": "30m", "allowed_extensions": "permit-pty", "default_extensions": {"permit-pty": ""}, "allow_user_key_ids": true}
JSON
# a policy write bumps its version and modified time, so compare the text
policy='path "ssh-client-signer/sign/factory-agent" {
  capabilities = ["update"]
}'
if [ "$(bao read -field=policy sys/policies/acl/factory-gateway-ssh 2>/dev/null || true)" != "$policy" ]; then
  printf '%s\n' "$policy" | bao write sys/policies/acl/factory-gateway-ssh policy=- >/dev/null
  changed="$changed sys/policies/acl/factory-gateway-ssh"
fi
if ! bao secrets list -format=json | grep -q '"factory/"'; then
  bao secrets enable -path=factory -version=2 kv >/dev/null
  changed="$changed sys/mounts/factory"
fi
policy='path "factory/data/forgejo-admin" {
  capabilities = ["read"]
}'
if [ "$(bao read -field=policy sys/policies/acl/factoryd-forgejo-admin 2>/dev/null || true)" != "$policy" ]; then
  printf '%s\n' "$policy" | bao write sys/policies/acl/factoryd-forgejo-admin policy=- >/dev/null
  changed="$changed sys/policies/acl/factoryd-forgejo-admin"
fi
if ! bao auth list -format=json | grep -q '"kubernetes/"'; then
  bao auth enable kubernetes >/dev/null
  changed="$changed sys/auth/kubernetes"
fi
put auth/kubernetes/config kubernetes_host="https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT"
put auth/kubernetes/role/factory-gateway bound_service_account_names=factory-gateway \
  bound_service_account_namespaces=factory audience=openbao token_policies=factory-gateway-ssh token_ttl=1h token_max_ttl=1h
put auth/kubernetes/role/factoryd bound_service_account_names=factoryd \
  bound_service_account_namespaces=factory audience=openbao token_policies=factoryd-forgejo-admin token_ttl=1h token_max_ttl=1h
if [ -n "$changed" ]; then echo "openbao-config: wrote$changed"; else echo "openbao-config: no change"; fi
