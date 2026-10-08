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
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "\n${BLUE}==> $*${NC}"; }

if ! oc whoami &>/dev/null; then
    log_error "Not logged into an OpenShift cluster. Run 'oc login' first."
    exit 1
fi

CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
MCP_HOSTNAME="mcp.${CLUSTER_DOMAIN}"
MCP_URL="https://${MCP_HOSTNAME}/mcp"
HEADER_FILE=$(mktemp /tmp/mcp_headers.XXXXXX)
AUTH_ENABLED=false
TOKEN=""

cleanup() {
    rm -f "$HEADER_FILE"
}
trap cleanup EXIT

# Auto-detect whether authentication is in force, so the script does the right
# thing whether it is run after Phase 5 or after Phase 9. Running without auth
# against an authenticated gateway otherwise fails with a bare "Unauthorized".
MCP_NS="${MCP_NS:-mcp-gateway}"
if [[ "${1:-}" == "--with-auth" ]]; then
    AUTH_ENABLED=true
elif [[ "${1:-}" == "--no-auth" ]]; then
    AUTH_ENABLED=false
elif oc get authpolicy -n "$MCP_NS" -o name 2>/dev/null | grep -q authpolicy; then
    AUTH_ENABLED=true
    log_info "Detected an AuthPolicy in $MCP_NS; running in authenticated mode"
fi

log_step "MCP Gateway Verification"
log_info "Cluster domain: $CLUSTER_DOMAIN"
log_info "MCP endpoint:   $MCP_URL"
log_info "Auth enabled:   $AUTH_ENABLED (override with --with-auth / --no-auth)"

# Step 1: Initialize MCP session
log_step "Step 1: Initialize MCP Session"

AUTH_HEADER=""
if [[ "$AUTH_ENABLED" == "true" ]]; then
    KEYCLOAK_URL="https://$(oc get route keycloak -n mcp-test -o jsonpath='{.spec.host}')"
    KEYCLOAK_ISSUER="${KEYCLOAK_URL}/realms/mcp"
    log_info "Getting token from $KEYCLOAK_ISSUER"

    TOKEN=$(curl -sk -X POST "${KEYCLOAK_ISSUER}/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=password&client_id=mcp-gateway&username=mcp&password=mcp&scope=openid groups roles" | jq -r '.access_token')

    if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
        log_error "Failed to obtain token from Keycloak"
        exit 1
    fi
    log_ok "Token obtained successfully"
    AUTH_HEADER="-H \"Authorization: Bearer ${TOKEN}\""
fi

INIT_RESPONSE=$(curl -sk -D "$HEADER_FILE" -X POST "$MCP_URL" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    ${AUTH_ENABLED:+-H "Authorization: Bearer ${TOKEN}"} \
    -d '{
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "verify-script", "version": "1.0.0"}
        }
    }')

if echo "$INIT_RESPONSE" | jq -e '.result.serverInfo' > /dev/null 2>&1; then
    SERVER_NAME=$(echo "$INIT_RESPONSE" | jq -r '.result.serverInfo.name')
    log_ok "MCP session initialized - server: $SERVER_NAME"
else
    log_error "Failed to initialize MCP session"
    log_error "Response: $INIT_RESPONSE"
    exit 1
fi

# Step 2: Capture session ID
log_step "Step 2: Capture Session ID"

SESSION_ID=$(grep -i "mcp-session-id:" "$HEADER_FILE" | cut -d' ' -f2 | tr -d '\r')

if [[ -z "$SESSION_ID" ]]; then
    log_error "No mcp-session-id found in response headers"
    exit 1
fi
log_ok "Session ID: $SESSION_ID"

# Step 3: List tools
log_step "Step 3: List Available Tools"

TOOLS_RESPONSE=$(curl -sk -X POST "$MCP_URL" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "mcp-session-id: ${SESSION_ID}" \
    ${AUTH_ENABLED:+-H "Authorization: Bearer ${TOKEN}"} \
    -d '{"jsonrpc": "2.0", "id": 2, "method": "tools/list"}')

TOOL_COUNT=$(echo "$TOOLS_RESPONSE" | jq '.result.tools | length')
log_ok "Found $TOOL_COUNT tools"

echo "$TOOLS_RESPONSE" | jq -r '.result.tools[].name' | while read -r tool; do
    echo "  - $tool"
done

# Step 4: Verify tool prefixes
log_step "Step 4: Verify Tool Prefixes"

EXPECTED_PREFIXES=("test1_" "risk_" "dw_")
FOUND_PREFIXES=()

for prefix in "${EXPECTED_PREFIXES[@]}"; do
    count=$(echo "$TOOLS_RESPONSE" | jq --arg p "$prefix" '[.result.tools[].name | select(startswith($p))] | length')
    if [[ "$count" -gt 0 ]]; then
        FOUND_PREFIXES+=("$prefix")
        log_ok "Found $count tools with prefix '$prefix'"
    else
        log_warn "No tools found with prefix '$prefix'"
    fi
done

# Step 5: Test tool call
log_step "Step 5: Test Tool Call (risk_calculate_dti)"

