#!/usr/bin/env python3
"""Seed repeatable, clearly named platform demo resources and traffic routes."""

import json
import os
from pathlib import Path
import sys
import time
import urllib.error
import urllib.request


BASE_URL = os.environ.get("QUICKSTART_CONTROL_PLANE_URL", "http://127.0.0.1:8081")
USERNAME = os.environ.get("QUICKSTART_ADMIN_USERNAME", "admin")
PASSWORD = os.environ.get("QUICKSTART_ADMIN_PASSWORD", "")
CENTER_CODE = os.environ.get("QUICKSTART_DEMO_CENTER_CODE", "quickstart-local")
ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "runtime" / "traffic-generator" / "manifest.json"
MARK = "Quickstart 演示数据："


def api(path, token=None, data=None, method=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    body = None if data is None else json.dumps(data, ensure_ascii=False).encode()
    req = urllib.request.Request(BASE_URL.rstrip("/") + path, body, headers,
                                 method=method or ("POST" if data is not None else "GET"))
    with urllib.request.urlopen(req, timeout=10) as response:
        result = json.load(response)
    if result.get("code") not in (None, 0):
        raise RuntimeError(f"{path}: {result.get('message', '接口请求失败')}")
    return result.get("data")


def page(token, kind):
    data = api(f"/api/orp/{kind}?page=1&pageSize=500", token)
    return data.get("items", []) if isinstance(data, dict) else data


def upsert(token, kind, payload, field):
    items = page(token, kind)
    old = next((item for item in items if item.get(field) == payload.get(field)), None)
    if old:
        if not str(old.get("description", "")).startswith(MARK) and kind not in ("centers", "settings"):
            raise RuntimeError(f"{kind} 中已有同名非演示资源 {payload[field]}，为保护现有数据未覆盖")
        if kind == "settings" and not str(old.get("description", "")).startswith(MARK):
            raise RuntimeError(f"配置项 {payload[field]} 已存在且不是 Quickstart 演示数据，未覆盖")
        return api(f"/api/orp/{kind}/{old['id']}", token, payload, "PUT")
    return api(f"/api/orp/{kind}", token, payload)


def seed_singletons(token):
    samples = {
        "http-directives": ({"directives": [{"name": "server_tokens", "value": "off"},
                                                {"name": "keepalive_timeout", "value": "65s"}]}, []),
        "stream-directives": ({"directives": [{"name": "tcp_nodelay", "value": "on"}]}, []),
        "http-log-format": ({"name": "quickstart_json", "format": "$remote_addr [$time_iso8601] $host \"$request\" $status $body_bytes_sent $request_time"}, {"name": "", "format": ""}),
        "stream-log-format": ({"name": "quickstart_stream", "format": "$remote_addr [$time_iso8601] $protocol $status $bytes_sent $bytes_received $session_time"}, {"name": "", "format": ""}),
        "http-error-pages": ({"errorPages": {"404|application/json": '{"error":"not found","demo":true}',
                                                  "503|application/json": '{"error":"service unavailable","demo":true}'}}, {}),
    }
    for name, (sample, empty) in samples.items():
        current = api(f"/api/orp/{name}", token)
        if current == empty or current == {"name": "", "format": ""}:
            api(f"/api/orp/{name}", token, sample, "PUT")


def main():
    if not PASSWORD:
        raise SystemExit("缺少管理员密码，无法准备平台演示数据")
    last_error = None
    for _ in range(30):
        try:
            token = api("/api/auth/login", data={"username": USERNAME, "password": PASSWORD})["accessToken"]
            break
        except (OSError, urllib.error.URLError, KeyError, RuntimeError) as exc:
            last_error = exc
            time.sleep(2)
    else:
        raise SystemExit(f"管理 API 登录失败：{last_error}")

    centers = page(token, "centers")
    center = next((item for item in centers if item.get("code") == CENTER_CODE), None)
    if not center:
        raise SystemExit(f"演示中心 {CENTER_CODE} 不存在，请先运行 quickstart-demo.sh")
    center_id = center["id"]
    center_payload = {
        "code": CENTER_CODE, "name": center.get("name", "Quickstart 本地演示中心"),
        "description": MARK + "上海区域演示中心，承载 HTTP、Stream、DNS 与节点配置。",
        "latitude": 31.2304, "longitude": 121.4737,
    }
    api(f"/api/orp/centers/{center_id}", token, center_payload, "PUT")

    node_items = page(token, "nodes")
    nodes = []
    for name, api_port, portal_port in (("openresty-east-1", 20080, 28080),
                                        ("openresty-east-2", 30080, 38080),
                                        ("openresty-east-3", 40080, 48080)):
        node = next((item for item in node_items if item.get("name") == name), None)
        if node:
            nodes.append({"name": name, "baseUrl": f"http://127.0.0.1:{api_port}",
                          "portalBaseUrl": f"http://127.0.0.1:{portal_port}"})

    group_specs = [
        {"name": "quickstart-demo-api", "description": MARK + "商品、订单与用户 API 演示上游。", "port": 19000,
         "tags": ["quickstart", "api", "demo"], "lbPolicy": "round_robin"},
        {"name": "quickstart-demo-backup", "description": MARK + "备用 API 上游与故障切换演示。", "port": 19001,
         "tags": ["quickstart", "backup", "demo"], "lbPolicy": "least_conn"},
        {"name": "quickstart-demo-stream", "description": MARK + "TCP Stream 演示后端。", "port": 19002,
         "tags": ["quickstart", "stream", "demo"], "lbPolicy": "round_robin"},
    ]
    for spec in group_specs:
        upsert(token, "upstream-groups", {
            "centerId": center_id, "name": spec["name"], "description": spec["description"],
            "tags": spec["tags"], "lbPolicy": spec["lbPolicy"], "hashKey": "",
            "healthCheck": {"type": "none", "intervalSec": 10, "path": "", "expectedStatus": []},
            "nodes": [{"host": "127.0.0.1", "port": spec["port"], "weight": 1,
                       "maxFails": 3, "failTimeoutSec": 10, "slowStartSec": 0, "backup": False}],
        }, "name")

    routes = [
        {"path": "/", "type": "direct", "returnCode": 200, "returnBody": "quickstart-demo-portal"},
        {"path": "/healthz", "type": "direct", "returnCode": 200, "returnBody": "quickstart-demo-healthy"},
        {"path": "/api/v1/products", "type": "proxy", "upstream": "http://quickstart-demo-api"},
        {"path": "/api/v1/orders", "type": "proxy", "upstream": "http://quickstart-demo-api"},
        {"path": "/api/v1/users", "type": "proxy", "upstream": "http://quickstart-demo-api"},
        {"path": "/api/v1/catalog", "type": "proxy", "upstream": "http://quickstart-demo-backup"},
        {"path": "/assets/demo.css", "type": "static", "rootPath": "/usr/share/nginx/html"},
    ]
    upsert(token, "http-listeners", {
        "centerId": center_id, "domain": "api.quickstart.local", "port": 80,
        "tlsCertId": None, "routes": routes,
        "directives": [{"name": "client_max_body_size", "value": "2m"}],
        "ipPolicy": {"enabled": False, "allowList": [], "denyList": [], "priority": "allow-first"},
        "errorPages": {"404|application/json": '{"error":"route not found"}'},
        "description": MARK + "API 网关演示，覆盖直返、代理、静态资源、指令和错误页。",
    }, "domain")
    upsert(token, "http-listeners", {
        "centerId": center_id, "domain": "portal.quickstart.local", "port": 8080,
        "tlsCertId": None, "routes": [routes[0], routes[1], routes[-1]],
        "directives": [], "description": MARK + "门户静态页面与健康检查演示。",
    }, "domain")

    upsert(token, "stream-services", {
        "centerId": center_id, "protocol": "tcp", "listenAddress": "0.0.0.0", "listenPort": 19090,
        "backends": ["quickstart-demo-stream:19002"], "directives": [],
        "description": MARK + "TCP 服务转发演示，后端切换由上游组配置。",
        "ipPolicy": {"enabled": False, "allowList": [], "denyList": [], "priority": "allow-first"},
    }, "listenPort")

    upsert(token, "dns-resolvers", {
        "centerId": center_id, "name": "quickstart-demo-dns", "description": MARK + "演示 DNS 解析器配置。",
        "address": "223.5.5.5", "port": 53, "timeoutSec": 3, "cacheTtlSec": 300,
    }, "address")
    upsert(token, "ip-groups", {
        "name": "quickstart-demo-private-networks", "description": MARK + "私网网段白名单演示，可导入 HTTP/Stream 访问策略。",
        "members": ["127.0.0.1/32", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"],
    }, "name")

    groups = page(token, "setting-groups")
    group_names = {item.get("name") for item in groups}
    setting_group = next((name for name in ("业务参数", "系统基础") if name in group_names), None)
    if setting_group:
        setting_values = [
            ("quickstart.demo.environment", "演示环境", "string", "local", "本地快速启动演示环境标识。"),
            ("quickstart.demo.request.timeout", "演示请求超时", "number", "3", "演示 API 网关请求超时秒数。"),
            ("quickstart.demo.feature.enabled", "演示功能开关", "boolean", "true", "演示功能开关配置项。"),
            ("quickstart.demo.routing", "演示路由策略", "json", '{"algorithm":"round_robin","retries":2}', "演示路由策略 JSON 配置。"),
        ]
        for key, name, value_type, value, description in setting_values:
            payload = {"key": key, "name": name, "group": setting_group, "type": value_type,
                       "value": value, "isSensitive": False, "status": "enabled",
                       "description": MARK + description}
            upsert(token, "settings", payload, "key")

    seed_singletons(token)
    manifest_routes = [
        {"host": "api.quickstart.local", "path": "/", "method": "GET"},
        {"host": "api.quickstart.local", "path": "/healthz", "method": "GET"},
        {"host": "api.quickstart.local", "path": "/api/v1/products", "method": "GET"},
        {"host": "api.quickstart.local", "path": "/api/v1/orders?limit=20", "method": "GET"},
        {"host": "api.quickstart.local", "path": "/api/v1/orders", "method": "POST"},
        {"host": "api.quickstart.local", "path": "/api/v1/users", "method": "GET"},
        {"host": "api.quickstart.local", "path": "/api/v1/catalog", "method": "GET"},
        {"host": "portal.quickstart.local", "path": "/", "method": "GET", "baseUrlKey": "portalBaseUrl"},
        {"host": "portal.quickstart.local", "path": "/assets/demo.css", "method": "GET", "baseUrlKey": "portalBaseUrl"},
    ]
    MANIFEST.parent.mkdir(parents=True, exist_ok=True)
    temporary = MANIFEST.with_suffix(".json.tmp")
    temporary.write_text(json.dumps({"nodes": nodes, "requests": manifest_routes}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(MANIFEST)
    print(f"已准备中心、节点、HTTP/Stream、Upstream、DNS、IP 组、系统配置及日志演示数据；请求清单包含 {len(manifest_routes)} 条路由，{len(nodes)} 个节点。")


if __name__ == "__main__":
    main()
