#!/usr/bin/env python3
"""Register the three running Compose demo nodes in the numeric Go API."""

import argparse
import json
import os
import pathlib
import subprocess
import sys
import urllib.error
import urllib.request


PROJECT_ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKSPACE_ROOT = PROJECT_ROOT.parent
BASE = "http://127.0.0.1:8081/api"
NODES = (
    ("openresty-east-1", 18081, 10),
    ("openresty-east-2", 18181, 1),
    ("openresty-east-3", 18281, 5),
)


def request(path, token=None, data=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    payload = None if data is None else json.dumps(data).encode()
    req = urllib.request.Request(BASE + path, payload, headers, method="POST" if data is not None else "GET")
    with urllib.request.urlopen(req, timeout=5) as response:
        result = json.load(response)
    if result.get("code") not in (None, 0):
        raise RuntimeError(result.get("message", "接口请求失败"))
    return result.get("data")


def main():
    parser = argparse.ArgumentParser(description="登记本地三个 OpenResty Compose 节点")
    parser.add_argument("--center-id", type=int, help="目标 Center 的数字 ID；只有一个 Center 时可省略")
    args = parser.parse_args()
    for name, _, _ in NODES:
        container = "orp-" + name
        result = subprocess.run(
            ["docker", "inspect", "--format", '{{.State.Status}} {{index .Config.Labels "com.docker.compose.project"}} {{index .Config.Labels "com.docker.compose.service"}}', container],
            capture_output=True, text=True, check=False,
        )
        if result.returncode or result.stdout.strip() != f"running orp {name}":
            raise RuntimeError(f"容器 {container} 未运行或 Compose 身份不符")

    password = os.environ.get("ORP_ADMIN_PASSWORD")
    password_file = WORKSPACE_ROOT / "runtime/dev/admin-password"
    if not password and password_file.exists():
        password = password_file.read_text().strip()
    for env_file in (PROJECT_ROOT / ".env", WORKSPACE_ROOT / ".env"):
        if password or not env_file.exists():
            continue
        for line in env_file.read_text().splitlines():
            if line.startswith("ORP_ADMIN_PASSWORD="):
                password = line.split("=", 1)[1].strip().strip("\"'")
                break
    if not password:
        raise RuntimeError("找不到本地管理员密码；请设置 ORP_ADMIN_PASSWORD")
    login = {"username": os.environ.get("ORP_ADMIN_USERNAME", "admin"), "password": password}
    if os.environ.get("ORP_ADMIN_OTP_CODE"):
        login["otpCode"] = os.environ["ORP_ADMIN_OTP_CODE"]
    token = request("/auth/login", data=login)["accessToken"]
    centers = request("/orp/centers?page=1&pageSize=200", token)["items"]
    if args.center_id is None:
        if len(centers) != 1:
            raise RuntimeError("请通过 --center-id 指定目标 Center；当前 Center 数量不是 1")
        center_id = centers[0]["id"]
    else:
        center_id = args.center_id
        if not any(center["id"] == center_id for center in centers):
            raise RuntimeError("指定的 Center 不存在")
    existing = request("/orp/nodes?page=1&pageSize=200", token)["items"]
    for name, port, weight in NODES:
        endpoint = f"http://127.0.0.1:{port}"
        matched = [node for node in existing if node["name"] == name]
        if matched:
            node = matched[0]
            if node["centerId"] != center_id or node["host"] != "127.0.0.1" or node.get("controlEndpoint") != endpoint:
                raise RuntimeError(f"节点 {name} 已存在，但中心或连接信息不匹配")
            print(f"已存在：{name} (ID {node['id']})")
            continue
        node = request("/orp/nodes", token, {"centerId": center_id, "name": name, "host": "127.0.0.1", "controlEndpoint": endpoint, "status": "running", "weight": weight})
        print(f"已登记：{name} (ID {node['id']})")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, urllib.error.URLError, KeyError, ValueError) as exc:
        print(f"登记失败：{exc}", file=sys.stderr)
        sys.exit(1)
