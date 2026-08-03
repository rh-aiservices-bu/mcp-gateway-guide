#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "  ${CYAN}-->  $*${NC}"; }
log_phase() { echo -e "\n${GREEN}========================================${NC}"; echo -e "${GREEN}  Phase $1: $2${NC}"; echo -e "${GREEN}========================================${NC}"; }

WITH_AUTH=false
FROM_PHASE=0
DRY_RUN=false
MCP_NS="mcp-gateway"

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --with-auth       Include phases 6-9 (Keycloak, auth, authz, virtual servers)"
    echo "  --from-phase N    Start from phase N (skip completed phases)"
    echo "  --namespace NS    MCP gateway namespace (default: mcp-gateway)"
    echo "  --dry-run         Print commands without executing"
    echo "  -h, --help        Show this help"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --with-auth)    WITH_AUTH=true; shift ;;
        --from-phase)   FROM_PHASE="$2"; shift 2 ;;
        --namespace)    MCP_NS="$2"; shift 2 ;;
        --dry-run)      DRY_RUN=true; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              log_error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

run() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [DRY-RUN] $*"
    else
        eval "$@"
    fi
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    for cmd in oc envsubst curl jq; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "$cmd is required but not found"
            exit 1
        fi
    done
    log_ok "All required tools found"

    if ! oc whoami &>/dev/null; then
        log_error "Not logged into an OpenShift cluster. Run 'oc login' first."
        exit 1
    fi
    log_ok "Logged into cluster as $(oc whoami)"

    export CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
    export MCP_HOSTNAME="mcp.${CLUSTER_DOMAIN}"
    log_ok "Cluster domain: $CLUSTER_DOMAIN"
    log_ok "MCP hostname:   $MCP_HOSTNAME"
}

# Phase 1: Prerequisites
phase_1() {
    log_phase 1 "Prerequisites - Install MCP Gateway Operator"

    log_step "Creating namespace and operator subscription"
    run "oc apply -k ${REPO_ROOT}/manifests/01-prerequisites/operators/"

    log_step "Waiting for operator CSV to succeed (this may take a few minutes)..."
    run "sleep 30"
    run "oc wait csv -n ${MCP_NS} -l operators.coreos.com/mcp-gateway.${MCP_NS}='' --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s" || {
        log_warn "CSV wait timed out. Checking status..."
        oc get csv -n "$MCP_NS" 2>/dev/null || true
    }

    log_step "Verifying CRDs"
    run "oc get crd mcpgatewayextensions.mcp.kuadrant.io"
    run "oc get crd mcpserverregistrations.mcp.kuadrant.io"

    log_ok "Phase 1 complete"
}

# Phase 2: Gateway Setup
phase_2() {
    log_phase 2 "Gateway Setup"

    log_step "Creating Gateway with MCP listener"
    run "envsubst < ${REPO_ROOT}/manifests/02-gateway-setup/gateway.yaml.tmpl | oc apply -f -"

    log_step "Waiting for Gateway to be Programmed..."
    run "oc wait gateway/mcp-gateway -n ${MCP_NS} --for=condition=Programmed --timeout=120s"

    log_ok "Phase 2 complete"
}

# Phase 3: MCP Gateway Extension
phase_3() {
    log_phase 3 "MCP Gateway Extension"

    log_step "Creating MCPGatewayExtension and ReferenceGrant"
    run "oc apply -k ${REPO_ROOT}/manifests/03-mcp-gateway-extension/"

    log_step "Waiting for MCPGatewayExtension to be Ready..."
    run "oc wait mcpgatewayextension/mcp-extension -n ${MCP_NS} --for=condition=Ready --timeout=60s"

    log_ok "Phase 3 complete"
}

