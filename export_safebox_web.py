"""Build SafeBox as a deployable Flutter Web directory.

Examples:
    python export_safebox_web.py
    python export_safebox_web.py --serve
    python export_safebox_web.py --base-href /safebox/ --output build/web
    python export_safebox_web.py --max-file-mib 192 --skip-checks
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

from run_safebox import PROJECT_ROOT, find_flutter


DEFAULT_MAX_FILE_MIB = 128
MAX_CONFIGURABLE_FILE_MIB = 512
DEFAULT_PROXY_PATH = "/_safebox/proxy"
REQUIRED_WEB_FILES = (
    "index.html",
    "flutter_bootstrap.js",
    "main.dart.js",
    "canvaskit/canvaskit.js",
    "canvaskit/canvaskit.wasm",
    "canvaskit/chromium/canvaskit.js",
    "canvaskit/chromium/canvaskit.wasm",
)


def _file_size_mib(value: str) -> int:
    try:
        result = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be an integer") from error
    if not 1 <= result <= MAX_CONFIGURABLE_FILE_MIB:
        raise argparse.ArgumentTypeError(
            f"must be between 1 and {MAX_CONFIGURABLE_FILE_MIB} MiB"
        )
    return result


def _base_href(value: str) -> str:
    if not value.startswith("/") or not value.endswith("/"):
        raise argparse.ArgumentTypeError("must start and end with '/', for example /safebox/")
    if "?" in value or "#" in value or "\\" in value:
        raise argparse.ArgumentTypeError("must be a URL path without a query or fragment")
    return value


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


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Analyze, test, and export SafeBox as Flutter Web static files."
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("build/web"),
        help="output directory, relative to the project root by default (default: build/web)",
    )
    parser.add_argument(
        "--base-href",
        type=_base_href,
        default="/",
        help="deployment URL prefix; it must start and end with '/' (default: /)",
    )
    parser.add_argument(
        "--max-file-mib",
        type=_file_size_mib,
        default=DEFAULT_MAX_FILE_MIB,
        help=(
            "browser in-memory upload/download limit in MiB "
            f"(default: {DEFAULT_MAX_FILE_MIB}, maximum: {MAX_CONFIGURABLE_FILE_MIB})"
        ),
    )
    parser.add_argument(
        "--debug",
        action="store_true",
        help="produce a debug Web build instead of the optimized release build",
    )
    parser.add_argument(
        "--source-maps",
        action="store_true",
        help="include JavaScript source maps in the exported directory",
    )
    parser.add_argument(
        "--skip-checks",
        action="store_true",
        help="skip flutter analyze and flutter test before building",
    )
    parser.add_argument(
        "--no-pub",
        action="store_true",
        help="skip flutter pub get (requires an up-to-date .dart_tool directory)",
    )
    parser.add_argument(
        "--proxy-path",
        type=_proxy_path,
        default=DEFAULT_PROXY_PATH,
        help=f"same-origin cloud proxy path (default: {DEFAULT_PROXY_PATH})",
    )
    parser.add_argument(
        "--serve",
        action="store_true",
        help="serve the completed export with the restricted cloud proxy",
    )
    parser.add_argument(
        "--host",
        default="127.0.0.1",
        help="host used with --serve (default: 127.0.0.1)",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=8080,
        help="port used with --serve (default: 8080)",
    )
    return parser


def _resolved_output(value: Path, parser: argparse.ArgumentParser) -> Path:
    output = value.expanduser()
    if not output.is_absolute():
        output = PROJECT_ROOT / output
    output = output.resolve()
    broad_targets = {
        PROJECT_ROOT.resolve(),
        PROJECT_ROOT.resolve().parent,
        Path(output.anchor).resolve(),
    }
    if output in broad_targets:
        parser.error("--output must name a dedicated export directory")
    return output


def _run(command: list[str]) -> None:
    print(f"\n> {subprocess.list2cmdline(command)}", flush=True)
    subprocess.run(command, cwd=PROJECT_ROOT, check=True)


def _verify_export(output: Path, proxy_path: str) -> int:
    missing = [name for name in REQUIRED_WEB_FILES if not (output / name).is_file()]
    if missing:
        joined = ", ".join(missing)
        raise RuntimeError(f"Web build completed but required files are missing: {joined}")
    bootstrap = (output / "flutter_bootstrap.js").read_text(encoding="utf-8")
    if 'canvasKitBaseUrl: "canvaskit/"' not in bootstrap:
        raise RuntimeError("Web bootstrap is not configured to use local CanvasKit")
    main_script = (output / "main.dart.js").read_text(encoding="utf-8")
    if proxy_path not in main_script:
        raise RuntimeError("Web build does not contain the configured cloud proxy path")
    return sum(path.stat().st_size for path in output.rglob("*") if path.is_file())


def main(argv: list[str] | None = None) -> int:
    parser = _parser()
    args = parser.parse_args(argv)
    if not 1 <= args.port <= 65535:
        parser.error("--port must be between 1 and 65535")
    output = _resolved_output(args.output, parser)
    try:
        flutter = find_flutter()
        flutter_command = str(flutter)
        print(f"Flutter: {flutter}")
        print(f"Output:  {output}")
        print(f"Base:    {args.base_href}")
        print(f"Web in-memory file limit: {args.max_file_mib} MiB")
        print(f"Web cloud proxy path: {args.proxy_path}")

        if not args.no_pub:
            _run([flutter_command, "pub", "get"])
        if not args.skip_checks:
            _run([flutter_command, "analyze", "--no-pub"])
            _run([flutter_command, "test", "--no-pub"])

        command = [
            flutter_command,
            "build",
            "web",
            "--debug" if args.debug else "--release",
            "--no-pub",
            "--no-wasm-dry-run",
            "--base-href",
            args.base_href,
            "--output",
            str(output),
            f"--dart-define=SBOX_WEB_MAX_FILE_MIB={args.max_file_mib}",
            f"--dart-define=SBOX_WEB_PROXY_PATH={args.proxy_path}",
        ]
        if args.source_maps:
            command.append("--source-maps")
        _run(command)
        total_bytes = _verify_export(output, args.proxy_path)
    except FileNotFoundError as error:
        print(f"Export failed: {error}", file=sys.stderr)
        return 1
    except subprocess.CalledProcessError as error:
        print(
            f"Export failed: command exited with status {error.returncode}",
            file=sys.stderr,
        )
        return error.returncode or 1
    except RuntimeError as error:
        print(f"Export failed: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\nExport cancelled.", file=sys.stderr)
        return 130

    print(f"\nSafeBox Web export is ready: {output}")
    print(f"Static payload: {total_bytes / (1024 * 1024):.2f} MiB")
    print(
        "Cloud access requires the same-origin proxy; run "
        "serve_safebox_web.py or provide an equivalent HTTPS endpoint."
    )
    if args.serve:
        from serve_safebox_web import main as serve_main

        return serve_main(
            [
                "--directory",
                str(output),
                "--host",
                args.host,
                "--port",
                str(args.port),
                "--proxy-path",
                args.proxy_path,
            ]
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
