from __future__ import annotations

import http.client
import threading
import unittest
from functools import partial
from tempfile import TemporaryDirectory
from unittest.mock import patch
from urllib.parse import urlencode

import serve_safebox_web as web_server


class _FakeResponse:
    def __init__(self, status: int, body: bytes = b"", headers=()) -> None:
        self.status = status
        self.reason = "Test Response"
        self._body = body
        self._offset = 0
        self._headers = list(headers)

    def getheader(self, name: str):
        lowered = name.lower()
        for key, value in self._headers:
            if key.lower() == lowered:
                return value
        return None

    def getheaders(self):
        return list(self._headers)

    def read(self, amount: int | None = None) -> bytes:
        if amount is None:
            amount = len(self._body) - self._offset
        start = self._offset
        self._offset = min(len(self._body), self._offset + amount)
        return self._body[start : self._offset]

    def close(self) -> None:
        pass


class _FakeHttpsConnection:
    instances: list["_FakeHttpsConnection"] = []

    def __init__(self, host: str, port: int, **_) -> None:
        self.host = host
        self.port = port
        self.method = ""
        self.path = ""
        self.headers: list[tuple[str, str]] = []
        self.body = bytearray()
        self.instances.append(self)

    def putrequest(self, method: str, path: str, **_) -> None:
        self.method = method
        self.path = path

    def putheader(self, name: str, value: str) -> None:
        self.headers.append((name, value))

    def endheaders(self) -> None:
        pass

    def send(self, value: bytes) -> None:
        self.body.extend(value)

    def getresponse(self) -> _FakeResponse:
        if self.host == "api.github.com":
            return _FakeResponse(
                302,
                headers=(
                    (
                        "Location",
                        "https://release-assets.githubusercontent.com/file.sbox",
                    ),
                ),
            )
        return _FakeResponse(
            206,
            b"encrypted",
            headers=(
                ("Content-Type", "application/octet-stream"),
                ("Content-Length", "9"),
                ("Content-Range", "bytes 0-8/9"),
            ),
        )

    def close(self) -> None:
        pass


class SafeBoxWebServerTest(unittest.TestCase):
    def setUp(self) -> None:
        self._temporary = TemporaryDirectory()
        handler = partial(
            web_server.SafeBoxWebRequestHandler,
            directory=self._temporary.name,
            proxy_path=web_server.DEFAULT_PROXY_PATH,
        )
        self._server = web_server.SafeBoxThreadingHTTPServer(
            ("127.0.0.1", 0), handler
        )
        self._thread = threading.Thread(
            target=self._server.serve_forever, daemon=True
        )
        self._thread.start()

    def tearDown(self) -> None:
        self._server.shutdown()
        self._server.server_close()
        self._thread.join(timeout=5)
        self._temporary.cleanup()

    def _request(self, method: str, target: str, **kwargs):
        connection = http.client.HTTPConnection(
            "127.0.0.1", self._server.server_port, timeout=5
        )
        path = f"{web_server.DEFAULT_PROXY_PATH}?{urlencode({'url': target})}"
        connection.request(method, path, **kwargs)
        return connection, connection.getresponse()

    def test_redirect_is_followed_and_credentials_are_stripped(self) -> None:
        _FakeHttpsConnection.instances = []
        with patch.object(
            web_server.http.client,
            "HTTPSConnection",
            _FakeHttpsConnection,
        ):
            connection, response = self._request(
                "GET",
                "https://api.github.com/repos/a/b/releases/assets/1",
                headers={
                    "Authorization": "Bearer secret",
                    "Range": "bytes=0-8",
                },
            )
            try:
                self.assertEqual(response.status, 206)
                self.assertEqual(response.getheader("X-SafeBox-Proxy"), "1")
                self.assertEqual(response.getheader("Content-Range"), "bytes 0-8/9")
                self.assertEqual(response.read(), b"encrypted")
            finally:
                connection.close()

        self.assertEqual(
            [item.host for item in _FakeHttpsConnection.instances],
            ["api.github.com", "release-assets.githubusercontent.com"],
        )
        first_headers = {
            name.lower(): value
            for name, value in _FakeHttpsConnection.instances[0].headers
        }
        second_headers = {
            name.lower(): value
            for name, value in _FakeHttpsConnection.instances[1].headers
        }
        self.assertEqual(first_headers["authorization"], "Bearer secret")
        self.assertNotIn("authorization", second_headers)
        self.assertEqual(second_headers["range"], "bytes=0-8")

    def test_disallowed_target_is_rejected_without_upstream_request(self) -> None:
        _FakeHttpsConnection.instances = []
        with patch.object(
            web_server.http.client,
            "HTTPSConnection",
            _FakeHttpsConnection,
        ):
            connection, response = self._request(
                "GET", "https://127.0.0.1/private"
            )
            try:
                self.assertEqual(response.status, 403)
                self.assertEqual(response.getheader("X-SafeBox-Proxy"), "1")
                self.assertIn(b"allowed HTTPS endpoint", response.read())
            finally:
                connection.close()
        self.assertEqual(_FakeHttpsConnection.instances, [])

    def test_post_body_is_streamed_to_allowed_upload_host(self) -> None:
        _FakeHttpsConnection.instances = []
        with patch.object(
            web_server.http.client,
            "HTTPSConnection",
            _FakeHttpsConnection,
        ):
            connection, response = self._request(
                "POST",
                "https://uploads.github.com/repos/a/b/releases/1/assets?name=x.sbox",
                body=b"ciphertext",
                headers={"Content-Type": "application/octet-stream"},
            )
            try:
                self.assertEqual(response.status, 206)
                response.read()
            finally:
                connection.close()
        upstream = _FakeHttpsConnection.instances[0]
        self.assertEqual(upstream.method, "POST")
        self.assertEqual(upstream.body, b"ciphertext")


if __name__ == "__main__":
    unittest.main()
