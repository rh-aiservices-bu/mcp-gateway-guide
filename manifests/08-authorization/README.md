# Phase 8: Authorization Manifests

Detailed explanation of the authorization AuthPolicy that enforces tool-level access control on the MCP Gateway.

## authpolicy-authz.yaml.tmpl

```yaml
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: mcp-authz-policy
  namespace: mcp-gateway
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: mcp-gateway
    sectionName: mcps
  rules:
    authentication:
      "keycloak":
        jwt:
          issuerUrl: ${KEYCLOAK_ISSUER}
    authorization:
      "tool-access-check":
        when:
          - predicate: "request.headers.exists(h, h == 'x-mcp-toolname')"
          - predicate: "request.headers['x-mcp-method'] == 'tools/call'"
        patternMatching:
          patterns:
            - predicate: |
                ('tool:' + request.headers['x-mcp-toolname']) in (
                  has(auth.identity.resource_access) &&
                  auth.identity.resource_access.exists(p, p == request.headers['x-mcp-servername'])
                    ? auth.identity.resource_access[request.headers['x-mcp-servername']].roles
                    : []
                )
    response:
      unauthorized:
        body:
          value: |
            {
              "jsonrpc": "2.0",
              "error": {
                "code": -32600,
                "message": "Forbidden: Insufficient permissions for this tool."
              }
            }
```

This is the second AuthPolicy in the two-policy architecture. While `mcp-auth-policy` (Phase 7) handles JWT validation on the public `mcp` listener, this policy handles tool-level authorization on the internal `mcps` listener.

### Target - the internal `mcps` listener

```yaml
targetRef:
  sectionName: mcps
```

This policy targets the `mcps` listener, not the public `mcp` one. This is important because the broker injects `x-mcp-toolname`, `x-mcp-servername`, and `x-mcp-method` headers only when forwarding requests to backend MCP servers through the internal listener. Those headers do not exist on the public listener, so authorization must happen here.

The request flow is:

1. Client sends `tools/call` to the public `mcp` listener
2. `mcp-auth-policy` validates the JWT on the `mcp` listener (Phase 7)
3. The broker processes the request, identifies the target tool and server
4. The broker forwards to the `mcps` listener with `x-mcp-toolname`, `x-mcp-servername`, and `x-mcp-method` headers
5. `mcp-authz-policy` (this policy) checks tool permissions on the `mcps` listener

### Authentication - JWT on the internal listener

```yaml
authentication:
  "keycloak":
    jwt:
      issuerUrl: ${KEYCLOAK_ISSUER}
```

You might wonder why JWT validation appears again here when the `mcp-auth-policy` already validates it on the public listener. The reason is that each AuthPolicy is independent - the `mcps` listener needs its own JWT validation to decode the token claims so the authorization rule can read `resource_access` from `auth.identity`. Without this, `auth.identity` would be empty and the CEL expression would have nothing to evaluate.

This does not mean the token is validated twice from the client's perspective. The client only hits the public `mcp` listener. The internal `mcps` listener receives forwarded requests from the broker, which passes the original JWT along.

### When conditions - only evaluate during tool calls

```yaml
when:
  - predicate: "request.headers.exists(h, h == 'x-mcp-toolname')"
  - predicate: "request.headers['x-mcp-method'] == 'tools/call'"
```

Both conditions must be true for the authorization rule to evaluate. This is critical:

- **`x-mcp-toolname` must exist** - The broker sets this header on all requests forwarded to backend servers, including `initialize` and `notifications/initialized`. Without this check, the policy would try to evaluate the CEL expression on requests that don't have a tool name.

- **`x-mcp-method` must equal `tools/call`** - This distinguishes actual tool execution from session setup. The broker forwards `initialize` requests to backends too (to set up sessions with each MCP server), and those also have `x-mcp-toolname` set. Without this filter, the authorization would deny session creation, causing the broker to return a misleading `500 Internal Server Error` instead of the clean `403 Forbidden` you'd expect.

When both conditions are false (session setup, tool listing, etc.), the authorization rule is skipped entirely and the request passes through.

### The CEL expression - role-based tool access

