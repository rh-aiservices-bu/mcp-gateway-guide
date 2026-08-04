"""MCP Gateway Protocol Tester - Streamlit UI."""

import argparse
import base64
import json
import os
import sys

import requests
import streamlit as st
import streamlit.components.v1 as components

# ---------------------------------------------------------------------------
# CLI args
# ---------------------------------------------------------------------------

parser = argparse.ArgumentParser()
parser.add_argument("--url", default=os.environ.get("MCP_GATEWAY_URL", ""))
args, _ = parser.parse_known_args()

# ---------------------------------------------------------------------------
# Page config
# ---------------------------------------------------------------------------

st.set_page_config(
    page_title="MCP Gateway Tester",
    page_icon="\U0001f527",
    layout="wide",
)

# ---------------------------------------------------------------------------
# Session state defaults
# ---------------------------------------------------------------------------

_DEFAULTS = {
    "session_id": None,
    "cookies": {},
    "tools": [],
    "server_info": None,
    "steps": [],
    "token": None,
    "token_claims": None,
    "last_call_result": None,
    "last_call_tool": None,
}
for k, v in _DEFAULTS.items():
    if k not in st.session_state:
        st.session_state[k] = v

# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------

COMMON_HEADERS = {
    "Content-Type": "application/json",
    "Accept": "application/json, text/event-stream",
}


def mcp_post(url, body, session_id=None, token=None, cookies=None):
    headers = dict(COMMON_HEADERS)
    if session_id:
        headers["mcp-session-id"] = session_id
    if token:
        headers["Authorization"] = f"Bearer {token}"

    resp = requests.post(
        url,
        json=body,
        headers=headers,
        cookies=cookies or {},
        timeout=30,
        verify=False,
    )
    if resp.cookies:
        st.session_state.cookies.update(dict(resp.cookies))
    return resp


def _parse_sse(text):
    for line in text.strip().splitlines():
        if line.startswith("data: "):
            try:
                return json.loads(line[6:])
            except json.JSONDecodeError:
                continue
    return json.loads(text)


def _safe_parse(resp):
    ct = resp.headers.get("Content-Type", "")
    try:
        if "text/event-stream" in ct:
            return _parse_sse(resp.text)
        return resp.json()
    except (json.JSONDecodeError, ValueError):
        if resp.status_code >= 400:
            return {"error": f"HTTP {resp.status_code}", "message": resp.text[:200] or "(empty body)"}
        return {"error": "Invalid response", "message": resp.text[:200] or "(empty body)"}


# ---------------------------------------------------------------------------
# Token helpers
# ---------------------------------------------------------------------------


def get_keycloak_token(issuer_url, client_id, username, password, scope):
    token_url = f"{issuer_url}/protocol/openid-connect/token"
    resp = requests.post(
        token_url,
        data={
            "grant_type": "password",
            "client_id": client_id,
            "username": username,
            "password": password,
            "scope": scope,
        },
        verify=False,
        timeout=15,
    )
    resp.raise_for_status()
    return resp.json()["access_token"]


def decode_jwt_claims(token):
    parts = token.split(".")
    if len(parts) < 2:
        return {}
    payload = parts[1]
    payload += "=" * (4 - len(payload) % 4)
    return json.loads(base64.b64decode(payload))


# ---------------------------------------------------------------------------
# Protocol flow
# ---------------------------------------------------------------------------


