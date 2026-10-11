#!/usr/bin/env python3
"""Generate local demo HTTP traffic across the three OpenResty nodes."""

import itertools
import os
import random
import time
import urllib.error
import urllib.request


NODES = (
    ("openresty-east-1", "http://127.0.0.1:18080"),
    ("openresty-east-2", "http://127.0.0.1:18180"),
    ("openresty-east-3", "http://127.0.0.1:18280"),
)
PATHS = (
    "/",
    "/index.html",
    "/api/v1/products",
    "/api/v1/orders?limit=20",
    "/assets/app.js",
    "/health",
    "/runtime/status",
)
USER_AGENTS = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/129.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 Version/17.0 Safari/605.1.15",
    "curl/8.10.1",
)


def request(node_name: str, base_url: str) -> None:
    path = random.choice(PATHS)
    url = f"{base_url}{path}"
    req = urllib.request.Request(
        url,
        headers={"User-Agent": random.choice(USER_AGENTS), "Accept": "text/html,application/json,*/*"},
    )
    timeout = float(os.environ.get("TRAFFIC_REQUEST_TIMEOUT_SECONDS", "3"))
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            print(f"{node_name} {response.status} {path}", flush=True)
    except urllib.error.HTTPError as error:
        # 404s on sample application paths are intentional and useful for demo logs.
        print(f"{node_name} {error.code} {path}", flush=True)
    except (OSError, TimeoutError) as error:
        print(f"{node_name} request failed: {error}", flush=True)


def main() -> None:
    interval = max(0.05, float(os.environ.get("TRAFFIC_REQUEST_INTERVAL_SECONDS", "0.5")))
    max_requests = int(os.environ.get("TRAFFIC_MAX_REQUESTS", "0"))
    nodes = itertools.cycle(NODES)
    request_count = 0
    while True:
        node_name, base_url = next(nodes)
        request(node_name, base_url)
        request_count += 1
        if max_requests > 0 and request_count >= max_requests:
            return
        time.sleep(interval * random.uniform(0.8, 1.2))


if __name__ == "__main__":
    main()
