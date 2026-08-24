"""Serve an exported SafeBox Web build with a restricted cloud proxy.

Browsers cannot read GitHub Release and Gitee attachment redirects directly
because the final download hosts do not provide CORS access. This server keeps
the browser request same-origin and forwards only the small, explicit set of
hosts used by SafeBox's GitHub/Gitee integrations. It is not an open proxy.

Build first, then run:

    python export_safebox_web.py --no-pub
    python serve_safebox_web.py
"""

from __future__ import annotations

import argparse
import http.client
import json
import ssl
import sys
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urljoin, urlsplit, urlunsplit

from run_safebox import PROJECT_ROOT


DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8080
DEFAULT_PROXY_PATH = "/_safebox/proxy"
MAXIMUM_REQUEST_BODY_BYTES = 128 * 1024 * 1024
MAXIMUM_TARGET_URL_CHARACTERS = 16 * 1024
MAXIMUM_REDIRECTS = 5
UPSTREAM_TIMEOUT_SECONDS = 60

ALLOWED_TARGET_HOSTS = frozenset(
    {
        "api.github.com",
        "github.com",
        "objects.githubusercontent.com",
        "raw.githubusercontent.com",
        "release-assets.githubusercontent.com",
        "uploads.github.com",
        "foruda.gitee.com",
        "gitee.com",
    }
)

FORWARDED_REQUEST_HEADERS = frozenset(
    {
        "accept",
        "authorization",
        "content-type",
        "if-match",
        "if-none-match",
        "range",
        "x-github-api-version",
    }
)

FORWARDED_RESPONSE_HEADERS = frozenset(
    {
        "accept-ranges",
        "content-length",
        "content-range",
        "content-type",
        "etag",
        "last-modified",
        "link",
        "location",
        "retry-after",
        "x-ratelimit-limit",
        "x-ratelimit-remaining",
        "x-ratelimit-reset",
        "x-ratelimit-resource",
        "x-rate-limit-limit",
        "x-rate-limit-remaining",
        "x-rate-limit-reset",
    }
)

REDIRECT_STATUSES = frozenset({301, 302, 303, 307, 308})


class ProxyRequestError(ValueError):
    """A proxy request was malformed or targeted a disallowed endpoint."""


def _proxy_path(value: str) -> str:
    if (
        not value.startswith("/")
        or value == "/"
        or value.endswith("/")
        or "?" in value
        or "#" in value
        or "\\" in value
    ):
        raise argparse.ArgumentTypeError(
            "must be an absolute URL path without a trailing slash"
        )
    return value


def _validated_target(value: str):
    if not value or len(value) > MAXIMUM_TARGET_URL_CHARACTERS:
        raise ProxyRequestError("target URL is missing or too long")
    if any(ord(character) < 0x20 for character in value):
        raise ProxyRequestError("target URL contains a control character")
    target = urlsplit(value)
    try:
        port = target.port
    except ValueError as error:
        raise ProxyRequestError("target URL has an invalid port") from error
    host = (target.hostname or "").lower()
    if (
        target.scheme.lower() != "https"
        or host not in ALLOWED_TARGET_HOSTS
        or target.username is not None
        or target.password is not None
        or target.fragment
        or port not in (None, 443)
    ):
        raise ProxyRequestError("target URL is not an allowed HTTPS endpoint")
    return target


def _same_origin(left, right) -> bool:
    return (
        left.scheme.lower() == right.scheme.lower()
        and (left.hostname or "").lower() == (right.hostname or "").lower()
        and (left.port or 443) == (right.port or 443)
    )