def run_discovery(url, token=None):
    steps = []
    mcp_url = url.rstrip("/")
    if not mcp_url.endswith("/mcp"):
        mcp_url += "/mcp"

    # Step 1 - Initialize
    init_body = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "mcp-gateway-ui", "version": "1.0"},
        },
    }
    try:
        resp = mcp_post(
            mcp_url,
            init_body,
            token=token,
            cookies=st.session_state.cookies,
        )
        data = _safe_parse(resp)
        sid = resp.headers.get("Mcp-Session-Id") or resp.headers.get("mcp-session-id")
        if sid:
            st.session_state.session_id = sid
        init_ok = "result" in data
        st.session_state.server_info = data.get("result", {}).get("serverInfo")
        steps.append({
            "name": "Initialize",
            "method": "initialize",
            "status": resp.status_code,
            "ok": init_ok,
            "request": init_body,
            "response": data,
        })
        if not init_ok:
            st.session_state.steps = steps
            return steps
    except Exception as e:
        steps.append({"name": "Initialize", "method": "initialize", "ok": False, "error": str(e)})
        st.session_state.steps = steps
        return steps

    # Step 2 - Notify initialized
    notify_body = {"jsonrpc": "2.0", "method": "notifications/initialized"}
    try:
        resp = mcp_post(
            mcp_url,
            notify_body,
            session_id=st.session_state.session_id,
            token=token,
            cookies=st.session_state.cookies,
        )
        steps.append({
            "name": "Notify",
            "method": "notifications/initialized",
            "status": resp.status_code,
            "ok": resp.status_code in (200, 202, 204),
            "request": notify_body,
            "response": resp.text[:200] if resp.text else "(empty)",
        })
    except Exception as e:
        steps.append({"name": "Notify", "method": "notifications/initialized", "ok": False, "error": str(e)})

    # Step 3 - List tools
    list_body = {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}
    try:
        resp = mcp_post(
            mcp_url,
            list_body,
            session_id=st.session_state.session_id,
            token=token,
            cookies=st.session_state.cookies,
        )
        data = _safe_parse(resp)
        tools = data.get("result", {}).get("tools", [])
        st.session_state.tools = tools
        steps.append({
            "name": "List Tools",
            "method": "tools/list",
            "status": resp.status_code,
            "ok": len(tools) > 0,
            "request": list_body,
            "response": data,
            "tool_count": len(tools),
        })
    except Exception as e:
        steps.append({"name": "List Tools", "method": "tools/list", "ok": False, "error": str(e)})
        st.session_state.steps = steps
        return steps

    # Step 4 - Auto-call a tool
    tool_name, tool_args = _pick_auto_tool(st.session_state.tools)
    call_body = {
        "jsonrpc": "2.0",
        "id": 3,
        "method": "tools/call",
        "params": {"name": tool_name, "arguments": tool_args},
    }
    try:
        resp = mcp_post(
            mcp_url,
            call_body,
            session_id=st.session_state.session_id,
            token=token,
            cookies=st.session_state.cookies,
        )
        data = _safe_parse(resp)
        has_content = bool(data.get("result", {}).get("content"))
        steps.append({
            "name": "Call Tool",
            "method": f"tools/call ({tool_name})",
            "status": resp.status_code,
            "ok": has_content,
            "request": call_body,
            "response": data,
        })
    except Exception as e:
        steps.append({"name": "Call Tool", "method": "tools/call", "ok": False, "error": str(e)})

    st.session_state.steps = steps
    return steps


def _pick_auto_tool(tools):
    tool_map = {t["name"]: t for t in tools}
    if "risk_calculate_dti" in tool_map:
        return "risk_calculate_dti", {"monthly_income": 8000, "monthly_debts": 2400}
    if "test1_greet" in tool_map:
        return "test1_greet", {"name": "MCP Gateway UI"}
    if tools:
        first = tools[0]
        default_args = {}
        for p_name, p_info in first.get("inputSchema", {}).get("properties", {}).items():
            if p_info.get("type") == "number":
                default_args[p_name] = 0
            else:
                default_args[p_name] = ""
        return first["name"], default_args
    return "unknown", {}


def call_tool(url, tool_name, tool_args, token=None):
    mcp_url = url.rstrip("/")
    if not mcp_url.endswith("/mcp"):
        mcp_url += "/mcp"

    body = {
        "jsonrpc": "2.0",
        "id": 99,
        "method": "tools/call",
        "params": {"name": tool_name, "arguments": tool_args},
    }
    resp = mcp_post(
        mcp_url,
        body,
        session_id=st.session_state.session_id,
        token=token,
        cookies=st.session_state.cookies,
    )
    return _safe_parse(resp)