CALL_RESPONSE=$(curl -sk -X POST "$MCP_URL" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "mcp-session-id: ${SESSION_ID}" \
    ${AUTH_ENABLED:+-H "Authorization: Bearer ${TOKEN}"} \
    -d '{
        "jsonrpc": "2.0",
        "id": 3,
        "method": "tools/call",
        "params": {
            "name": "risk_calculate_dti",
            "arguments": {
                "monthly_income": 8000,
                "monthly_debts": 2400
            }
        }
    }')

CALL_JSON=$(echo "$CALL_RESPONSE" | grep '^data: ' | head -1 | sed 's/^data: //' || true)
if [[ -z "$CALL_JSON" ]]; then
    CALL_JSON="$CALL_RESPONSE"
fi

if echo "$CALL_JSON" | jq -e '.result.content' > /dev/null 2>&1; then
    TOOL_RESULT=$(echo "$CALL_JSON" | jq -r '.result.content[0].text')
    log_ok "Tool call succeeded: $TOOL_RESULT"
else
    log_warn "Tool call did not return expected result"
    log_warn "Response: $(echo "$CALL_JSON" | head -c 200)"
fi

# Step 6: Auth-specific checks
if [[ "$AUTH_ENABLED" == "true" ]]; then
    log_step "Step 6: Auth-Specific Checks"

    # Check OAuth discovery
    OAUTH_DISCOVERY=$(curl -sk "https://${MCP_HOSTNAME}/.well-known/oauth-protected-resource")
    if echo "$OAUTH_DISCOVERY" | jq -e '.authorization_servers' > /dev/null 2>&1; then
        log_ok "OAuth discovery endpoint working"
    else
        log_warn "OAuth discovery endpoint not responding as expected"
    fi

    # Check 401 without token
    UNAUTH_CODE=$(curl -sk -o /dev/null -w '%{http_code}' -X POST "$MCP_URL" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')
    if [[ "$UNAUTH_CODE" == "401" ]]; then
        log_ok "Unauthenticated request correctly returns 401"
    else
        log_warn "Unauthenticated request returned $UNAUTH_CODE (expected 401)"
    fi

    # Check restricted user authz (403 for denied tools)
    KEYCLOAK_URL="https://$(oc get route keycloak -n mcp-test -o jsonpath='{.spec.host}' 2>/dev/null || oc get route -n mcp-test -o jsonpath='{.items[0].spec.host}' 2>/dev/null)"
    if [[ -n "$KEYCLOAK_URL" ]] && [[ "$KEYCLOAK_URL" != "https://" ]]; then
        RESTRICTED_TOKEN=$(curl -sk "${KEYCLOAK_URL}/realms/mcp/protocol/openid-connect/token" \
            -d "grant_type=password&client_id=mcp-gateway&username=restricted&password=restricted" | jq -r '.access_token' 2>/dev/null)
        if [[ -n "$RESTRICTED_TOKEN" ]] && [[ "$RESTRICTED_TOKEN" != "null" ]]; then
            R_SID=$(curl -vsk "$MCP_URL" \
                -H "Authorization: Bearer ${RESTRICTED_TOKEN}" \
                -H "Content-Type: application/json" \
                -H "Accept: application/json, text/event-stream" \
                -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"verify","version":"1.0"}}}' 2>&1 | grep -i 'mcp-session-id' | head -1 | sed 's/.*: //' | tr -d '\r')
            if [[ -n "$R_SID" ]]; then
                curl -sk "$MCP_URL" \
                    -H "Authorization: Bearer ${RESTRICTED_TOKEN}" \
                    -H "Content-Type: application/json" \
                    -H "Accept: application/json, text/event-stream" \
                    -H "Mcp-Session-Id: ${R_SID}" \
                    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' > /dev/null 2>&1
                AUTHZ_CODE=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "$MCP_URL" \
                    -H "Authorization: Bearer ${RESTRICTED_TOKEN}" \
                    -H "Content-Type: application/json" \
                    -H "Accept: application/json, text/event-stream" \
                    -H "Mcp-Session-Id: ${R_SID}" \
                    -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"risk_calculate_dti","arguments":{"monthly_debts":1500,"monthly_income":5000}}}')
                if [[ "$AUTHZ_CODE" == "403" ]]; then
                    log_ok "Restricted user correctly denied with 403 for risk tools"
                else
                    log_warn "Restricted user got $AUTHZ_CODE for denied tool (expected 403)"
                fi
            else
                log_warn "Could not initialize session for restricted user"
            fi
        else
            log_warn "Could not get restricted user token"
        fi
    else
        log_warn "Keycloak route not found, skipping authz check"
    fi
fi

# Summary
log_step "Verification Summary"
log_ok "MCP Gateway endpoint: $MCP_URL"
log_ok "Session initialized successfully"
log_ok "Tools discovered: $TOOL_COUNT"
log_ok "Prefixes found: ${FOUND_PREFIXES[*]:-none}"

if [[ "${#FOUND_PREFIXES[@]}" -eq "${#EXPECTED_PREFIXES[@]}" ]]; then
    log_ok "All expected tool prefixes found"
else
    log_warn "Some expected tool prefixes were missing"
fi

echo ""
log_info "Verification complete."