class SafeBoxWebRequestHandler(SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def __init__(
        self,
        *args,
        directory: str,
        proxy_path: str = DEFAULT_PROXY_PATH,
        **kwargs,
    ) -> None:
        self.proxy_path = proxy_path
        self._proxy_log_target: str | None = None
        super().__init__(*args, directory=directory, **kwargs)

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if self._is_proxy_request():
            self._serve_proxy()
        else:
            super().do_GET()

    def do_HEAD(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if self._is_proxy_request():
            self._serve_proxy()
        else:
            super().do_HEAD()

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        self._proxy_or_method_not_allowed()

    def do_PUT(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        self._proxy_or_method_not_allowed()

    def do_PATCH(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        self._proxy_or_method_not_allowed()

    def do_DELETE(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        self._proxy_or_method_not_allowed()

    def _proxy_or_method_not_allowed(self) -> None:
        if self._is_proxy_request():
            self._serve_proxy()
        else:
            self.send_error(405, "Method Not Allowed")

    def _is_proxy_request(self) -> bool:
        return urlsplit(self.path).path == self.proxy_path

    def _target_from_request(self):
        parsed = urlsplit(self.path)
        try:
            parameters = parse_qs(
                parsed.query,
                keep_blank_values=True,
                strict_parsing=True,
                max_num_fields=2,
            )
        except ValueError as error:
            raise ProxyRequestError("invalid proxy query") from error
        if set(parameters) != {"url"} or len(parameters["url"]) != 1:
            raise ProxyRequestError("proxy query must contain exactly one URL")
        return _validated_target(parameters["url"][0])

    def _request_content_length(self) -> int:
        if self.headers.get("Transfer-Encoding") is not None:
            raise ProxyRequestError("chunked request bodies are not accepted")
        raw = self.headers.get("Content-Length")
        if raw is None:
            return 0
        try:
            length = int(raw)
        except ValueError as error:
            raise ProxyRequestError("invalid request content length") from error
        if length < 0 or length > MAXIMUM_REQUEST_BODY_BYTES:
            raise ProxyRequestError("request body exceeds the proxy limit")
        return length

    def _forwarded_headers(self) -> dict[str, str]:
        result: dict[str, str] = {}
        for name, value in self.headers.items():
            lowered = name.lower()
            if lowered in FORWARDED_REQUEST_HEADERS:
                result[name] = value
        result["User-Agent"] = "SafeBox-Web-Proxy/1.0"
        result["Accept-Encoding"] = "identity"
        return result

    def _serve_proxy(self) -> None:
        connection: http.client.HTTPSConnection | None = None
        response: http.client.HTTPResponse | None = None
        try:
            target = self._target_from_request()
            self._proxy_log_target = target.hostname
            content_length = self._request_content_length()
            if self.command in {"GET", "HEAD"} and content_length != 0:
                raise ProxyRequestError("read requests cannot contain a body")
            headers = self._forwarded_headers()
            current = target
            for redirects in range(MAXIMUM_REDIRECTS + 1):
                connection, response = self._open_upstream(
                    current,
                    headers=headers,
                    content_length=content_length,
                )
                if (
                    self.command not in {"GET", "HEAD"}
                    or response.status not in REDIRECT_STATUSES
                ):
                    break
                location = response.getheader("Location")
                response.read()
                connection.close()
                connection = None
                response = None
                if location is None or redirects >= MAXIMUM_REDIRECTS:
                    raise ProxyRequestError("upstream redirect is invalid")
                next_target = _validated_target(
                    urljoin(urlunsplit(current), location)
                )
                if not _same_origin(current, next_target):
                    headers = {
                        name: value
                        for name, value in headers.items()
                        if name.lower() not in {"authorization", "cookie"}
                    }
                current = next_target

            if response is None:
                raise ProxyRequestError("upstream response is missing")
            self._send_upstream_response(response)
        except ProxyRequestError as error:
            self._send_proxy_error(403, str(error))
        except (OSError, ssl.SSLError, http.client.HTTPException) as error:
            self.log_error(
                "SafeBox proxy upstream failure for %s: %s",
                self._proxy_log_target or "unknown host",
                type(error).__name__,
            )
            self._send_proxy_error(502, "cloud provider request failed")
        finally:
            if response is not None:
                response.close()
            if connection is not None:
                connection.close()

    def _open_upstream(
        self,
        target,
        *,
        headers: dict[str, str],
        content_length: int,
    ) -> tuple[http.client.HTTPSConnection, http.client.HTTPResponse]:
        host = target.hostname or ""
        connection = http.client.HTTPSConnection(
            host,
            target.port or 443,
            timeout=UPSTREAM_TIMEOUT_SECONDS,
            context=ssl.create_default_context(),
        )
        path = urlunsplit(("", "", target.path or "/", target.query, ""))
        connection.putrequest(
            self.command,
            path,
            skip_host=True,
            skip_accept_encoding=True,
        )
        connection.putheader("Host", host)
        for name, value in headers.items():
            connection.putheader(name, value)
        if content_length > 0:
            connection.putheader("Content-Length", str(content_length))
        connection.endheaders()

        remaining = content_length
        while remaining > 0:
            chunk = self.rfile.read(min(64 * 1024, remaining))
            if not chunk:
                connection.close()
                raise ProxyRequestError("request body ended unexpectedly")
            connection.send(chunk)
            remaining -= len(chunk)
        return connection, connection.getresponse()

    def _send_upstream_response(self, response: http.client.HTTPResponse) -> None:
        self.send_response(response.status, response.reason)
        self.send_header("X-SafeBox-Proxy", "1")
        for name, value in response.getheaders():
            if name.lower() in FORWARDED_RESPONSE_HEADERS:
                self.send_header(name, value)
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        if self.command == "HEAD":
            return
        try:
            while True:
                chunk = response.read(64 * 1024)
                if not chunk:
                    break
                self.wfile.write(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _send_proxy_error(self, status: int, message: str) -> None:
        if self.wfile.closed:
            return
        payload = json.dumps(
            {"error": message}, ensure_ascii=False, separators=(",", ":")
        ).encode("utf-8")
        self.send_response(status)
        self.send_header("X-SafeBox-Proxy", "1")
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        if self.command != "HEAD":
            self.wfile.write(payload)

    def log_request(self, code="-", size="-") -> None:
        if self._proxy_log_target is None:
            super().log_request(code, size)
            return
        self.log_message(
            '"%s %s" %s %s',
            self.command,
            self._proxy_log_target,
            str(code),
            str(size),
        )


class SafeBoxThreadingHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Serve SafeBox Web with its restricted GitHub/Gitee proxy."
    )
    parser.add_argument(
        "--directory",
        type=Path,
        default=Path("build/web"),
        help="exported Web directory (default: build/web)",
    )
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument(
        "--proxy-path",
        type=_proxy_path,
        default=DEFAULT_PROXY_PATH,
        help=f"same-origin proxy path (default: {DEFAULT_PROXY_PATH})",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _parser()
    args = parser.parse_args(argv)
    if not 1 <= args.port <= 65535:
        parser.error("--port must be between 1 and 65535")
    directory = args.directory.expanduser()
    if not directory.is_absolute():
        directory = PROJECT_ROOT / directory
    directory = directory.resolve()
    required = (directory / "index.html", directory / "main.dart.js")
    if not all(path.is_file() for path in required):
        print(
            f"SafeBox Web export not found in {directory}. "
            "Run export_safebox_web.py first.",
            file=sys.stderr,
        )
        return 1

    handler = partial(
        SafeBoxWebRequestHandler,
        directory=str(directory),
        proxy_path=args.proxy_path,
    )
    try:
        server = SafeBoxThreadingHTTPServer((args.host, args.port), handler)
    except OSError as error:
        print(f"Unable to start SafeBox Web server: {error}", file=sys.stderr)
        return 1

    print(f"Serving SafeBox Web from {directory}")
    print(f"Open http://{args.host}:{args.port}")
    print(f"Cloud proxy: {args.proxy_path} (GitHub/Gitee allowlist only)")
    print("Press Ctrl+C to stop.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
