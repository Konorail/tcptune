import importlib.util
from pathlib import Path
import sys
import threading
import unittest
import urllib.error
import urllib.request

spec = importlib.util.spec_from_file_location(
    "probe_bridge", Path(__file__).resolve().parents[1] / "tools" / "probe_bridge.py"
)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class BridgeTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
