#!/usr/bin/env python3
"""Run a fixed client probe through an authenticated loopback SSH reverse tunnel."""
import argparse
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import secrets
import subprocess
import threading


class ProbeHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        expected = "Bearer " + self.server.token
        if self.path != "/probe":
            self.send_error(404)
            return
        if not hmac.compare_digest(self.headers.get("Authorization", ""), expected):
            self.send_error(403)
            return
        if not self.server.probe_lock.acquire(blocking=False):
            self.send_error(409, "probe already running")
            return
        try:
            result = subprocess.run(
                self.server.probe_command,
                capture_output=True,
                timeout=self.server.probe_timeout,
                check=False,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
            if result.returncode != 0:
                raise ValueError("client probe failed")
            data = json.loads(result.stdout)
            if not isinstance(data, dict) or data.get("status") != "ok":
                raise ValueError("invalid probe result")
            body = json.dumps(data).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (subprocess.TimeoutExpired, ValueError, OSError):
            self.send_error(502, "client probe failed or timed out")
        finally:
            self.server.probe_lock.release()

    def log_message(self, fmt, *args):
        # Neither authorization headers nor probe stderr contain HTTP log fields.
        print(fmt % args, flush=True)


def make_server(port, token, command, timeout):
    server = ThreadingHTTPServer(("127.0.0.1", port), ProbeHandler)
    server.token = token
    server.probe_command = command
    server.probe_timeout = timeout
    server.probe_lock = threading.Lock()
    return server


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=19090)
    parser.add_argument("--token-file", type=Path, required=True)
    parser.add_argument("--bash", default="bash")
    parser.add_argument("--timeout", type=int, default=15)
    args = parser.parse_args()
    if not (1 <= args.port <= 65535 and 2 <= args.timeout <= 180):
        parser.error("port or timeout outside supported range")
    if not args.token_file.exists():
        descriptor = os.open(args.token_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as handle:
            handle.write(secrets.token_hex(32))
    token = args.token_file.read_text().strip()
    if len(token) < 32 or not token.isascii():
        parser.error("token must contain at least 32 ASCII characters")
    script = Path(__file__).resolve().with_name("client_probe.sh")
    server = make_server(args.port, token, [args.bash, str(script)], args.timeout)
    print(f"Client probe bridge: 127.0.0.1:{args.port}; token file: {args.token_file}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