_HTTP_STATUS_LABELS = {
    400: "Bad Request",
    401: "Unauthorized - Enable Authentication in the sidebar and get a token first",
    403: "Forbidden - Token lacks required permissions for this operation",
    404: "Not Found - Check the MCP Gateway URL",
    500: "Internal Server Error",
    502: "Bad Gateway - MCP backend server may be down",
    503: "Service Unavailable",
}


def _step_error_text(step):
    if step.get("error"):
        return step["error"]
    status = step.get("status")
    resp = step.get("response", {})
    if isinstance(resp, dict) and resp.get("message"):
        label = f"HTTP {status} - {resp['error']}" if resp.get("error") else f"HTTP {status}"
        return f"{label}\n\n{resp['message']}"
    if status and status in _HTTP_STATUS_LABELS:
        return f"HTTP {status} - {_HTTP_STATUS_LABELS[status]}"
    if status:
        return f"HTTP {status}"
    return "FAIL"


# ---------------------------------------------------------------------------
# Sidebar
# ---------------------------------------------------------------------------

with st.sidebar:
    st.title("Configuration")

    gateway_url = st.text_input("MCP Gateway URL", value=args.url, placeholder="http://mcp.apps.example.com")

    st.divider()

    auth_enabled = st.checkbox("Enable Authentication")

    if auth_enabled:
        keycloak_issuer = st.text_input(
            "Keycloak Issuer URL",
            placeholder="https://sso.apps.example.com/realms/mcp",
        )
        client_id = st.text_input("Client ID", value="mcp-gateway")
        username = st.text_input("Username", value="mcp")
        password = st.text_input("Password", value="mcp", type="password")
        scope = st.text_input("Scope", value="openid groups roles")

        if st.button("Get Token", use_container_width=True):
            try:
                token = get_keycloak_token(keycloak_issuer, client_id, username, password, scope)
                st.session_state.token = token
                st.session_state.token_claims = decode_jwt_claims(token)
                st.success("Token obtained")
            except Exception as e:
                st.error(f"Token error: {e}")

        if st.session_state.token:
            claims = st.session_state.token_claims or {}
            st.caption(f"User: `{claims.get('preferred_username', '?')}`")
            groups = claims.get("groups", [])
            if groups:
                st.caption(f"Groups: `{', '.join(groups)}`")
            ra = claims.get("resource_access", {})
            if ra:
                with st.expander("Token roles", expanded=False):
                    st.json(ra)

    st.divider()
    st.caption("MCP Gateway Protocol Tester")
    st.caption("[Guide](https://rcarrata.github.io/mcp-gateway-guide/) | "
               "[Source](https://github.com/rcarrata/mcp-gateway-guide)")


# ---------------------------------------------------------------------------
# Main area
# ---------------------------------------------------------------------------

st.title("MCP Gateway Protocol Tester")

if not gateway_url:
    st.info("Enter the MCP Gateway URL in the sidebar to get started.")
    st.stop()

# Run discovery button
col_btn, col_url = st.columns([1, 3])
with col_btn:
    run_clicked = st.button("Run Discovery", type="primary", use_container_width=True)
with col_url:
    st.code(f"{gateway_url}/mcp", language=None)

if run_clicked:
    with st.spinner("Running MCP protocol flow..."):
        token = st.session_state.token if auth_enabled else None
        run_discovery(gateway_url, token=token)

# ---------------------------------------------------------------------------
# Protocol flow status cards
# ---------------------------------------------------------------------------

