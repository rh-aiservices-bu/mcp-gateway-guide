#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_step()  { echo -e "  ${BLUE}-->  $*${NC}"; }

MCP_NS="mcp-gateway"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --confirm)  CONFIRMED=true; shift ;;
        --namespace) MCP_NS="$2"; shift 2 ;;
        *)          shift ;;
    esac
done

echo -e "${RED}============================================${NC}"
echo -e "${RED}  MCP Gateway - Teardown${NC}"
echo -e "${RED}============================================${NC}"
echo ""

if [[ "${CONFIRMED:-false}" != "true" ]]; then
    echo "This will remove all MCP Gateway resources from the cluster."
    echo "Run with --confirm to proceed."
    echo "Use --namespace NS to target a custom namespace (default: mcp-gateway)."
    exit 0
fi

if ! oc whoami &>/dev/null; then
    echo -e "${RED}[ERROR]${NC} Not logged into an OpenShift cluster."
    exit 1
fi

log_info "Starting teardown (namespace: $MCP_NS)..."

# Delete virtual servers
log_step "Deleting MCPVirtualServer resources"
oc delete mcpvirtualserver --all -n "$MCP_NS" --ignore-not-found 2>/dev/null || true

# Delete auth policies
log_step "Deleting AuthPolicy resources"
oc delete authpolicy --all -n "$MCP_NS" --ignore-not-found 2>/dev/null || true

# Delete MCP server registrations
log_step "Deleting MCPServerRegistration resources"
oc delete mcpsr --all -n mcp-test --ignore-not-found 2>/dev/null || true

# Delete HTTPRoutes in mcp-test
log_step "Deleting HTTPRoutes in mcp-test"
oc delete httproute --all -n mcp-test --ignore-not-found 2>/dev/null || true

# Delete Kuadrant CR (has finalizers, must be deleted before namespace)
log_step "Deleting Kuadrant CR"
oc delete kuadrant --all -n "$MCP_NS" --ignore-not-found 2>/dev/null || true

# Delete MCP Gateway Extension
log_step "Deleting MCPGatewayExtension"
oc delete mcpgatewayextension --all -n "$MCP_NS" --ignore-not-found 2>/dev/null || true

# Delete ReferenceGrant
log_step "Deleting ReferenceGrant"
oc delete referencegrant --all -n "$MCP_NS" --ignore-not-found 2>/dev/null || true

# Delete Gateway
log_step "Deleting Gateway"
oc delete gateway mcp-gateway -n "$MCP_NS" --ignore-not-found 2>/dev/null || true

# Delete test MCP server namespace
log_step "Deleting mcp-test namespace"
oc delete namespace mcp-test --ignore-not-found 2>/dev/null || true

# Delete RHBK resources in mcp-test (namespace deletion below handles cleanup)
log_step "Deleting RHBK Keycloak resources in mcp-test"
oc delete keycloakrealmimport --all -n mcp-test --ignore-not-found 2>/dev/null || true
oc delete keycloak --all -n mcp-test --ignore-not-found 2>/dev/null || true
oc delete deployment keycloak-pgsql -n mcp-test --ignore-not-found 2>/dev/null || true
oc delete secret keycloak-db-secret -n mcp-test --ignore-not-found 2>/dev/null || true

# Delete mcp-system namespace (virtual server config)
log_step "Deleting mcp-system namespace"
oc delete namespace mcp-system --ignore-not-found 2>/dev/null || true

# Delete operator subscription and operator groups
log_step "Deleting MCP Gateway operator subscription"
oc delete subscription mcp-gateway -n "$MCP_NS" --ignore-not-found 2>/dev/null || true
oc delete operatorgroup --all -n "$MCP_NS" --ignore-not-found 2>/dev/null || true

# Delete CSVs
log_step "Deleting CSVs"
oc delete csv -n "$MCP_NS" --all --ignore-not-found 2>/dev/null || true

# Delete namespace
log_step "Deleting $MCP_NS namespace"
oc delete namespace "$MCP_NS" --ignore-not-found 2>/dev/null || true

echo ""
log_ok "Teardown complete."
