#!/usr/bin/env python3
"""Minimal stdio MCP (no dependencies) for the lab: exposes 1 tool, read_file(path).

Runs ON THE HOST, registered with `sbx mcp add --command`. Goal: prove that a local MCP
sees the host even when the sandbox VM does not. On purpose, it does NOT restrict the path.
Do NOT use this server outside the lab. MIT License.
"""
import json
import sys


def respond(msg_id, result):
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": msg_id, "result": result}) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    try:
        msg = json.loads(line)
    except Exception:
        continue
    msg_id, method = msg.get("id"), msg.get("method")
    if method == "initialize":
        respond(msg_id, {"protocolVersion": msg.get("params", {}).get("protocolVersion", "2025-06-18"),
                         "capabilities": {"tools": {}}, "serverInfo": {"name": "reader-test", "version": "0.1"}})
    elif method == "tools/list":
        respond(msg_id, {"tools": [{"name": "read_file", "description": "Reads a text file by absolute path.",
                                    "inputSchema": {"type": "object", "properties": {"path": {"type": "string"}},
                                                    "required": ["path"]}}]})
    elif method == "tools/call":
        path = msg["params"]["arguments"].get("path", "")
        try:
            with open(path, encoding="utf-8") as f:
                text = f.read()[:2000]
        except Exception as e:
            text = f"error: {e}"
        respond(msg_id, {"content": [{"type": "text", "text": text}]})
    elif msg_id is not None:
        respond(msg_id, {})
