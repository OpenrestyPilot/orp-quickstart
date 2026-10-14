#!/usr/bin/env python3
"""Continuously replay configured demo routes across the managed nodes."""

import itertools
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import random
import socketserver
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path


MANIFEST = Path(os.environ.get("TRAFFIC_MANIFEST", "/runtime/manifest.json"))
FALLBACK_NODES = [
    {"name": "openresty-east-1", "baseUrl": "http://127.0.0.1:20080", "portalBaseUrl": "http://127.0.0.1:28080", "managementBaseUrl": "http://127.0.0.1:18080"},
    {"name": "openresty-east-2", "baseUrl": "http://127.0.0.1:30080", "portalBaseUrl": "http://127.0.0.1:38080", "managementBaseUrl": "http://127.0.0.1:18180"},
    {"name": "openresty-east-3", "baseUrl": "http://127.0.0.1:40080", "portalBaseUrl": "http://127.0.0.1:48080", "managementBaseUrl": "http://127.0.0.1:18280"},
]
FALLBACK_ROUTES = [
    {"host": "api.quickstart.local", "path": "/health", "method": "GET", "baseUrlKey": "managementBaseUrl"},
    {"host": "api.quickstart.local", "path": "/runtime/status", "method": "GET", "baseUrlKey": "managementBaseUrl"},
]
USER_AGENTS = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/129.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 Version/17.0 Safari/605.1.15",
    "curl/8.10.1",
)
BODY = b'{"source":"orp-quickstart-demo","quantity":1}'


class DemoAPI(BaseHTTPRequestHandler):
    def do_GET(self):
        payloads = {
            "/api/v1/products": {"items": [{"id": "demo-001", "name": "ORP 演示商品", "price": 29.9}], "total": 1},
            "/api/v1/orders": {"items": [{"id": "order-demo-001", "status": "已发货", "amount": 29.9}], "total": 1},
            "/api/v1/users": {"items": [{"id": "user-demo-001", "name": "演示用户", "role": "运维管理员"}], "total": 1},
            "/api/v1/catalog": {"categories": ["网关", "流量管理", "节点运维"]},
            "/healthz": {"status": "UP", "service": "quickstart-demo-api"},
        }
        self._send(payloads.get(self.path.split("?", 1)[0], {"message": "demo api is ready"}), 200)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(min(length, 1024 * 1024))
        try:
            submitted = json.loads(raw) if raw else {}
        except ValueError:
            submitted = {}
        self._send({"id": f"order-demo-{int(time.time())}", "status": "已受理", "received": submitted}, 201)

    def _send(self, document, status):
        body = json.dumps(document, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        return


class EchoHandler(socketserver.BaseRequestHandler):
    def handle(self):
        while True:
            data = self.request.recv(4096)
            if not data:
                return
            self.request.sendall(data)


def serve_mock_backends():
    for port in (19000, 19001):
        server = ThreadingHTTPServer(("0.0.0.0", port), DemoAPI)
        threading.Thread(target=server.serve_forever, daemon=True).start()
    tcp_server = socketserver.ThreadingTCPServer(("0.0.0.0", 19002), EchoHandler)
    threading.Thread(target=tcp_server.serve_forever, daemon=True).start()


def load_manifest():
    try:
        data = json.loads(MANIFEST.read_text(encoding="utf-8"))
        nodes = data.get("nodes") or FALLBACK_NODES
        routes = data.get("requests") or FALLBACK_ROUTES
        return nodes, routes
    except (OSError, ValueError, AttributeError):
        return FALLBACK_NODES, FALLBACK_ROUTES


def request(node, route):
    method = route.get("method", "GET").upper()
    headers = {
        "Host": route.get("host", "api.quickstart.local"),
        "User-Agent": random.choice(USER_AGENTS),
        "Accept": "application/json,text/html,*/*",
    }
    body = None
    if method in ("POST", "PUT", "PATCH"):
        headers["Content-Type"] = "application/json"
        body = BODY
    base_url = node.get(route.get("baseUrlKey", "baseUrl"), node["baseUrl"])
    req = urllib.request.Request(base_url.rstrip("/") + route.get("path", "/health"),
                                 data=body, headers=headers, method=method)
    timeout = float(os.environ.get("TRAFFIC_REQUEST_TIMEOUT_SECONDS", "3"))
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            return response.status, None
    except urllib.error.HTTPError as error:
        return error.code, None
    except (OSError, TimeoutError) as error:
        return None, str(error)


def main():
    serve_mock_backends()
    interval = max(0.05, float(os.environ.get("TRAFFIC_REQUEST_INTERVAL_SECONDS", "0.5")))
    max_requests = int(os.environ.get("TRAFFIC_MAX_REQUESTS", "0"))
    request_count = 0
    failures = 0
    node_cycle = itertools.cycle(range(1000000))
    while True:
        nodes, routes = load_manifest()
        if not nodes or not routes:
            time.sleep(1)
            continue
        index = next(node_cycle) % len(nodes)
        node = nodes[index]
        route = random.choice(routes)
        status, error = request(node, route)
        request_count += 1
        if error:
            failures += 1
        if request_count % 20 == 1:
            state = f"失败={failures}" if failures else "全部成功"
            print(f"持续演示请求：累计 {request_count} 次，最近 {node['name']} {route.get('method', 'GET')} {route.get('path', '/')} -> {status or error}；{state}", flush=True)
        if max_requests > 0 and request_count >= max_requests:
            return
        time.sleep(interval * random.uniform(0.8, 1.2))


if __name__ == "__main__":
    main()