```
('tool:' + request.headers['x-mcp-toolname']) in (
  has(auth.identity.resource_access) &&
  auth.identity.resource_access.exists(p, p == request.headers['x-mcp-servername'])
    ? auth.identity.resource_access[request.headers['x-mcp-servername']].roles
    : []
)
```

This is a single CEL predicate that checks whether the user has permission to call the specific tool. Breaking it down step by step:

**Step 1 - Build the role name:**
```
'tool:' + request.headers['x-mcp-toolname']
```
Prepends `tool:` to the tool name from the header. For example, if the broker set `x-mcp-toolname: calculate_dti`, this becomes `tool:calculate_dti`.

**Step 2 - Find the roles array:**
```
has(auth.identity.resource_access) &&
auth.identity.resource_access.exists(p, p == request.headers['x-mcp-servername'])
  ? auth.identity.resource_access[request.headers['x-mcp-servername']].roles
  : []
```

This is a defensive ternary:
1. Does `resource_access` exist in the JWT claims?
2. Does it contain an entry matching the server name from `x-mcp-servername`?
3. If yes, return that server's `roles` array
4. If no, return an empty array `[]` (which will fail the `in` check)

**Step 3 - Check membership:**

The `in` operator checks if `tool:calculate_dti` exists in the roles array. If it does, the request is authorized. If not, it's denied.

### How the JWT claims map to this expression

The Keycloak realm in Phase 6 creates JWTs with this structure in the `resource_access` claim:

```json
{
  "resource_access": {
    "mcp-test/test-server1": {
      "roles": ["tool:greet", "tool:headers", "tool:add_tool", "tool:slow", "tool:time"]
    },
    "mcp-test/risk-server": {
      "roles": ["tool:calculate_dti", "tool:calculate_ltv", "tool:evaluate_credit_risk", "..."]
    }
  }
}
```

The keys (`mcp-test/test-server1`, `mcp-test/risk-server`) match what the broker sets in the `x-mcp-servername` header. The roles use the `tool:` prefix convention.

**User `mcp`** has roles for all tools on both servers - full access.

**User `restricted`** only has `tool:greet` on `mcp-test/test-server1` - they can greet but cannot call risk tools or any other test server tools.

### Unauthorized response

```yaml
response:
  unauthorized:
    body:
      value: |
        {
          "jsonrpc": "2.0",
          "error": {
            "code": -32600,
            "message": "Forbidden: Insufficient permissions for this tool."
          }
        }
```

When authorization fails, the response is a JSON-RPC error (not a plain HTTP error body). This keeps the response consistent with the MCP protocol. The HTTP status code is `403 Forbidden` (Kuadrant's default for `unauthorized` responses).

Note the distinction in Kuadrant terminology:
- `unauthenticated` (Phase 7) - No valid identity, returns 401
- `unauthorized` (this policy) - Valid identity but insufficient permissions, returns 403

### Template variables

- `${KEYCLOAK_ISSUER}` - The Keycloak realm URL (e.g., `https://keycloak-mcp-test.apps.cluster-xxx/realms/mcp`)

Substituted by `envsubst` before applying.

## Two-Policy Architecture

```
                          MCP Gateway
                    ┌─────────────────────┐
Client request ──>  │  mcp listener       │
                    │  (public, port 8080) │
                    │                     │
                    │  mcp-auth-policy    │  <-- Phase 7: JWT validation
                    │  - validates token  │      401 if no/bad token
                    │  - skips .well-known│
                    └────────┬────────────┘
                             │
                        [MCP Broker]
                    - reads MCP JSON-RPC
                    - identifies tool + server
                    - sets x-mcp-toolname
                    - sets x-mcp-servername
                    - sets x-mcp-method
                             │
                    ┌────────v────────────┐
                    │  mcps listener      │
                    │  (internal, *.local)│
                    │                     │
                    │  mcp-authz-policy   │  <-- Phase 8: tool-level authz
                    │  - checks roles     │      403 if no permission
                    │  - skips non-tool   │
                    └────────┬────────────┘
                             │
                      Backend MCP Server
```

The separation exists because the broker sits between the two listeners. It needs to parse the MCP request first to know which tool is being called, then set the headers that the authorization policy checks. You can't do tool-level authorization on the public listener because the tool name hasn't been extracted yet at that point.
