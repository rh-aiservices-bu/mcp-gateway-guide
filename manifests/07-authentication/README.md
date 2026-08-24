# Phase 7: Authentication Manifests

Detailed explanation of each manifest used to configure OAuth 2.1 authentication for the MCP Gateway.

## kuadrant.yaml

```yaml
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata:
  name: kuadrant
  namespace: mcp-gateway
spec: {}
```

The Kuadrant CR activates the Kuadrant control plane in the `mcp-gateway` namespace. Without this CR, AuthPolicy resources are accepted by the API server but never enforced - Authorino (the auth engine) won't process them.

The `spec: {}` means use all defaults. The Kuadrant operator (installed as a dependency of the MCP Gateway operator) watches for this CR and configures:

- **Authorino integration** - Wires up the Authorino instance for auth evaluation
- **WASM plugin injection** - Deploys the `kuadrant-wasm-shim` plugin that Envoy loads to intercept requests and send them to Authorino for auth checks
- **Limitador integration** - Sets up rate limiting infrastructure (not used in this phase but available for RateLimitPolicy)

After creating this CR, the gateway proxy deployment needs a restart so it can fetch the WASM plugin binary from the `kuadrant-operator-wasm` service. If the plugin fails to load on first boot, the gateway fails closed (blocks all traffic).

## authpolicy-auth.yaml.tmpl

```yaml
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: mcp-auth-policy
  namespace: mcp-gateway
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: mcp-gateway
    sectionName: mcp
  defaults:
    when:
      - predicate: "!request.path.contains('/.well-known')"
    rules:
      authentication:
        "keycloak":
          jwt:
            issuerUrl: ${KEYCLOAK_ISSUER}
      response:
        unauthenticated:
          code: 401
          headers:
            "WWW-Authenticate":
              value: Bearer resource_metadata=https://${MCP_HOSTNAME}/.well-known/oauth-protected-resource/mcp
          body:
            value: |
              {
                "error": "Unauthorized",
                "message": "Authentication required."
              }
```

This AuthPolicy enforces JWT authentication on the MCP Gateway's public `mcp` listener. It is the first layer of the two-AuthPolicy architecture (the second being the authorization policy in Phase 8).

### Target

Attached to the `mcp` sectionName (listener) of the `mcp-gateway` Gateway object via `targetRef`. This means it only affects traffic entering through the public listener, not the internal `mcps` listener used for backend routing.

### When condition

The policy only evaluates when the request path does NOT contain `/.well-known`. This excludes OAuth discovery endpoints (like `/.well-known/oauth-protected-resource`) so they remain publicly accessible without a token. MCP clients need those endpoints to discover how to authenticate before they have a token.

### Authentication rule (`keycloak`)

Validates incoming JWTs against the Keycloak OIDC issuer URL (`${KEYCLOAK_ISSUER}` is substituted at apply time via `envsubst`). Under the hood, Authorino fetches the JWKS keys from `${KEYCLOAK_ISSUER}/.well-known/openid-configuration` and uses them to verify token signatures. If the token is valid and not expired, the request passes through with the decoded JWT claims available for downstream policies.

### Unauthenticated response

When a request arrives without a token or with an invalid/expired one, the policy returns:

- **HTTP 401** status code
- A **JSON body** with `"Authentication required."` message
- A **`WWW-Authenticate` header** pointing to `/.well-known/oauth-protected-resource/mcp`

The `WWW-Authenticate` header is the key piece for MCP OAuth 2.1 compliance. It tells MCP clients where to find the protected resource metadata document, which contains the Keycloak authorization and token endpoints. This is how MCP Inspector and any compliant MCP client discovers how to authenticate automatically - they read this header, fetch the metadata, and start the OAuth flow.

### Defaults and strategy

The `defaults` wrapper means this policy provides default auth rules that can be overridden by more specific policies (like an HTTPRoute-level AuthPolicy). The `strategy: atomic` (auto-set by Kuadrant) means all rules are applied as a single unit - if any rule fails, the whole policy fails.

### Template variables

- `${KEYCLOAK_ISSUER}` - The Keycloak realm URL (e.g., `https://keycloak-mcp-test.apps.cluster-xxx/realms/mcp`)
- `${MCP_HOSTNAME}` - The MCP Gateway external hostname (e.g., `mcp.apps.cluster-xxx`)

Both are substituted by `envsubst` before applying.

## mcpgatewayextension-oauth-patch.yaml.tmpl

```yaml
apiVersion: mcp.kuadrant.io/v1alpha1
kind: MCPGatewayExtension
metadata:
  name: mcp-extension
  namespace: mcp-gateway
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: mcp-gateway
    namespace: mcp-gateway
    sectionName: mcp
  httpRouteManagement: Enabled
  oauthProtectedResource:
    resourceName: "MCP Gateway"
    resource: "https://${MCP_HOSTNAME}/mcp"
    authorizationServers:
      - "${KEYCLOAK_ISSUER}"
    bearerMethodsSupported:
      - header
    scopesSupported:
      - openid
      - groups
      - roles
```

