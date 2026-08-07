#!/usr/bin/env python3
"""Run Playwright through an npmmirror-compatible redirect endpoint."""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def mirror_url(mirror_base: str, request_path: str) -> str:
    path = request_path.split("?", 1)[0]
    if path.startswith("/builds/cft/"):
        suffix = path.removeprefix("/builds/cft/")
        return f"{mirror_base.rstrip('/')}/chrome-for-testing/{suffix}"
    if re.match(r"^/\d+(?:\.\d+){3}/", path):
        return f"{mirror_base.rstrip('/')}/chrome-for-testing{path}"
    return f"{mirror_base.rstrip('/')}/playwright{path}"


def run(command: list[str], mirror_base: str) -> int:
    class RedirectHandler(BaseHTTPRequestHandler):
        def redirect(self) -> None:
            target = mirror_url(mirror_base, self.path)
            self.send_response(302)
            self.send_header("Location", target)
            self.end_headers()

        do_GET = redirect
        do_HEAD = redirect

        def log_message(self, format: str, *args: object) -> None:
            print(f"[NAG] Playwright mirror: {format % args}", file=sys.stderr)

    server = ThreadingHTTPServer(("127.0.0.1", 0), RedirectHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    mirror_environment = os.environ.copy()
    for name in (
        "PLAYWRIGHT_CHROMIUM_DOWNLOAD_HOST",
        "PLAYWRIGHT_FIREFOX_DOWNLOAD_HOST",
        "PLAYWRIGHT_WEBKIT_DOWNLOAD_HOST",
    ):
        mirror_environment.pop(name, None)
    mirror_environment["PLAYWRIGHT_DOWNLOAD_HOST"] = (
        f"http://127.0.0.1:{server.server_port}"
    )
    try:
        result = subprocess.run(command, env=mirror_environment, check=False)
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
    if result.returncode == 0:
        return 0

    print(
        "[NAG] Playwright 国内镜像失败，改用官方源重试",
        file=sys.stderr,
    )
    official_environment = os.environ.copy()
    for name in (
        "PLAYWRIGHT_DOWNLOAD_HOST",
        "PLAYWRIGHT_CHROMIUM_DOWNLOAD_HOST",
        "PLAYWRIGHT_FIREFOX_DOWNLOAD_HOST",
        "PLAYWRIGHT_WEBKIT_DOWNLOAD_HOST",
    ):
        official_environment.pop(name, None)
    return subprocess.run(command, env=official_environment, check=False).returncode


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mirror-base", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        parser.error("a command is required after --")
    return run(command, args.mirror_base)


if __name__ == "__main__":
    raise SystemExit(main())
