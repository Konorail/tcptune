#!/usr/bin/env python3
"""Bounded, memory-only HTTP origin for the explicitly started TCP lab."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import re

BLOCK = bytes(range(256)) * 256


class Origin(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    bulk_bytes = 256 * 1024 * 1024

    def do_GET(self):
        if self.path == "/small":
            size = 1024
        elif self.path == "/bulk":
            size = self.bulk_bytes
        else:
            self.send_error(404)
            return
        start, end, code = 0, size - 1, 200
        if "Range" in self.headers:
            match = re.fullmatch(r"bytes=(\d+)-(\d*)", self.headers["Range"])
            if match is None:
                self.send_error(416)
                return
            start = int(match[1])
            end = min(int(match[2]) if match[2] else end, end)
            if start >= size or end < start:
                self.send_error(416)
                return
            code = 206
        self.send_response(code)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Accept-Ranges", "bytes")
        if code == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        remaining = end - start + 1
        try:
            while remaining:
                count = min(remaining, len(BLOCK))
                offset = start % len(BLOCK)
                data = (BLOCK + BLOCK)[offset:offset + count]
                self.wfile.write(data)
                remaining -= count
                start += count
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, fmt, *args):
        # Access logs keep the request path and status, never payload contents.
        print(f"{self.client_address[0]} {fmt % args}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--size-mib", type=int, default=256)
    args = parser.parse_args()
    if not (1 <= args.port <= 65535 and 1 <= args.size_mib <= 1024):
        parser.error("port or fixture size outside supported range")
    Origin.bulk_bytes = args.size_mib * 1024 * 1024
    print(f"lab origin http://{args.bind}:{args.port}/bulk and /small", flush=True)
    ThreadingHTTPServer((args.bind, args.port), Origin).serve_forever()


if __name__ == "__main__":
    main()
