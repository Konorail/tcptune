import importlib.util
from pathlib import Path
import threading
import unittest
import urllib.error
import urllib.request

spec = importlib.util.spec_from_file_location(
    "lab_origin", Path(__file__).resolve().parents[1] / "tools" / "lab_origin.py"
)
origin = importlib.util.module_from_spec(spec)
spec.loader.exec_module(origin)


class OriginTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = origin.ThreadingHTTPServer(("127.0.0.1", 0), origin.Origin)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}"
        # Do not send local test traffic through user-configured proxies.
        cls.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(3)

    def test_small(self):
        with self.opener.open(self.base + "/small", timeout=3) as response:
            self.assertEqual(response.status, 200)
            self.assertEqual(len(response.read()), 1024)

    def test_bounded_range(self):
        request = urllib.request.Request(self.base + "/bulk", headers={"Range": "bytes=17-1040"})
        with self.opener.open(request, timeout=3) as response:
            self.assertEqual(response.status, 206)
            self.assertEqual(response.headers["Content-Length"], "1024")
            self.assertEqual(response.read(), (origin.BLOCK + origin.BLOCK)[17:1041])

    def test_invalid_range(self):
        request = urllib.request.Request(self.base + "/bulk", headers={"Range": "bytes=42-17"})
        with self.assertRaises(urllib.error.HTTPError) as error:
            self.opener.open(request, timeout=3)
        self.assertEqual(error.exception.code, 416)

    def test_unknown_path(self):
        with self.assertRaises(urllib.error.HTTPError) as error:
            self.opener.open(self.base + "/no-file", timeout=3)
        self.assertEqual(error.exception.code, 404)


if __name__ == "__main__":
    unittest.main()
