"""Run SafeBox on the Windows desktop target.

Usage:
    python run_safebox.py
    python run_safebox.py --release

Set FLUTTER_ROOT if Flutter is not on PATH, for example:
    $env:FLUTTER_ROOT = 'C:\\src\\flutter'
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parent


def _flutter_executable(root: Path) -> Path | None:
    """Return the Flutter executable below an SDK root, if it exists."""
    for name in ("flutter.bat", "flutter.exe", "flutter"):
        candidate = root / "bin" / name
        if candidate.is_file():
            return candidate
    return None


def _flutter_from_package_config() -> Path | None:
    """Use the SDK recorded by this Flutter project's package configuration."""
    package_config = PROJECT_ROOT / ".dart_tool" / "package_config.json"
    if not package_config.is_file():
        return None

    try:
        packages = json.loads(package_config.read_text(encoding="utf-8"))[
            "packages"
        ]
        flutter_package = next(
            package for package in packages if package.get("name") == "flutter"
        )
        root_uri = flutter_package["rootUri"]
    except (KeyError, StopIteration, TypeError, ValueError, OSError):
        return None

    prefix = "file:///"
    if not root_uri.startswith(prefix):
        return None
    flutter_package_root = Path(root_uri[len(prefix) :].replace("/", os.sep))
    return _flutter_executable(flutter_package_root.parent.parent)


def find_flutter() -> Path:
    """Find Flutter using explicit configuration, PATH, or local SDK hints."""
    configured_root = os.environ.get("FLUTTER_ROOT")
    if configured_root:
        executable = _flutter_executable(Path(configured_root).expanduser())
        if executable:
            return executable
        raise FileNotFoundError(
            f"FLUTTER_ROOT does not point to a Flutter SDK: {configured_root}"
        )

    for command in ("flutter", "flutter.bat"):
        executable = shutil.which(command)
        if executable:
            return Path(executable)

    package_config_executable = _flutter_from_package_config()
    if package_config_executable:
        return package_config_executable

    for root in (
        Path.home() / ".cache" / "codex-tools" / "flutter-stable",
        Path.home() / "development" / "flutter",
        Path.home() / "src" / "flutter",
        Path("C:/src/flutter"),
    ):
        executable = _flutter_executable(root)
        if executable:
            return executable

    raise FileNotFoundError(
        "Flutter was not found. Install Flutter or set FLUTTER_ROOT to its SDK path."
    )


def main() -> int:
    try:
        flutter = find_flutter()
    except FileNotFoundError as error:
        print(error, file=sys.stderr)
        return 1

    flutter_args = sys.argv[1:]
    if "--pub" not in flutter_args and "--no-pub" not in flutter_args:
        flutter_args.append("--no-pub")

    command = [str(flutter), "run", "-d", "windows", *flutter_args]
    print(f"Running SafeBox with {flutter}")
    print("Press Ctrl+C to stop the Flutter runner.")
    try:
        return subprocess.run(command, cwd=PROJECT_ROOT).returncode
    except KeyboardInterrupt:
        print("\nStopped.")
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