# Phase 4: Register MCP Servers
phase_4() {
    log_phase 4 "Register MCP Servers"

    log_step "Creating mcp-test namespace"
    run "oc apply -f ${REPO_ROOT}/manifests/04-register-mcp-servers/namespace.yaml"

    log_step "Deploying test server"
    run "oc apply -k ${REPO_ROOT}/manifests/04-register-mcp-servers/test-server/"

    log_step "Deploying risk server"
    run "oc apply -k ${REPO_ROOT}/manifests/04-register-mcp-servers/risk-server/"

    log_step "Waiting for MCP server pods to be ready..."
    run "oc wait pod -n mcp-test -l app=test-server1 --for=condition=Ready --timeout=120s" || log_warn "Test server not ready yet"
    run "oc wait pod -n mcp-test -l app=mcp-risk-server --for=condition=Ready --timeout=120s" || log_warn "Risk server not ready yet"

    log_step "Creating HTTPRoutes"
    run "oc apply -f ${REPO_ROOT}/manifests/04-register-mcp-servers/httproute-test.yaml"
    run "oc apply -f ${REPO_ROOT}/manifests/04-register-mcp-servers/httproute-risk.yaml"

    log_step "Creating MCPServerRegistrations"
    run "oc apply -f ${REPO_ROOT}/manifests/04-register-mcp-servers/mcpsr-test.yaml"
    run "oc apply -f ${REPO_ROOT}/manifests/04-register-mcp-servers/mcpsr-risk.yaml"

    log_step "Checking MCPServerRegistration status"
    run "sleep 5"
    run "oc get mcpsr -A"

    log_ok "Phase 4 complete"
}

# Phase 5: Verification
phase_5() {
    log_phase 5 "Verification"

    log_step "Running verification script"
    run "bash ${REPO_ROOT}/scripts/verify.sh"

    log_ok "Phase 5 complete"
}

# Phase 6: Deploy Keycloak
phase_6() {
    log_phase 6 "Deploy Keycloak"

    log_step "Deploying Keycloak with realm import"
    run "oc apply -k ${REPO_ROOT}/manifests/06-deploy-keycloak/keycloak/"

    log_step "Waiting for Keycloak to be ready..."
    run "oc wait pod -n keycloak -l app=keycloak --for=condition=Ready --timeout=180s"

    export KEYCLOAK_URL="https://$(oc get route keycloak -n keycloak -o jsonpath='{.spec.host}')"
    export KEYCLOAK_ISSUER="${KEYCLOAK_URL}/realms/mcp"
    log_ok "Keycloak URL: $KEYCLOAK_URL"

    log_step "Verifying OIDC discovery"
    run "sleep 5"
    run "curl -sk '${KEYCLOAK_ISSUER}/.well-known/openid-configuration' | jq '.issuer'"

    log_ok "Phase 6 complete"
}

# Phase 7: Authentication
phase_7() {
    log_phase 7 "Authentication"

    export KEYCLOAK_URL="https://$(oc get route keycloak -n keycloak -o jsonpath='{.spec.host}')"
    export KEYCLOAK_ISSUER="${KEYCLOAK_URL}/realms/mcp"
    export MCP_URL="http://${MCP_HOSTNAME}/mcp"

    log_step "Configuring OAuth via MCPGatewayExtension oauthProtectedResource"
    run "envsubst < ${REPO_ROOT}/manifests/07-authentication/mcpgatewayextension-oauth-patch.yaml.tmpl | oc apply -f -"

    log_step "Waiting for broker rollout..."
    run "sleep 10"
    run "oc rollout status deployment/mcp-gateway -n ${MCP_NS} --timeout=60s"

    log_step "Setting up Kuadrant for AuthPolicy enforcement"

    log_step "Ensuring OperatorGroup supports AllNamespaces mode"
    OG_NAME=$(oc get operatorgroup -n ${MCP_NS} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -n "$OG_NAME" ]]; then
        OG_TARGET=$(oc get operatorgroup "$OG_NAME" -n ${MCP_NS} -o jsonpath='{.spec.targetNamespaces}' 2>/dev/null || true)
        if [[ -n "$OG_TARGET" && "$OG_TARGET" != "[]" ]]; then
            log_warn "OperatorGroup has targetNamespaces set (OwnNamespace mode)"
            log_step "Recreating OperatorGroup in AllNamespaces mode (required by Authorino)"
            run "oc delete operatorgroup '$OG_NAME' -n ${MCP_NS}"
            run "cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${MCP_NS}-og
  namespace: ${MCP_NS}
