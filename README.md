# MCP Gateway on OpenShift Guide

Step-by-step guide for installing and configuring MCP Gateway (Red Hat Connectivity Link 1.4) on OpenShift, with real examples of authentication and authorization using Keycloak.

## What's Inside

- **Part 1 - Installation & Configuration**: OLM-based operator install, Gateway setup, MCPGatewayExtension, MCP server registration, and end-to-end verification
- **Part 2 - Authentication & Authorization**: Keycloak deployment, OAuth 2.1 / JWT authentication with AuthPolicy, tool-level authorization using CEL expressions, and virtual MCP servers

## Quick Start

```bash
git clone https://github.com/rcarrata/mcp-gateway-guide.git
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
- `envsubst`, `curl`, `jq` available on PATH
