#!/usr/bin/env bash
# Real curl and loopback servers; no proxy account, public traffic or host writes.
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

unsupported_curl(){
  local banner
  curl(){
    printf '%s\n' "$*" >> "$CASE_TMP/curl-calls"
    if [ "$#" -eq 2 ] && [ "$1" = --disable ] && [ "$2" = --version ]; then
      printf '%s\n' "$CURL_TEST_BANNER"
    else
      : > "$CASE_TMP/unexpected-network"
      return 1
    fi
  }
  for banner in 'curl 7.88.1 test' 'curl 8.3.9 test' 'unrecognized version'; do
    CURL_TEST_BANNER="$banner"
    : > "$CASE_TMP/curl-calls"
    assert_bad "$banner cannot start a probe" _old_probe_to_file
    assert_ok "$banner explains its dependency" grep -q 'requires curl >= 8.4.0' "$CASE_TMP/probe.stderr"
    assert_eq "$banner only invokes an isolated version check" '--disable --version' "$(cat "$CASE_TMP/curl-calls")"
    assert_bad "$banner sends no network request" test -e "$CASE_TMP/unexpected-network"
  done
}
_old_probe_to_file(){ _proxy_probe_impl > "$CASE_TMP/probe.json" 2> "$CASE_TMP/probe.stderr"; }

completed_under_load(){
  PROXY_HOST=127.0.0.1; PROXY_TEST_URL=http://origin/bulk; PROXY_SMALL_URL=http://origin/small
  PROXY_REQUESTS=20; PROXY_MAX_BYTES=1000000; PROXY_SMALL_MAX_BYTES=4096
  curl(){
    if [ "${1:-}" = --disable ] && [ "${2:-}" = --version ]; then printf 'curl 8.4.0 test\n'; return; fi
    local arg is_bulk=0 count=0 i
    for arg in "$@"; do [ "$arg" != --range ] || is_bulk=1; done
    if [ "$is_bulk" -eq 1 ]; then
      for ((i=0;i<200;i++)); do
        [ ! -f "$CASE_TMP/last-request-started" ] || break
        sleep 0.01
      done
      printf '206 100000 1.0\n'
      : > "$CASE_TMP/bulk-finished"
    else
      [ ! -f "$CASE_TMP/small-count" ] || read -r count < "$CASE_TMP/small-count"
      count=$((count+1)); printf '%s\n' "$count" > "$CASE_TMP/small-count"
      if [ "$count" -eq 11 ]; then
        : > "$CASE_TMP/last-request-started"
        for ((i=0;i<200;i++)); do
          [ ! -f "$CASE_TMP/bulk-finished" ] || break
          sleep 0.01
        done
        sleep 0.05
      fi
      printf '200 1024 0.020\n'
    fi
  }
  assert_ok 'ten fully loaded samples produce a usable probe' _loaded_probe_to_file
  assert_json 'request completing after bulk is excluded from latency but still charged' "$CASE_TMP/probe.json" \
    '.requests==10 and .errors==0 and .p95_ms==20 and .bytes==111264'
  assert_eq 'the late request was actually performed' 11 "$(cat "$CASE_TMP/small-count")"
}
_loaded_probe_to_file(){ _proxy_probe_impl > "$CASE_TMP/probe.json"; }