spec: {}
EOF"
        fi
    fi

    log_step "Checking Authorino operator"
    AUTHORINO_CSV=$(oc get csv -n ${MCP_NS} -l operators.coreos.com/authorino-operator.${MCP_NS}='' -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -z "$AUTHORINO_CSV" ]]; then
        log_warn "Authorino operator CSV not found. It should be installed as a dependency of MCP Gateway."
        log_warn "If AuthPolicy enforcement fails, install the Authorino operator manually."
    else
        log_ok "Authorino operator found: $AUTHORINO_CSV"
    fi

    log_step "Creating Kuadrant CR (required for AuthPolicy enforcement)"
    run "oc apply -f ${REPO_ROOT}/manifests/07-authentication/kuadrant.yaml"

    log_step "Waiting for Kuadrant to be ready..."
    run "sleep 15"
    run "oc wait kuadrant/kuadrant -n ${MCP_NS} --for=condition=Ready --timeout=120s" || log_warn "Kuadrant ready check timed out"

    log_step "Restarting gateway to load WASM plugin"
    ISTIO_DEPLOY=$(oc get deployment -n ${MCP_NS} -l istio.io/gateway-name=mcp-gateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -n "$ISTIO_DEPLOY" ]]; then
        run "oc rollout restart deployment/${ISTIO_DEPLOY} -n ${MCP_NS}"
        run "oc rollout status deployment/${ISTIO_DEPLOY} -n ${MCP_NS} --timeout=60s"
    fi

    log_step "Applying authentication AuthPolicy"
    run "envsubst < ${REPO_ROOT}/manifests/07-authentication/authpolicy-auth.yaml.tmpl | oc apply -f -"

    log_step "Waiting for AuthPolicy to be Enforced..."
    run "sleep 10"
    run "oc wait authpolicy/mcp-auth-policy -n ${MCP_NS} --for=condition=Enforced --timeout=60s" || log_warn "AuthPolicy enforcement check timed out"

    log_step "Verifying OAuth discovery"
    run "curl -s 'http://${MCP_HOSTNAME}/.well-known/oauth-protected-resource' | jq '.resource_name'"

    log_step "Verifying unauthenticated request returns 401"
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://${MCP_HOSTNAME}/mcp" \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')
    if [[ "$HTTP_CODE" == "401" ]]; then
        log_ok "Unauthenticated request correctly returns 401"
    else
        log_warn "Unauthenticated request returned $HTTP_CODE (expected 401)"
    fi

    log_ok "Phase 7 complete"
}

# Phase 8: Authorization
phase_8() {
    log_phase 8 "Authorization"

    export KEYCLOAK_URL="https://$(oc get route keycloak -n keycloak -o jsonpath='{.spec.host}')"
    export KEYCLOAK_ISSUER="${KEYCLOAK_URL}/realms/mcp"

    log_step "Applying authorization AuthPolicy (targets internal mcps listener)"
    run "envsubst < ${REPO_ROOT}/manifests/08-authorization/authpolicy-authz.yaml.tmpl | oc apply -f -"

    log_step "Waiting for AuthPolicy to be Enforced..."
    run "sleep 10"
    run "oc wait authpolicy/mcp-authz-policy -n ${MCP_NS} --for=condition=Enforced --timeout=60s" || log_warn "AuthPolicy enforcement check timed out"

    log_step "Verifying two-policy architecture"
    run "oc get authpolicy -n ${MCP_NS}"

    log_ok "Phase 8 complete - Auth on public 'mcp' listener, Authz on internal 'mcps' listener"
}

# Phase 9: Virtual MCP Servers
phase_9() {
    log_phase 9 "Virtual MCP Servers"

    log_step "Creating mcp-system namespace (required for virtual server config)"
    run "oc create ns mcp-system --dry-run=client -o yaml | oc apply -f -"

    log_step "Creating MCPVirtualServer resources"
    run "oc apply -k ${REPO_ROOT}/manifests/09-virtual-servers/"

    log_step "Waiting for virtual server reconciliation..."
    run "sleep 10"

    log_step "Restarting broker to load virtual server config"
    run "oc rollout restart deployment/mcp-gateway -n ${MCP_NS}"
    run "oc rollout status deployment/mcp-gateway -n ${MCP_NS} --timeout=60s"

    log_step "Verifying virtual servers"
    run "oc get mcpvirtualserver -n ${MCP_NS}"

    log_ok "Phase 9 complete"
}

# Main
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  MCP Gateway on OpenShift - Setup Script${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""

check_prerequisites

PHASES=(1 2 3 4 5)
if [[ "$WITH_AUTH" == "true" ]]; then
    PHASES+=(6 7 8 9)
fi

for phase in "${PHASES[@]}"; do
    if [[ "$phase" -ge "$FROM_PHASE" ]]; then
        "phase_${phase}"
    else
        log_info "Skipping phase $phase (--from-phase $FROM_PHASE)"
    fi
done

echo ""
log_ok "Setup complete!"
if [[ "$WITH_AUTH" == "true" ]]; then
    log_info "Run './scripts/verify.sh --with-auth' to verify the full setup"
else
    log_info "Run './scripts/verify.sh' to verify the setup"
    log_info "Run '$0 --with-auth --from-phase 6' to add authentication and authorization"
fi