This is the full MCPGatewayExtension manifest with OAuth configuration. In practice, Phase 3 creates the base MCPGatewayExtension and Phase 7 patches it with `oc patch --type=merge` to add the `oauthProtectedResource` field. This template is kept as reference for the complete desired state.

### oauthProtectedResource

This field configures the MCP Gateway broker to serve the OAuth 2.1 Protected Resource Metadata document at `/.well-known/oauth-protected-resource/mcp`. When an MCP client gets a `401` with the `WWW-Authenticate` header, it fetches this document to discover:

- **`resource`** - The protected resource identifier (the MCP endpoint URL)
- **`authorization_servers`** - Where to go for tokens (Keycloak issuer URL). The client fetches `${KEYCLOAK_ISSUER}/.well-known/openid-configuration` to get the token and authorization endpoints.
- **`bearer_methods_supported`** - How to send the token (`header` means `Authorization: Bearer <token>`)
- **`scopes_supported`** - What OAuth scopes the resource supports (`openid` for identity, `groups` for group claims, `roles` for role-based access in Phase 8)

The broker sets these as environment variables on the deployment (`MCP_OAUTH_RESOURCE_NAME`, `MCP_OAUTH_RESOURCE`, etc.) and serves the metadata as a JSON document. Do NOT use `oc set env` to configure these directly - the MCP Gateway operator reconciles the deployment and will overwrite manually set variables.

### Template variables

- `${MCP_HOSTNAME}` - The MCP Gateway external hostname
- `${KEYCLOAK_ISSUER}` - The Keycloak realm URL

## envoyfilter-auth-ssl.yaml

```yaml
apiVersion: networking.istio.io/v1alpha3
kind: EnvoyFilter
metadata:
  name: mcp-gateway-auth-ssl
  namespace: mcp-gateway
spec:
  priority: -1
  configPatches:
  - applyTo: CLUSTER
    match:
      cluster:
        service: authorino-authorino-authorization.mcp-gateway.svc.cluster.local
    patch:
      operation: ADD
      value:
        name: kuadrant-auth-service
        type: STRICT_DNS
        connect_timeout: 1s
        http2_protocol_options: {}
        lb_policy: ROUND_ROBIN
        load_assignment:
          cluster_name: kuadrant-auth-service
          endpoints:
          - lb_endpoints:
            - endpoint:
                address:
                  socket_address:
                    address: authorino-authorino-authorization.mcp-gateway.svc.cluster.local
                    port_value: 50051
        transport_socket:
          name: envoy.transport_sockets.tls
          typed_config:
            '@type': type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext
            common_tls_context:
              validation_context:
                trusted_ca:
                  filename: /var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: mcp-gateway
```

**This EnvoyFilter is NOT used in the default installation.** It is kept as a reference for environments where the Authorino service has TLS enabled on its gRPC endpoint (port 50051).

### When you need it

By default, the Kuadrant WASM plugin in the gateway proxy connects to Authorino's gRPC authorization service over plain-text. On some clusters (depending on Authorino operator version or cluster security policies), Authorino may be configured with TLS on its gRPC endpoint. In that case, the Envoy proxy will fail to connect because it tries plain-text against a TLS endpoint.

### What it does

This EnvoyFilter patches the Envoy cluster configuration for the Authorino service to add TLS:

- **`applyTo: CLUSTER`** - Patches at the Envoy cluster level (upstream connection config)
- **`match`** - Targets the cluster for `authorino-authorino-authorization.mcp-gateway.svc.cluster.local`
- **`transport_socket`** - Adds TLS context using the OpenShift service CA certificate (`/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt`) to validate Authorino's TLS certificate
- **`http2_protocol_options`** - Required because gRPC runs over HTTP/2
- **`priority: -1`** - Ensures this filter is applied before others

### How to know if you need it

Check the Authorino deployment logs. If you see connection errors from the gateway proxy to Authorino (TLS handshake failures or connection refused), apply this EnvoyFilter. On fresh OCP 4.21 clusters with RHCL 1.4.2, this is typically not needed.

## Request Flow

```
MCP Client
    |
    | 1. POST /mcp (no token)
    v
[mcp listener] --> [kuadrant-wasm-shim] --> [Authorino]
    |                                           |
    |                     2. No valid JWT found  |
    |<------------------------------------------+
    | 3. 401 + WWW-Authenticate header
    v
MCP Client
    |
    | 4. GET /.well-known/oauth-protected-resource/mcp
    v
[mcp listener] --> [broker serves metadata]
    |
    | 5. Discovers Keycloak issuer
    v
MCP Client
    |
    | 6. OAuth flow with Keycloak (get token)
    v
MCP Client
    |
    | 7. POST /mcp + Authorization: Bearer <token>
    v
[mcp listener] --> [kuadrant-wasm-shim] --> [Authorino]
    |                                           |
    |              8. JWT valid, claims decoded  |
    |<------------------------------------------+
    | 9. Request forwarded to broker
    v
[broker] --> [mcps listener] --> [backend MCP server]
```
