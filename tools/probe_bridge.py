#!/usr/bin/env python3
"""Run a fixed client probe through an authenticated loopback SSH reverse tunnel."""
import argparse
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import secrets
import signal
import subprocess
import sys
import threading


class WindowsJob:
    """Own a Windows probe tree even after its immediate parent exits."""

    def __init__(self):
        import ctypes
        from ctypes import wintypes

        class BasicLimits(ctypes.Structure):
            _fields_ = [
                ("process_time", ctypes.c_longlong), ("job_time", ctypes.c_longlong),
                ("flags", wintypes.DWORD), ("min_working_set", ctypes.c_size_t),
                ("max_working_set", ctypes.c_size_t), ("active_processes", wintypes.DWORD),
                ("affinity", ctypes.c_size_t), ("priority", wintypes.DWORD),
                ("scheduling", wintypes.DWORD),
            ]

        class ExtendedLimits(ctypes.Structure):
            _fields_ = [
                ("basic", BasicLimits), ("io_counters", ctypes.c_ulonglong * 6),
                ("process_memory", ctypes.c_size_t), ("job_memory", ctypes.c_size_t),
                ("peak_process_memory", ctypes.c_size_t), ("peak_job_memory", ctypes.c_size_t),
            ]

        self.api = ctypes.WinDLL("kernel32", use_last_error=True)
        self.api.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
        self.api.CreateJobObjectW.restype = wintypes.HANDLE
        self.api.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
        self.api.SetInformationJobObject.restype = wintypes.BOOL
        self.api.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
        self.api.AssignProcessToJobObject.restype = wintypes.BOOL
        self.api.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        self.api.OpenProcess.restype = wintypes.HANDLE
        self.api.CloseHandle.argtypes = [wintypes.HANDLE]
        self.api.CloseHandle.restype = wintypes.BOOL
        self.handle = self.api.CreateJobObjectW(None, None)
        if not self.handle:
            raise ctypes.WinError(ctypes.get_last_error())
        limits = ExtendedLimits()
        limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not self.api.SetInformationJobObject(self.handle, 9, ctypes.byref(limits), ctypes.sizeof(limits)):
            error = ctypes.get_last_error()
            self.close()
            raise ctypes.WinError(error)

    def assign(self, pid):
        import ctypes
        # AssignProcessToJobObject requires PROCESS_SET_QUOTA | PROCESS_TERMINATE.
        process_handle = self.api.OpenProcess(0x0100 | 0x0001, False, pid)
        if not process_handle:
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            if not self.api.AssignProcessToJobObject(self.handle, process_handle):
                raise ctypes.WinError(ctypes.get_last_error())
        finally:
            self.api.CloseHandle(process_handle)

    def close(self):
        if self.handle:
            self.api.CloseHandle(self.handle)
            self.handle = None


class ActiveProbe:
    def __init__(self, process, job):
        self.process = process
        self.job = job
        self.done = threading.Event()
        self.lock = threading.Lock()
        self.cancelled = False

    def cancel(self):
        with self.lock:
            if self.cancelled:
                return
            self.cancelled = True
            if self.job is not None:
                self.job.close()
            else:
                try:
                    os.killpg(self.process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass


class ProbeRunner:
    def __init__(self):
        self.lock = threading.Lock()
        self.active = set()
        self.closed = False

    def run(self, command, timeout):
        # Registration and releasing the Windows launch gate are atomic with close.
        with self.lock:
            if self.closed:
                raise ValueError("probe bridge is closing")
            job = WindowsJob() if os.name == "nt" else None
            process = None
            try:
                if job is not None:
                    # No probe descendants can exist before AssignProcessToJobObject.
                    launcher = (
                        "import json,subprocess,sys; "
                        "gate=sys.stdin.buffer.read(1); "
                        "sys.exit(subprocess.call(json.loads(sys.argv[1]),stdin=subprocess.DEVNULL,"
                        "creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0)) if gate==b'1' else 125)"
                    )
                    process = subprocess.Popen(
                        [sys.executable, "-c", launcher, json.dumps(command)],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                        creationflags=subprocess.CREATE_NO_WINDOW,
                    )
                    job.assign(process.pid)
                    process.stdin.write(b"1")
                    process.stdin.close()
                    process.stdin = None
                else:
                    process = subprocess.Popen(
                        command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE, start_new_session=True,
                    )
            except BaseException:
                if job is not None:
                    job.close()
                if process is not None:
                    if process.poll() is None:
                        process.kill()
                    process.communicate(timeout=5)
                raise
            probe = ActiveProbe(process, job)
            self.active.add(probe)
        try:
            stdout, _ = process.communicate(timeout=timeout)
            if process.returncode != 0:
                raise ValueError("client probe failed")
            return stdout
        finally:
            # Close the entire tree even if the launcher exited before its children.
            probe.cancel()
            try:
                process.communicate(timeout=5)
            finally:
                with self.lock:
                    self.active.remove(probe)
                probe.done.set()

    def close(self):
        with self.lock:
            self.closed = True
            probes = list(self.active)
        for probe in probes:
            probe.cancel()
        for probe in probes:
            if not probe.done.wait(5):
                raise TimeoutError("probe cleanup did not finish")


def run_probe(command, timeout):
    runner = ProbeRunner()
    try:
        return runner.run(command, timeout)
    finally:
        runner.close()


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
            data = json.loads(self.server.probe_runner.run(self.server.probe_command, self.server.probe_timeout))
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


class ProbeServer(ThreadingHTTPServer):
    def __init__(self, *args, **kwargs):
        self.probe_runner = ProbeRunner()
        super().__init__(*args, **kwargs)

    def server_close(self):
        try:
            self.probe_runner.close()
        finally:
            super().server_close()
        # ProbeRunner finishes before the handler sends its final HTTP response.
        # Daemon request threads are not joined by ThreadingHTTPServer, so also
        # wait until the handler's finally block has released the probe lock.
        lock = getattr(self, "probe_lock", None)
        if lock is not None:
            if not lock.acquire(timeout=5):
                raise TimeoutError("probe handler cleanup did not finish")
            lock.release()


def make_server(port, token, command, timeout):
    server = ProbeServer(("127.0.0.1", port), ProbeHandler)
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