real_proxy_path(){
  assert_ok 'real curl cannot bypass SOCKS through NO_PROXY or curlrc' python3 - "$REPO" "$CASE_TMP" <<'PY'
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import os
import re
import select
import shutil
import socket
import socketserver
import subprocess
import sys
import threading

repo, case = map(Path, sys.argv[1:])
hits = {"origin": 0, "socks": 0}
lock = threading.Lock()

class Origin(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        self.close_connection = True
        with lock:
            hits["origin"] += 1
        if self.path == "/chunked":
            self.send_response(200)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            try:
                # Deliberately ignore Range and omit Content-Length.
                for _ in range(64):
                    self.wfile.write(b"4000\r\n" + b"x" * 16384 + b"\r\n")
                    self.wfile.flush()
                self.wfile.write(b"0\r\n\r\n")
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        self.send_response(200)
        self.send_header("Content-Length", "1024")
        self.end_headers()
        self.wfile.write(b"x" * 1024)

    def log_message(self, *_):
        pass

class RefuseSocks(socketserver.BaseRequestHandler):
    def handle(self):
        with lock:
            hits["socks"] += 1
        self.request.recv(4096)

class ForwardSocks(socketserver.BaseRequestHandler):
    def exact(self, size):
        data = b""
        while len(data) < size:
            part = self.request.recv(size - len(data))
            if not part:
                raise OSError("incomplete SOCKS request")
            data += part
        return data

    def handle(self):
        self.request.settimeout(3)
        try:
            version, count = self.exact(2)
            assert version == 5 and 0 in self.exact(count)
            self.request.sendall(b"\x05\x00")
            version, command, _, kind = self.exact(4)
            assert version == 5 and command == 1
            if kind == 1:
                host = socket.inet_ntoa(self.exact(4))
            elif kind == 3:
                host = self.exact(self.exact(1)[0]).decode("ascii")
            else:
                raise OSError("only fixture-local IPv4 is supported")
            port = int.from_bytes(self.exact(2), "big")
            assert host == "127.0.0.1" and port == origin.server_port
            with socket.create_connection((host, port), timeout=3) as target:
                self.request.sendall(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00")
                while True:
                    readable, _, _ = select.select([self.request, target], [], [], 3)
                    if not readable:
                        return
                    for source in readable:
                        data = source.recv(65536)
                        if not data:
                            return
                        (target if source is self.request else self.request).sendall(data)
        except (AssertionError, OSError):
            pass

curl = shutil.which("curl")
bash = shutil.which("bash")
assert curl and bash, "real curl and bash are required"
version = subprocess.run([curl, "--disable", "--version"], capture_output=True, timeout=5)
match = re.match(rb"curl (\d+)\.(\d+)\.(\d+)", version.stdout)
assert version.returncode == 0 and match and tuple(map(int, match.groups())) >= (8, 4, 0), \
    "real proxy tests require curl >= 8.4.0"
origin = ThreadingHTTPServer(("127.0.0.1", 0), Origin)
socks = socketserver.ThreadingTCPServer(("127.0.0.1", 0), RefuseSocks)
socks.daemon_threads = True
forward = socketserver.ThreadingTCPServer(("127.0.0.1", 0), ForwardSocks)
forward.daemon_threads = True
threads = [threading.Thread(target=s.serve_forever, daemon=True) for s in (origin, socks, forward)]
for thread in threads:
    thread.start()
try:
    curl_home = case / "curl-home"
    curl_home.mkdir()
    trace = case / "curlrc.trace"
    for name in (".curlrc", "_curlrc"):
        (curl_home / name).write_text(f'trace-ascii = "{trace.as_posix()}"\n')
    env = os.environ.copy()
    env.update(NO_PROXY="*", no_proxy="*", CURL_HOME=str(curl_home),
               PROXY_HOST="127.0.0.1", PROXY_PORT=str(socks.server_address[1]),
               PROXY_TEST_URL=f"http://127.0.0.1:{origin.server_port}/bulk",
               PROXY_SMALL_URL=f"http://127.0.0.1:{origin.server_port}/small",
               PROXY_DURATION="2", PROXY_REQUESTS="20", PROXY_MAX_BYTES="1048576",
               PROXY_SMALL_MAX_BYTES="65536")
    control = subprocess.run(
        [curl, "--silent", "--max-time", "2", "--socks5-hostname",
         f"127.0.0.1:{socks.server_address[1]}", "--output", os.devnull,
         env["PROXY_TEST_URL"]], env=env, capture_output=True, timeout=5)
    assert control.returncode == 0 and hits["origin"] == 1 and hits["socks"] == 0, \
        "negative control must show NO_PROXY bypasses an explicit SOCKS option"
    assert trace.exists(), "negative control must load the injected curlrc"
    trace.unlink()
    with lock:
        hits["origin"] = 0
    result = subprocess.run(
        [bash, "-c", 'source "$1"; _proxy_probe_impl', "proxy-test", str(repo / "tcptune.sh")],
        env=env, capture_output=True, timeout=10)
    assert result.returncode != 0, "a refusing SOCKS endpoint cannot yield a valid probe"
    assert hits["socks"] > 0, "the probe must actually attempt its SOCKS endpoint"
    assert hits["origin"] == 0, "the probe must never reach the origin directly"
    assert not trace.exists(), "the probe must ignore user curlrc settings"
    bounded = subprocess.run(
        [curl, "--disable", "--silent", "--show-error", "--noproxy", "",
         "--socks5-hostname", f"127.0.0.1:{forward.server_address[1]}",
         "--max-time", "3", "--max-filesize", "65536", "--range", "0-65535",
         "--output", os.devnull, "--write-out", "%{size_download}",
         f"http://127.0.0.1:{origin.server_port}/chunked"],
        env=env, capture_output=True, timeout=5)
    assert bounded.returncode == 63, "unknown-length oversized response must hit curl's size limit"
    assert 0 < float(bounded.stdout) <= 65536, "received payload must remain within the declared limit"
    env.update(PROXY_PORT=str(forward.server_address[1]), PROXY_MAX_BYTES="65536",
               PROXY_TEST_URL=f"http://127.0.0.1:{origin.server_port}/chunked")
    rejected = subprocess.run(
        [bash, "-c", 'source "$1"; _proxy_probe_impl', "proxy-test", str(repo / "tcptune.sh")],
        env=env, capture_output=True, timeout=10)
    assert rejected.returncode != 0, "probe cannot accept an oversized chunked bulk response"
    print("Verified NO_PROXY negative control, SOCKS enforcement, curlrc isolation and bounded chunked rejection.")
finally:
    for server in (origin, socks, forward):
        server.shutdown()
        server.server_close()
    for thread in threads:
        thread.join(3)
PY
}

run_case unsupported-curl-refuses-network unsupported_curl
run_case loaded-sample-completion completed_under_load
run_case real-curl-proxy-path real_proxy_path
finish_suite
