# MCP Gateway on OpenShift Guide

Step-by-step guide for installing and configuring MCP Gateway (Red Hat Connectivity Link 1.4) on OpenShift, with real examples of authentication and authorization using Red Hat Build of Keycloak (RHBK).

## What's Inside

- **Part 1 - Installation & Configuration**: Gateway API provider selection, OLM-based operator install, Gateway setup, MCPGatewayExtension, registration of in-cluster **and external** MCP servers, and end-to-end verification
- **Part 2 - Authentication & Authorization**: RHBK deployment, OAuth 2.1 / JWT authentication with AuthPolicy, tool-level authorization using CEL expressions, and virtual MCP servers

## Quick Start

```bash
git clone https://github.com/rh-aiservices-bu/mcp-gateway-guide.git
cd mcp-gateway-guide

# Full installation (phases 1-5)
./scripts/setup-mcp-gateway.sh

# With authentication and authorization (phases 1-9)
./scripts/setup-mcp-gateway.sh --with-auth
```

## Building the Docs

```bash
npm install -g @antora/cli@3.1 @antora/site-generator@3.1 @andrew-jones/antora-tabs-extension
antora generate site.yml
# open www/index.html
```

## Prerequisites

- OpenShift 4.19+ with cluster-admin access
- `oc` CLI authenticated
- `envsubst`, `curl`, `jq`, `python3` available on PATH

> **Note:** `setup-mcp-gateway.sh` installs OpenShift Service Mesh 3 and creates an Istio control plane. If your cluster already provides a GatewayClass (for example an Ingress-Operator-managed Istio), do not run it as-is - it would create a conflicting second control plane. Follow the phases manually instead; see Phase 1.
