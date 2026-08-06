---
name: verify-guide
description: "End-to-end verification of the mcp-gateway-guide content on a live OpenShift cluster. Installs MCP Gateway (with optional auth), runs verify.sh, 10 blind-spot regression checks, and validates guide commands produce correct output."
argument-hint: "<API_URL> <USERNAME> <PASSWORD> [--skip-install] [--skip-verify-sh] [--skip-blindspot] [--skip-guide-content] [--with-auth]"
allowed-tools: Bash(oc *), Bash(./*), Bash(envsubst *), Bash(curl *), Bash(jq *), Bash(grep *), Bash(dig *), Bash(wc *), Bash(awk *), Bash(sed *), Bash(head *), Bash(tail *), Bash(tr *), Bash(sort *), Bash(openssl *), Bash(python3 *), Bash(ls *), Bash(cat *), Bash(date *), Bash(mkdir *), Bash(echo *), Bash(bash *), Write, Read, AskUserQuestion
---

# Verify MCP Gateway Guide on Live Cluster

End-to-end verification that the mcp-gateway-guide content is correct and working on a live OpenShift cluster. Runs installation via setup-mcp-gateway.sh, the verify.sh E2E script, 10 blind-spot regression checks, and validates that AsciiDoc guide commands produce documented output.

## Arguments

Parse `$ARGUMENTS` for these values:

- `<API_URL>` -- (required) OpenShift API server URL (e.g. `https://api.cluster-abc.dyn.redhatworkshops.io:6443`)
- `<USERNAME>` -- (required) Cluster admin username (e.g. `admin` or `kubeadmin`)
- `<PASSWORD>` -- (required) Cluster admin password
- `--skip-install` -- Skip Phase 1 (setup-mcp-gateway.sh). Use when MCP Gateway is already installed.
- `--skip-verify-sh` -- Skip Phase 2 (verify.sh E2E).
- `--skip-blindspot` -- Skip Phase 3 (10 blind-spot checks).
- `--skip-guide-content` -- Skip Phase 4 (AsciiDoc content verification).
- `--with-auth` -- Install with authentication/authorization (Phases 6-9 of setup-mcp-gateway.sh). Default: true.
- `--no-auth` -- Install without authentication (only Phases 1-5).
- `--from-phase N` -- Pass `--from-phase N` to setup-mcp-gateway.sh to resume.

If any of the three required arguments are missing, use `AskUserQuestion` to request them. Do NOT proceed without all three.

## Phases

| Phase | What it checks | Time |
|-------|---------------|------|
| 0 | Cluster login, preflight detection (platform, OCP version, nodes) | instant |
| 1 | Full MCP Gateway installation via `./scripts/setup-mcp-gateway.sh --with-auth` | 10-20 min |
| 2 | E2E verification via `./scripts/verify.sh --with-auth` | 1-2 min |
| 3 | 10 blind-spot regression checks (gateway namespace, HTTPS routes, Keycloak, AuthPolicy, etc.) | 1-2 min |
| 4 | AsciiDoc guide commands produce documented output | 1-2 min |
| 5 | Report generation + save findings to memory | instant |

## CRITICAL: Continuation Policy

**NEVER stop on failure.** Every phase and every individual check MUST run regardless of previous failures. Accumulate all results (PASS/FAIL/WARN with details) and report them together in Phase 5. The entire purpose of this skill is to find ALL issues in a single run, not to stop at the first one.

Track results using these counters (initialize at the start):
- `TOTAL_PASSED=0`
- `TOTAL_FAILED=0`
- `TOTAL_WARNED=0`
- Keep a list of all individual results with their phase, check name, and status.

## Instructions

Run from the guide repo root (`mcp-gateway-guide/`). Make sure your working directory is correct before starting.

---

### Phase 0: Cluster Login & Preflight

**Step 0a: Login**

```bash
oc login --server=<API_URL> -u <USERNAME> -p '<PASSWORD>' --insecure-skip-tls-verify=true
```

Verify the login succeeded with `oc whoami`. If it fails, report the error and ask the user to check credentials.

**Step 0b: Verify cluster-admin**

```bash
oc auth can-i '*' '*' --all-namespaces
```

Must return `yes`. If not, FAIL and warn the user that cluster-admin is required.

**Step 0c: Detect cluster characteristics**

Run these in parallel and record all values:

```bash
# Platform type (AWS, None, BareMetal, VSphere, etc.)
oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}'

# OCP version
oc get clusterversion version -o jsonpath='{.status.desired.version}'

# Node count and roles
oc get nodes --no-headers -o custom-columns='NAME:.metadata.name,ROLES:.metadata.labels.node-role\.kubernetes\.io/worker,STATUS:.status.conditions[-1].type'

# Cluster domain
oc get ingresses.config/cluster -o jsonpath='{.spec.domain}'
```

Record these values for the report:
- `PLATFORM_TYPE` (e.g. "None", "AWS")
- `OCP_VERSION` (e.g. "4.21.25")
- `NODE_COUNT`
- `CLUSTER_DOMAIN`
- `IS_CLOUD` = true if PLATFORM_TYPE is AWS, Azure, or GCP; false otherwise

**Step 0d: Report preflight to user**

Print a summary of detected cluster characteristics before proceeding.

---

### Phase 1: Install MCP Gateway via setup-mcp-gateway.sh

Skip this phase if `--skip-install` was passed. Report "Phase 1: SKIPPED (--skip-install)" and move to Phase 2.

**Step 1a: Run the installer**

```bash
cd /path/to/mcp-gateway-guide
./scripts/setup-mcp-gateway.sh --with-auth 2>&1
```

If `--no-auth` was passed, omit `--with-auth`:
```bash
./scripts/setup-mcp-gateway.sh 2>&1
```

If `--from-phase N` was passed, add it:
```bash
./scripts/setup-mcp-gateway.sh --with-auth --from-phase N 2>&1
```

**IMPORTANT**: This script can take 10-20 minutes. Run it and monitor the output.

**Step 1b: Handle known failures**

- If MCP Gateway operator CSV takes too long: wait for it, then resume with `--from-phase 2`
- If Keycloak pod fails readiness: check image pull status, then resume with `--from-phase 7`
- If AuthPolicy enforcement times out: check Kuadrant CR status and Authorino operator

**Step 1c: Record result**

- If setup-mcp-gateway.sh completes successfully: PASS
- If it fails but MCP Gateway is partially installed: WARN with details
- If it fails completely: FAIL with error details, but CONTINUE to Phase 2

---

### Phase 2: Run verify.sh E2E

Skip this phase if `--skip-verify-sh` was passed.

**Step 2a: Run verification**

```bash
cd /path/to/mcp-gateway-guide
./scripts/verify.sh --with-auth 2>&1
```

If `--no-auth` was passed:
```bash
./scripts/verify.sh 2>&1
```

**Step 2b: Parse results**

From the output, extract:
- Every line containing `[OK]` or `[ERROR]` - record each individually
- Any `[WARN]` lines
- Final verification summary

Add results to TOTAL_PASSED/TOTAL_FAILED/TOTAL_WARNED.

---

### Phase 3: Blind Spot Checks

Skip this phase if `--skip-blindspot` was passed.

These 10 checks catch regressions that verify.sh does not test. Run ALL 10 regardless of individual failures.

#### Check 1: Gateway Deployment in gateway-system

With `openshift-default` GatewayClass, the gateway proxy deploys to `gateway-system`, NOT to `mcp-gateway`.

```bash
GW_DEPLOY=$(oc get deployment -n gateway-system --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null | grep mcp-gateway || echo "")
```

- PASS if a deployment matching `mcp-gateway-openshift-default` is found in `gateway-system`
- FAIL if no deployment found in `gateway-system` (might be in wrong namespace)
- Record the exact deployment name

#### Check 2: HTTPS Route Exists

With `openshift-default`, OpenShift creates a Route for TLS edge termination. All external traffic MUST go through HTTPS.

```bash
ROUTES=$(oc get routes -n gateway-system --no-headers 2>/dev/null | grep mcp || echo "")
```

- PASS if at least one Route exists for the gateway in `gateway-system`
- Verify the Route has TLS configured: `oc get route -n gateway-system -o jsonpath='{.items[0].spec.tls.termination}' 2>/dev/null`
- FAIL if no routes found
- WARN if route exists but has no TLS termination

#### Check 3: MCP Endpoint Reachable via HTTPS

```bash
CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
MCP_HOSTNAME="mcp.${CLUSTER_DOMAIN}"
HTTP_CODE=$(curl -sk --connect-timeout 10 --max-time 15 -o /dev/null -w '%{http_code}' "https://${MCP_HOSTNAME}/mcp" -X POST \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0.0"}}}')
```

- PASS if HTTP code is 200, 401, or 403 (any valid response proves the endpoint works)
- FAIL if HTTP 000 (connection refused) or empty
- WARN if HTTP 404 or 502 (gateway not ready)

#### Check 4: HTTP Must NOT Work (Only HTTPS)

```bash
HTTP_CODE=$(curl -s --connect-timeout 5 --max-time 10 -o /dev/null -w '%{http_code}' "http://${MCP_HOSTNAME}/mcp" 2>/dev/null || echo "000")
```

- PASS if HTTP returns 000 (connection refused), 301/302 (redirect to HTTPS), or 404
- FAIL if HTTP returns 200 (plain HTTP should not be serving the MCP endpoint)
- This validates the guide's migration from Istio (which had port 80) to openshift-default (HTTPS only)

#### Check 5: MCPGatewayExtension Ready

```bash
MGE_STATUS=$(oc get mcpgatewayextension mcp-extension -n mcp-gateway -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "UNKNOWN")
```

- PASS if status is "True"
- FAIL if status is "False" or "UNKNOWN"
- Check controller logs for errors: `oc logs deployment/mcp-gateway-controller -n mcp-gateway --tail=10 2>/dev/null`

#### Check 6: MCPServerRegistrations Ready

```bash
MCPSR_STATUS=$(oc get mcpsr -n mcp-gateway --no-headers 2>/dev/null || echo "")
```

- PASS if at least 2 MCPServerRegistrations exist (test-server1, risk-server)
- Check each for Ready condition
- FAIL if fewer than 2 or any not Ready
- Record the names and statuses

#### Check 7: Keycloak OIDC Discovery (auth mode only)

Skip if `--no-auth` was passed.

```bash
KEYCLOAK_URL="https://$(oc get route keycloak -n mcp-test -o jsonpath='{.spec.host}' 2>/dev/null || echo "")"
OIDC_RESP=$(curl -sk --connect-timeout 10 "${KEYCLOAK_URL}/realms/mcp/.well-known/openid-configuration" 2>/dev/null)
ISSUER=$(echo "$OIDC_RESP" | jq -r '.issuer // empty' 2>/dev/null)
```

- PASS if OIDC discovery returns a valid issuer URL
- FAIL if Keycloak route not found or OIDC returns empty/invalid
- WARN if issuer URL doesn't match the expected format

#### Check 8: AuthPolicy Enforcement (auth mode only)

Skip if `--no-auth` was passed.

```bash
# Check both auth policies exist and are enforced
AUTH_ENFORCED=$(oc get authpolicy mcp-auth-policy -n mcp-gateway -o jsonpath='{.status.conditions[?(@.type=="Enforced")].status}' 2>/dev/null || echo "UNKNOWN")
AUTHZ_ENFORCED=$(oc get authpolicy mcp-authz-policy -n mcp-gateway -o jsonpath='{.status.conditions[?(@.type=="Enforced")].status}' 2>/dev/null || echo "UNKNOWN")
```

- PASS if both `mcp-auth-policy` (Enforced=True) AND `mcp-authz-policy` (Enforced=True)
- FAIL if either is missing or not Enforced
- Verify the two-listener architecture: auth targets `mcp` listener, authz targets `mcps` listener

#### Check 9: Restricted User Authorization (auth mode only)

Skip if `--no-auth` was passed.

Test that the `restricted` user gets denied access to risk tools but can use greet:

```bash
KEYCLOAK_ISSUER="${KEYCLOAK_URL}/realms/mcp"

# Get restricted user token
RESTRICTED_TOKEN=$(curl -sk -X POST "${KEYCLOAK_ISSUER}/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=password&client_id=mcp-gateway&username=restricted&password=restricted&scope=openid groups roles" | jq -r '.access_token')

# Initialize session
curl -sk -D /tmp/r_headers -X POST "https://${MCP_HOSTNAME}/mcp" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${RESTRICTED_TOKEN}" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0.0"}}}'

R_SESSION=$(grep -i "mcp-session-id:" /tmp/r_headers | cut -d' ' -f2 | tr -d '\r')

# Call risk_calculate_dti - should be denied (403)
RISK_CODE=$(curl -sk -o /dev/null -w '%{http_code}' -X POST "https://${MCP_HOSTNAME}/mcp" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${RESTRICTED_TOKEN}" \
    -H "mcp-session-id: ${R_SESSION}" \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"risk_calculate_dti","arguments":{"monthly_income":8000,"monthly_debts":2400}}}')
```

- PASS if risk tool call returns 403 (restricted user denied access to risk tools)
- FAIL if returns 200 (authorization not enforced)
- WARN if returns 401 (authentication issue, not authorization)

#### Check 10: Virtual Server Filtering (auth mode only)

Skip if `--no-auth` was passed.

```bash
# Get mcp user token and session
TOKEN=$(curl -sk -X POST "${KEYCLOAK_ISSUER}/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=password&client_id=mcp-gateway&username=mcp&password=mcp&scope=openid groups roles" | jq -r '.access_token')

curl -sk -D /tmp/v_headers -X POST "https://${MCP_HOSTNAME}/mcp" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${TOKEN}" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1.0.0"}}}'

V_SESSION=$(grep -i "mcp-session-id:" /tmp/v_headers | cut -d' ' -f2 | tr -d '\r')

# List tools with risk-analysis virtual server header
RISK_TOOLS=$(curl -sk -X POST "https://${MCP_HOSTNAME}/mcp" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "mcp-session-id: ${V_SESSION}" \
    -H "X-Mcp-Virtualserver: mcp-gateway/risk-analysis" \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | jq -r '.result.tools[].name' 2>/dev/null)

RISK_TOOL_COUNT=$(echo "$RISK_TOOLS" | grep -c "risk_" || echo "0")
NON_RISK_COUNT=$(echo "$RISK_TOOLS" | grep -cv "risk_" 2>/dev/null || echo "0")
```

- PASS if RISK_TOOL_COUNT > 0 AND NON_RISK_COUNT == 0 (only risk tools returned)
- FAIL if non-risk tools appear in the risk-analysis virtual server response
- FAIL if no tools returned at all
- Check also that mcp-system namespace has the config secret: `oc get secret mcp-gateway-config -n mcp-system`

---

### Phase 4: Guide Content Verification

Skip this phase if `--skip-guide-content` was passed.

These checks verify that commands documented in the AsciiDoc guide pages produce the expected output.

#### Content Check 1: GatewayClass (02-gateway-setup.adoc)

The guide says `gatewayClassName: openshift-default`.

```bash
GW_CLASS=$(oc get gateway mcp-gateway -n mcp-gateway -o jsonpath='{.spec.gatewayClassName}' 2>/dev/null || echo "UNKNOWN")
```

- PASS if GW_CLASS is `openshift-default`
- FAIL if it's `istio` or anything else (guide migration incomplete)

#### Content Check 2: Gateway Listeners (02-gateway-setup.adoc)

The guide says the Gateway has two listeners: `mcp` (public) and `mcps` (internal).

```bash
LISTENERS=$(oc get gateway mcp-gateway -n mcp-gateway -o jsonpath='{range .spec.listeners[*]}{.name}{"\n"}{end}' 2>/dev/null)
```

- PASS if both `mcp` and `mcps` listeners exist
- FAIL if either is missing
- FAIL if an `http` listener exists on port 80 (leftover from Istio config)

#### Content Check 3: MCP Gateway CRDs (01-prerequisites.adoc)

```bash
CRDS=$(oc get crd --no-headers 2>/dev/null | grep -E 'mcp.*kuadrant' || echo "")
```

Expected CRDs: `mcpgatewayextensions.mcp.kuadrant.io`, `mcpserverregistrations.mcp.kuadrant.io`, `mcpvirtualservers.mcp.kuadrant.io`

- PASS for each CRD found
- FAIL for each missing CRD

#### Content Check 4: Route Namespace (02-gateway-setup.adoc)

The guide says to check routes in `gateway-system` (not `mcp-gateway`).

```bash
GW_ROUTES=$(oc get routes -n gateway-system --no-headers 2>/dev/null | grep mcp || echo "")
MCP_ROUTES=$(oc get routes -n mcp-gateway --no-headers 2>/dev/null | grep mcp || echo "")
```

- PASS if routes exist in `gateway-system`
- WARN if routes exist in `mcp-gateway` instead (guide may need updating)
- FAIL if no routes found in either namespace

#### Content Check 5: Operator CSV Status (01-prerequisites.adoc)

The guide documents the MCP Gateway operator must reach Succeeded:

```bash
MCP_CSV=$(oc get csv -n mcp-gateway --no-headers 2>/dev/null | grep mcp-gateway || echo "")
MCP_PHASE=$(echo "$MCP_CSV" | awk '{print $NF}')
```

- PASS if CSV exists and phase is Succeeded
- FAIL if CSV not found or phase is not Succeeded

#### Content Check 6: OAuth Discovery (07-authentication.adoc, auth mode only)

The guide says `curl -sk "https://${MCP_HOSTNAME}/.well-known/oauth-protected-resource"` should return the protected resource metadata.

```bash
OAUTH_DISC=$(curl -sk "https://${MCP_HOSTNAME}/.well-known/oauth-protected-resource" 2>/dev/null)
RESOURCE_NAME=$(echo "$OAUTH_DISC" | jq -r '.resource // empty' 2>/dev/null)
AUTH_SERVERS=$(echo "$OAUTH_DISC" | jq -r '.authorization_servers // empty' 2>/dev/null)
```

- PASS if response contains `resource` and `authorization_servers` fields
- PASS if `resource` value contains `https://` (not `http://`)
- FAIL if response is empty or malformed
- FAIL if `resource` uses `http://` (migration from Istio incomplete)

#### Content Check 7: Gateway Restart Command (07-authentication.adoc, auth mode only)

The guide documents restarting the gateway with:
```
oc rollout restart deployment/mcp-gateway-openshift-default -n gateway-system
```

Verify this deployment exists and the name matches what's in the guide:

```bash
DEPLOY_EXISTS=$(oc get deployment mcp-gateway-openshift-default -n gateway-system --no-headers 2>/dev/null | wc -l)
```

- PASS if deployment `mcp-gateway-openshift-default` exists in `gateway-system`
- FAIL if deployment name is different or not in that namespace

---

### Phase 5: Report Generation

#### Step 5a: Collect versions

```bash
MCP_GW_VERSION=$(oc get csv -n mcp-gateway --no-headers 2>/dev/null | grep mcp-gateway | awk '{print $1}' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "UNKNOWN")
AUTHORINO_VERSION=$(oc get csv -n mcp-gateway --no-headers 2>/dev/null | grep authorino | awk '{print $1}' | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || echo "UNKNOWN")
KUADRANT_READY=$(oc get kuadrant -n mcp-gateway -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "UNKNOWN")
```

#### Step 5b: Print the report

Print a structured report to the user with these sections:

**Header:**
```
=== VERIFY-GUIDE REPORT (mcp-gateway-guide) ===
Date: <today's date>
Cluster: <API_URL>
Platform: <PLATFORM_TYPE> | OCP: <OCP_VERSION> | Nodes: <NODE_COUNT>
MCP GW: <version> | Authorino: <version> | Kuadrant Ready: <yes/no>
```

**Summary:**
```
Total: X checks | PASSED: Y | FAILED: Z | WARNINGS: W
```

**Phase Results Table:**
For each phase, list every individual check with PASS/FAIL/WARN status.

**Failures (if any):**
List every FAIL with its phase, check name, expected value, and actual value.

**Warnings (if any):**
List every WARN with details.

#### Step 5c: Save findings to memory

Use the `Write` tool to save findings to:
`/Users/rcarrata/.claude/projects/-Users-rcarrata-Code-MCPGateway/memory/project_mcp-gateway-verify-v<N>.md`

Determine the walkthrough number:
- If `--walkthrough-number N` was passed, use N
- Otherwise, check existing memory files and auto-increment from 1

Include:
- Frontmatter with name, description, metadata (type: project)
- Date, cluster, OCP version, platform
- Result summary
- Issues found (numbered, with severity and details)
- Positive findings
- Blind spots verified table
- Operator versions

#### Step 5d: Cleanup (optional)

Teardown is NOT run automatically. Inform the user they can run:

```bash
./scripts/teardown.sh
```

---

## Known Issues to Watch For

| Issue | Description | Status |
|-------|------------|--------|
| Gateway deploys to gateway-system | openshift-default puts the proxy deployment in gateway-system, not mcp-gateway | BY DESIGN |
| HTTPS required | OpenShift Routes provide TLS edge termination; HTTP doesn't work | BY DESIGN |
| Route in gateway-system | Routes created in gateway-system, not mcp-gateway | BY DESIGN |
| Deployment name pattern | Deployment is named `<gw-name>-<gatewayclass>`, e.g. `mcp-gateway-openshift-default` | BY DESIGN |
| OperatorGroup mode | MCP Gateway operator uses OwnNamespace; Authorino needs AllNamespaces - setup-mcp-gateway.sh recreates the OG | HANDLED |
| Kuadrant CR required | AuthPolicy won't enforce without Kuadrant CR in the namespace | HANDLED |
| mcp-system namespace | Virtual server config secret goes to mcp-system, must exist before creating MCPVirtualServer | HANDLED |
| envoyfilter-accept-header.yaml | Istio-specific, not used with openshift-default but still in the repo | KNOWN |

## Troubleshooting

- **`oc login` fails**: Verify the API URL includes the port (`:6443`). Try `--insecure-skip-tls-verify=true`.
- **MCP Gateway CSV stuck**: Check `oc get csv -n mcp-gateway`. May need to wait longer on constrained clusters.
- **AuthPolicy not Enforced**: Check Kuadrant CR: `oc get kuadrant -n mcp-gateway`. Check Authorino: `oc get pods -n mcp-gateway | grep authorino`.
- **verify.sh fails at Step 1**: Gateway may not be ready. Check `oc get gateway -n mcp-gateway` and `oc get deployment -n gateway-system`.
- **HTTP 000 on MCP endpoint**: Gateway pod restarting. Check `oc get pods -n gateway-system`.
- **Virtual server "not found"**: Check mcp-system namespace exists and config secret is present. Restart broker.
- **Restricted user gets 200 on risk tools**: Authorization policy not enforced on mcps listener. Check `oc get authpolicy -n mcp-gateway`.
