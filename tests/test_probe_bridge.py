import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from unittest import mock

spec = importlib.util.spec_from_file_location(
    "probe_bridge", Path(__file__).resolve().parents[1] / "tools" / "probe_bridge.py"
)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class BridgeTests(unittest.TestCase):
    def assert_process_stopped(self, pid):
        if os.name == "nt":
            import ctypes
            from ctypes import wintypes
            api = ctypes.WinDLL("kernel32", use_last_error=True)
            api.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
            api.OpenProcess.restype = wintypes.HANDLE
            api.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
            api.WaitForSingleObject.restype = wintypes.DWORD
            api.CloseHandle.argtypes = [wintypes.HANDLE]
            handle = api.OpenProcess(0x00100000, False, pid)
            if handle:
                try:
                    self.assertEqual(api.WaitForSingleObject(handle, 1000), 0)
                finally:
                    api.CloseHandle(handle)
        else:
            # A killed child may briefly remain as a zombie until init reaps it.
            # SIGKILL is asynchronous: the child may not have been scheduled yet
            # when its parent has already exited and closed the captured pipes.
            status = Path(f"/proc/{pid}/stat")
            deadline = time.monotonic() + 1
            while True:
                try:
                    state = status.read_text().rsplit(")", 1)[1].split()[0]
                except FileNotFoundError:
                    return
                if state == "Z":
                    return
                if time.monotonic() >= deadline:
                    self.fail(f"probe descendant {pid} remains in state {state} after cleanup")
                time.sleep(0.01)

    @classmethod
    def setUpClass(cls):
        cls.server = bridge.make_server(
            0, "a" * 64, [sys.executable, "-c", 'print(\'{"status":"ok"}\')'], 3
        )
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.url = f"http://127.0.0.1:{cls.server.server_port}/probe"
        cls.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(3)

    def test_rejects_missing_authorization(self):
        request = urllib.request.Request(self.url, data=b"", method="POST")
        with self.assertRaises(urllib.error.HTTPError) as error:
            self.opener.open(request, timeout=5)
        self.assertEqual(error.exception.code, 403)

    def test_fixed_authorized_probe(self):
        request = urllib.request.Request(
            self.url, data=b"", method="POST", headers={"Authorization": "Bearer " + "a" * 64}
        )
        with self.opener.open(request, timeout=5) as response:
            self.assertEqual(response.status, 200)
            self.assertIn(b'"status": "ok"', response.read())

    def test_rejects_concurrent_probe(self):
        self.server.probe_lock.acquire()
        try:
            request = urllib.request.Request(
                self.url, data=b"", method="POST", headers={"Authorization": "Bearer " + "a" * 64}
            )
            with self.assertRaises(urllib.error.HTTPError) as error:
                self.opener.open(request, timeout=5)
            self.assertEqual(error.exception.code, 409)
        finally:
            self.server.probe_lock.release()

    def test_nonzero_probe_is_rejected(self):
        with self.assertRaises(ValueError):
            bridge.run_probe([sys.executable, "-c", "raise SystemExit(1)"], 3)

    def test_timeout_terminates_descendants(self):
        with tempfile.TemporaryDirectory() as directory:
            pid_file = Path(directory) / "child.pid"
            child = (
                "import os,time; from pathlib import Path; "
                f"Path({str(pid_file)!r}).write_text(str(os.getpid())); time.sleep(60)"
            )
            parent = (
                "import subprocess,sys,time; "
                f"subprocess.Popen([sys.executable,'-c',{child!r}]); time.sleep(60)"
            )
            started = time.monotonic()
            with self.assertRaises(bridge.subprocess.TimeoutExpired):
                bridge.run_probe([sys.executable, "-c", parent], 2)
            self.assertLess(time.monotonic() - started, 8)
            self.assertTrue(pid_file.exists(), "the descendant must actually have started")
            pid = int(pid_file.read_text())
            self.assert_process_stopped(pid)

    def test_timeout_terminates_children_after_parent_exits(self):
        with tempfile.TemporaryDirectory() as directory:
            pid_file = Path(directory) / "child.pid"
            child = (
                "import os,time; from pathlib import Path; "
                f"Path({str(pid_file)!r}).write_text(str(os.getpid())); time.sleep(60)"
            )
            parent = f"import subprocess,sys; subprocess.Popen([sys.executable,'-c',{child!r}])"
            started = time.monotonic()
            with self.assertRaises(bridge.subprocess.TimeoutExpired):
                bridge.run_probe([sys.executable, "-c", parent], 2)
            self.assertLess(time.monotonic() - started, 6)
            self.assertTrue(pid_file.exists())
            self.assert_process_stopped(int(pid_file.read_text()))

    @unittest.skipUnless(os.name == "nt", "Windows Job assignment failure")
    def test_windows_job_failure_does_not_start_probe(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "probe-started"
            command = [sys.executable, "-c", f"from pathlib import Path; Path({str(marker)!r}).touch()"]
            with mock.patch.object(bridge.WindowsJob, "assign", side_effect=OSError("assignment denied")):
                with self.assertRaises(OSError):
                    bridge.run_probe(command, 2)
            self.assertFalse(marker.exists(), "failed containment must never start the actual probe")

    def test_closing_bridge_cancels_active_probe_tree(self):
        with tempfile.TemporaryDirectory() as directory:
            pid_file = Path(directory) / "child.pid"
            child = (
                "import os,time; from pathlib import Path; "
                f"Path({str(pid_file)!r}).write_text(str(os.getpid())); time.sleep(60)"
            )
            parent = f"import subprocess,sys,time; subprocess.Popen([sys.executable,'-c',{child!r}]); time.sleep(60)"
            server = bridge.make_server(0, "b" * 64, [sys.executable, "-c", parent], 60)
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            errors = []

            def request_probe():
                request = urllib.request.Request(
                    f"http://127.0.0.1:{server.server_port}/probe", data=b"", method="POST",
                    headers={"Authorization": "Bearer " + "b" * 64},
                )
                try:
                    self.opener.open(request, timeout=10).close()
                    errors.append("cancelled probe unexpectedly succeeded")
                except urllib.error.HTTPError as error:
                    if error.code != 502:
                        errors.append(f"unexpected status {error.code}")
                except Exception as error:
                    errors.append(str(error))

            client = threading.Thread(target=request_probe, daemon=True)
            client.start()
            try:
                deadline = time.monotonic() + 5
                while not pid_file.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(pid_file.exists(), "probe must start before closing the bridge")
                self.assertTrue(server.probe_lock.locked())
                server.shutdown()
                server.server_close()
                client.join(5)
                self.assertFalse(client.is_alive())
                self.assertEqual(errors, [])
                self.assertFalse(server.probe_lock.locked())
                self.assert_process_stopped(int(pid_file.read_text()))
            finally:
                server.shutdown()
                server.server_close()
                worker.join(3)
                client.join(3)

    def test_timeout_releases_bridge_lock(self):
        command = self.server.probe_command
        timeout = self.server.probe_timeout
        self.server.probe_command = [sys.executable, "-c", "import time; time.sleep(60)"]
        self.server.probe_timeout = 0.1
        request = urllib.request.Request(
            self.url, data=b"", method="POST", headers={"Authorization": "Bearer " + "a" * 64}
        )
        try:
            with self.assertRaises(urllib.error.HTTPError) as error:
                self.opener.open(request, timeout=8)
            self.assertEqual(error.exception.code, 502)
            self.assertTrue(self.server.probe_lock.acquire(timeout=1))
            self.server.probe_lock.release()
        finally:
            self.server.probe_command = command
            self.server.probe_timeout = timeout


if __name__ == "__main__":
    unittest.main()
