#!/usr/bin/env bash
# Runs k8s/platform/openbao/config.sh in openbao-0 with the root token, then
# writes role and policy openbao-config, with which CronJob openbao-config
# logs in from then on. Once per OpenBao, and again after a restore whose
# Kubernetes auth refuses the new cluster (README "OpenBao SSH CA"). Reads
# BAO_TOKEN from the environment; the token goes over stdin, never into an
# argument, and nothing prints it.
set -euo pipefail
: "${BAO_TOKEN:?set BAO_TOKEN to the OpenBao root token}"
script=$(cat "$(dirname "$0")/../k8s/platform/openbao/config.sh")
script+=$(cat <<'SH'

bao policy write openbao-config - >/dev/null <<'HCL'
path "sys/auth" { capabilities = ["read"] }
path "sys/mounts" { capabilities = ["read"] }
path "sys/policies/acl/factory-gateway-ssh" { capabilities = ["read", "create", "update"] }
path "auth/kubernetes/config" { capabilities = ["read", "create", "update"] }
path "auth/kubernetes/role/factory-gateway" { capabilities = ["read", "create", "update"] }
path "ssh-client-signer/config/ca" { capabilities = ["read", "create", "update"] }
path "ssh-client-signer/roles/factory-agent" { capabilities = ["read", "create", "update"] }
HCL
bao write auth/kubernetes/role/openbao-config bound_service_account_names=openbao-config \
  bound_service_account_namespaces=platform audience=openbao token_policies=openbao-config \
  token_ttl=5m token_max_ttl=5m >/dev/null
echo "openbao-config-bootstrap: role and policy openbao-config written"
SH
)
printf '%s\n' "$BAO_TOKEN" | kubectl -n platform exec -i openbao-0 -- sh -c "read -r BAO_TOKEN; export BAO_TOKEN; $script"
