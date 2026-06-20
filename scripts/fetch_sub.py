#!/usr/bin/env python3
"""Fetch proxy subscription and generate xray-core config."""

from __future__ import annotations

import base64
import json
import os
import sys
import urllib.request
from urllib.parse import parse_qs, unquote, urlparse


def fetch_subscription(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        raw = resp.read()
    try:
        return base64.b64decode(raw).decode("utf-8", errors="ignore")
    except Exception:
        return raw.decode("utf-8", errors="ignore")


def parse_vless(uri: str) -> dict | None:
    """Parse vless://UUID@host:port?params#name"""
    if not uri.startswith("vless://"):
        return None
    try:
        rest = uri[8:]
        main, _, fragment = rest.partition("#")
        userinfo_host, _, params_str = main.partition("?")
        uuid_part, _, host_port = userinfo_host.partition("@")
        host, _, port = host_port.rpartition(":")
        params = parse_qs(params_str)
        return {
            "protocol": "vless",
            "uuid": uuid_part,
            "address": host,
            "port": int(port),
            "security": params.get("security", ["none"])[0],
            "sni": params.get("sni", [""])[0],
            "type": params.get("type", ["tcp"])[0],
            "path": unquote(params.get("path", ["/"])[0]),
            "host": params.get("host", [""])[0],
            "fp": params.get("fp", [""])[0],
            "name": unquote(fragment) or "vless-node",
        }
    except Exception as e:
        print(f"  Failed to parse vless: {e}", file=sys.stderr)
        return None


def parse_vmess(uri: str) -> dict | None:
    """Parse vmess://base64json"""
    if not uri.startswith("vmess://"):
        return None
    try:
        b64 = uri[8:]
        padding = 4 - len(b64) % 4
        b64 += "=" * padding
        info = json.loads(base64.b64decode(b64))
        return {
            "protocol": "vmess",
            "uuid": info.get("id", ""),
            "address": info.get("add", ""),
            "port": int(info.get("port", 443)),
            "security": info.get("tls", ""),
            "sni": info.get("sni", ""),
            "type": info.get("net", "tcp"),
            "path": unquote(info.get("path", "/")),
            "host": info.get("host", ""),
            "fp": info.get("fp", ""),
            "name": info.get("ps", "vmess-node"),
        }
    except Exception as e:
        print(f"  Failed to parse vmess: {e}", file=sys.stderr)
        return None


def parse_trojan(uri: str) -> dict | None:
    """Parse trojan://password@host:port?params#name"""
    if not uri.startswith("trojan://"):
        return None
    try:
        rest = uri[9:]
        main, _, fragment = rest.partition("#")
        userinfo_host, _, params_str = main.partition("?")
        password, _, host_port = userinfo_host.partition("@")
        host, _, port = host_port.rpartition(":")
        params = parse_qs(params_str)
        return {
            "protocol": "trojan",
            "uuid": password,
            "address": host,
            "port": int(port),
            "security": params.get("security", ["tls"])[0],
            "sni": params.get("sni", [""])[0],
            "type": params.get("type", ["tcp"])[0],
            "path": unquote(params.get("path", ["/"])[0]),
            "host": params.get("host", [""])[0],
            "fp": params.get("fp", [""])[0],
            "name": unquote(fragment) or "trojan-node",
        }
    except Exception as e:
        print(f"  Failed to parse trojan: {e}", file=sys.stderr)
        return None


def node_to_xray_outbound(node: dict) -> dict:
    """Convert parsed node to xray outbound config."""
    protocol = node["protocol"]
    outbound = {
        "tag": "proxy",
        "protocol": protocol,
        "settings": {
            "vnext": [
                {
                    "address": node["address"],
                    "port": node["port"],
                    "users": [],
                }
            ]
        },
        "streamSettings": {
            "network": node["type"],
        },
    }

    if protocol == "vless":
        user = {"id": node["uuid"], "encryption": "none"}
        outbound["settings"]["vnext"][0]["users"].append(user)
    elif protocol == "vmess":
        user = {"id": node["uuid"], "alterId": 0, "security": "auto"}
        outbound["settings"]["vnext"][0]["users"].append(user)
    elif protocol == "trojan":
        outbound["settings"] = {
            "servers": [
                {
                    "address": node["address"],
                    "port": node["port"],
                    "password": node["uuid"],
                }
            ]
        }

    # Stream settings
    net = node["type"]
    stream = outbound["streamSettings"]

    if net == "ws":
        ws_settings = {"path": node["path"]}
        if node["host"]:
            ws_settings["headers"] = {"Host": node["host"]}
        stream["wsSettings"] = ws_settings

    # TLS
    security = node.get("security", "none")
    if security in ("tls", "reality"):
        stream["security"] = "tls"
        tls_settings = {}
        if node.get("sni"):
            tls_settings["serverName"] = node["sni"]
        if node.get("fp"):
            tls_settings["fingerprint"] = node["fp"]
        stream["tlsSettings"] = tls_settings

    return outbound


def generate_xray_config(node: dict, socks_port: int = 1080) -> dict:
    outbound = node_to_xray_outbound(node)
    return {
        "log": {"loglevel": "warning"},
        "inbounds": [
            {
                "tag": "socks-in",
                "port": socks_port,
                "listen": "127.0.0.1",
                "protocol": "socks",
                "settings": {"auth": "noauth", "udp": True},
            }
        ],
        "outbounds": [outbound],
    }


def main() -> int:
    sub_url = os.getenv("PROXY_SUB_URL", "").strip()
    output_path = os.getenv("XRAY_CONFIG_PATH", "/app/xray-config.json")
    socks_port = int(os.getenv("XRAY_SOCKS_PORT", "1080"))

    if not sub_url:
        print("PROXY_SUB_URL not set, skipping proxy setup")
        return 1

    print(f"Fetching subscription from {sub_url[:50]}...")
    try:
        content = fetch_subscription(sub_url)
    except Exception as e:
        print(f"Failed to fetch subscription: {e}", file=sys.stderr)
        return 1

    parsers = [parse_vless, parse_vmess, parse_trojan]
    nodes = []
    for line in content.strip().splitlines():
        line = line.strip()
        if not line:
            continue
        for parser in parsers:
            node = parser(line)
            if node:
                nodes.append(node)
                break

    if not nodes:
        print("No valid proxy nodes found in subscription", file=sys.stderr)
        return 1

    print(f"Found {len(nodes)} node(s):")
    for i, n in enumerate(nodes):
        print(f"  [{i}] {n['name']} ({n['protocol']}) - {n['address']}:{n['port']}")

    # Use the first node
    node = nodes[0]
    print(f"Using node: {node['name']}")

    config = generate_xray_config(node, socks_port)
    with open(output_path, "w") as f:
        json.dump(config, f, indent=2)

    print(f"Xray config written to {output_path}")
    print(f"Local SOCKS5 proxy will be at 127.0.0.1:{socks_port}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
