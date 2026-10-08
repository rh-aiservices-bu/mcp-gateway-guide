#!/usr/bin/env bash
#
# Merge MCPVirtualServer definitions into the broker's config secret.
#
# Why this is needed: the MCPVirtualServer controller writes its config to
# mcp-gateway-config in the *mcp-system* namespace (hardcoded), but the broker
# reads mcp-gateway-config from its *own* namespace. Without this merge the
# broker logs "failed to get virtual server ... not found".
#
# Usage: scripts/merge-virtualserver-config.sh [broker-namespace]
#        broker-namespace defaults to mcp-gateway
set -euo pipefail

BROKER_NS="${1:-mcp-gateway}"
SOURCE_NS="mcp-system"
SECRET="mcp-gateway-config"

for ns in "$SOURCE_NS" "$BROKER_NS"; do
  if ! oc get secret "$SECRET" -n "$ns" >/dev/null 2>&1; then
    echo "error: secret/$SECRET not found in namespace $ns" >&2
    echo "       create the MCPVirtualServer resources first, and give the" >&2
    echo "       controller a few seconds to reconcile them." >&2
    exit 1
  fi
done

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

oc get secret "$SECRET" -n "$SOURCE_NS" -o jsonpath='{.data.config\.yaml}' | base64 -d > "$workdir/virtualservers.yaml"
oc get secret "$SECRET" -n "$BROKER_NS" -o jsonpath='{.data.config\.yaml}' | base64 -d > "$workdir/broker.yaml"

# Read both files from disk rather than interpolating YAML into a -c snippet,
# so quotes and special characters in the config cannot break the merge.
merged_b64=$(python3 - "$workdir/broker.yaml" "$workdir/virtualservers.yaml" <<'PY'
import base64, sys, yaml

broker_path, vs_path = sys.argv[1], sys.argv[2]
broker = yaml.safe_load(open(broker_path)) or {}
vs = yaml.safe_load(open(vs_path)) or {}

broker["virtualServers"] = vs.get("virtualServers", [])
payload = yaml.dump(broker, default_flow_style=False, sort_keys=False)
sys.stdout.write(base64.b64encode(payload.encode()).decode())
PY
)

oc patch secret "$SECRET" -n "$BROKER_NS" --type=json \
  -p="[{\"op\":\"replace\",\"path\":\"/data/config.yaml\",\"value\":\"${merged_b64}\"}]"

count=$(python3 -c "import yaml,sys; print(len((yaml.safe_load(open(sys.argv[1])) or {}).get('virtualServers', [])))" "$workdir/virtualservers.yaml")
echo "merged ${count} virtual server(s) into ${BROKER_NS}/${SECRET}"
echo "now restart the broker: oc rollout restart deployment/mcp-gateway -n ${BROKER_NS}"
