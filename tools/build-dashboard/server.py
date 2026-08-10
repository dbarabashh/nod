#!/usr/bin/env python3
"""Local build dashboard for Nod — serves index.html and streams command output.

Usage: python3 tools/build-dashboard/server.py [port]
Then open http://127.0.0.1:<port> in a browser. Binds to 127.0.0.1 only.
"""

import http.server
import json
import os
import re
import subprocess
import sys
from urllib.parse import urlsplit, parse_qs

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
DASHBOARD_DIR = os.path.dirname(os.path.abspath(__file__))

COMMANDS = {
    "generate": {
        "label": "xcodegen generate",
        "argv": ["xcodegen", "generate"],
    },
    "build": {
        "label": "Build (Debug — sandbox backend)",
        "argv": ["xcodebuild", "-project", "Nod.xcodeproj", "-scheme", "Nod", "build"],
    },
    "build-sandbox": {
        "label": "Build (Sandbox config)",
        "argv": [
            "xcodebuild", "-project", "Nod.xcodeproj", "-scheme", "Nod",
            "-configuration", "Sandbox", "build",
        ],
    },
    "build-release": {
        "label": "Build (Release — prod)",
        "argv": [
            "xcodebuild", "-project", "Nod.xcodeproj", "-scheme", "Nod",
            "-configuration", "Release", "build",
        ],
    },
    "test": {
        "label": "Run tests",
        "argv": [
            "xcodebuild", "-project", "Nod.xcodeproj", "-scheme", "Nod",
            "-destination", "platform=macOS", "test",
        ],
    },
    "clean": {
        "label": "Clean build folder",
        "argv": ["xcodebuild", "-project", "Nod.xcodeproj", "-scheme", "Nod", "clean"],
    },
    "fetch-vad": {
        "label": "Fetch VAD xcframework",
        "argv": ["./scripts/fetch-vad-xcframework.sh"],
    },
    "lint": {
        "label": "SwiftLint",
        "argv": ["swiftlint", "lint"],
    },
    "format-check": {
        "label": "SwiftFormat --lint",
        "argv": ["swiftformat", "--lint", "."],
    },
    "open-xcode": {
        "label": "Open in Xcode",
        "argv": ["open", "Nod.xcodeproj"],
    },
}

VERSION_RE = re.compile(r"^(patch|minor|major|\d+\.\d+\.\d+)$")
CHANNEL_RE = re.compile(r"^[A-Za-z0-9_-]{1,40}$")
EMAILS_RE = re.compile(r"^[A-Za-z0-9_.+-]+@[A-Za-z0-9-]+\.[A-Za-z0-9.-]+(,[A-Za-z0-9_.+-]+@[A-Za-z0-9-]+\.[A-Za-z0-9.-]+)*$")


def build_release_argv(params):
    version = params.get("version", [""])[0].strip()
    if not VERSION_RE.match(version):
        raise ValueError("version must be patch, minor, major, or x.y.z")

    argv = ["./scripts/release.sh", version]

    if params.get("sandbox", ["0"])[0] == "1":
        argv.append("--sandbox")

    channel = params.get("channel", [""])[0].strip()
    if channel:
        if not CHANNEL_RE.match(channel):
            raise ValueError("channel must be alphanumeric/-/_ only")
        argv += ["--channel", channel]

    feed = params.get("feed", [""])[0].strip()
    if feed:
        if not CHANNEL_RE.match(feed):
            raise ValueError("feed must be alphanumeric/-/_ only")
        argv += ["--feed", feed]

    to = params.get("to", [""])[0].strip()
    if to:
        if not EMAILS_RE.match(to):
            raise ValueError("to must be a comma-separated list of emails")
        argv += ["--to", to]

    if params.get("dryrun", ["1"])[0] == "1":
        argv.append("--dry-run")
    if params.get("skipnotarize", ["0"])[0] == "1":
        argv.append("--skip-notarize")
    if params.get("nopublish", ["0"])[0] == "1":
        argv.append("--no-publish")

    return argv


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        if self.path == "/" or self.path == "/index.html":
            self._serve_file("index.html", "text/html; charset=utf-8")
        elif self.path == "/api/commands":
            body = json.dumps(
                [{"id": k, "label": v["label"], "cmd": " ".join(v["argv"])} for k, v in COMMANDS.items()]
            ).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif self.path.startswith("/api/run?cmd="):
            cmd_id = self.path.split("=", 1)[1]
            spec = COMMANDS.get(cmd_id)
            if spec is None:
                self.send_error(404, "unknown command")
                return
            self._stream(spec["argv"])
        elif self.path.startswith("/api/release?") or self.path == "/api/release":
            params = parse_qs(urlsplit(self.path).query)
            try:
                argv = build_release_argv(params)
            except ValueError as e:
                self.send_error(400, str(e))
                return
            self._stream(argv)
        else:
            self.send_error(404)

    def _serve_file(self, name, content_type):
        path = os.path.join(DASHBOARD_DIR, name)
        with open(path, "rb") as f:
            body = f.read()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _stream(self, argv):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()

        def emit(event, data):
            for line in data.splitlines() or [""]:
                self.wfile.write(f"data: {line}\n".encode("utf-8"))
            self.wfile.write(f"event: {event}\n\n".encode("utf-8"))
            self.wfile.flush()

        emit("line", f"$ {' '.join(argv)}")
        try:
            proc = subprocess.Popen(
                argv,
                cwd=REPO_ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
            for line in proc.stdout:
                emit("line", line.rstrip("\n"))
            proc.wait()
            emit("done", str(proc.returncode))
        except FileNotFoundError as e:
            emit("line", f"error: {e}")
            emit("done", "127")
        except (BrokenPipeError, ConnectionResetError):
            pass


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8934
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"Nod build dashboard: http://127.0.0.1:{port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