if st.session_state.steps:
    st.subheader("Protocol Flow")

    cols = st.columns(4)
    step_labels = ["Initialize", "Notify", "List Tools", "Call Tool"]
    step_icons = ["\U0001f91d", "\U0001f514", "\U0001f4cb", "\U000026a1"]

    for i, col in enumerate(cols):
        with col:
            if i < len(st.session_state.steps):
                step = st.session_state.steps[i]
                if step["ok"]:
                    st.success(f"{step_icons[i]} **{step['name']}**\n\nHTTP {step.get('status', '?')} - PASS")
                else:
                    st.error(f"{step_icons[i]} **{step['name']}**\n\n{_step_error_text(step)}")
            else:
                st.info(f"{step_icons[i]} **{step_labels[i]}**\n\nPending")

    # Step details
    for step in st.session_state.steps:
        with st.expander(f"Step: {step['name']} ({step['method']})", expanded=False):
            c1, c2 = st.columns(2)
            with c1:
                st.caption("Request")
                st.json(step.get("request", {}))
            with c2:
                st.caption("Response")
                resp = step.get("response", step.get("error", ""))
                if isinstance(resp, dict):
                    st.json(resp)
                else:
                    st.code(str(resp)[:500])

    # Summary metrics
    st.divider()
    m1, m2, m3, m4 = st.columns(4)
    passed = sum(1 for s in st.session_state.steps if s["ok"])
    total = len(st.session_state.steps)
    with m1:
        st.metric("Steps", f"{passed}/{total}")
    with m2:
        tool_count = next((s.get("tool_count", 0) for s in st.session_state.steps if s["name"] == "List Tools"), 0)
        st.metric("Tools Found", tool_count)
    with m3:
        sid = st.session_state.session_id or ""
        st.metric("Session", sid[:16] + "..." if len(sid) > 16 else sid or "-")
    with m4:
        si = st.session_state.server_info or {}
        st.metric("Server", si.get("name", "-"))

# ---------------------------------------------------------------------------
# Tool catalog
# ---------------------------------------------------------------------------

if st.session_state.tools:
    st.subheader(f"Tool Catalog ({len(st.session_state.tools)} tools)")

    for tool in st.session_state.tools:
        name = tool["name"]
        desc = tool.get("description", "")
        schema = tool.get("inputSchema", {})
        props = schema.get("properties", {})
        required = schema.get("required", [])

        with st.expander(f"`{name}` - {desc[:80]}"):
            if props:
                rows = []
                for p_name, p_info in props.items():
                    rows.append({
                        "Parameter": p_name,
                        "Type": p_info.get("type", "?"),
                        "Required": "yes" if p_name in required else "",
                        "Description": p_info.get("description", ""),
                    })
                st.table(rows)

            default_args = {}
            for p_name, p_info in props.items():
                if p_info.get("type") == "number":
                    default_args[p_name] = 0
                elif p_info.get("type") == "boolean":
                    default_args[p_name] = False
                else:
                    default_args[p_name] = ""

            args_input = st.text_area(
                "Arguments (JSON)",
                value=json.dumps(default_args, indent=2),
                height=100,
                key=f"args_{name}",
            )

            if st.button(f"Call {name}", key=f"call_{name}"):
                try:
                    parsed_args = json.loads(args_input)
                    token = st.session_state.token if auth_enabled else None
                    result = call_tool(gateway_url, name, parsed_args, token=token)
                    st.session_state.last_call_result = result
                    st.session_state.last_call_tool = name

                    content = result.get("result", {}).get("content", [])
                    if content:
                        for item in content:
                            st.code(item.get("text", str(item)), language="json")
                    elif "error" in result:
                        st.error(json.dumps(result["error"], indent=2))
                    else:
                        st.json(result)
                except json.JSONDecodeError as e:
                    st.error(f"Invalid JSON: {e}")
                except Exception as e:
                    st.error(f"Call failed: {e}")

# ---------------------------------------------------------------------------
# Interactive flow visualizer
# ---------------------------------------------------------------------------

st.divider()
st.subheader("How It Works")
st.markdown(
    "Interactive animated architecture flow for the MCP Gateway. "
    "Explore three flows: **Tool Discovery**, **Prefix Routing**, and **Progressive Discovery**. "
    "Click components and step through the animation to see how requests travel through the gateway."
)

components.iframe(
    "https://noyitz.github.io/ai-gateway-docs/mcp-gateway/",
    height=850,
    scrolling=True,
)
