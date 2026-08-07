#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
from pathlib import Path


repo_root = Path(__file__).resolve().parents[1]
module_path = repo_root / "scripts" / "run-playwright-with-mirror.py"
spec = importlib.util.spec_from_file_location("playwright_mirror", module_path)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def test_chrome_for_testing_path() -> None:
    assert module.mirror_url(
        "https://registry.npmmirror.com/-/binary/",
        "/builds/cft/145.0.7632.6/linux64/chrome-linux64.zip",
    ) == (
        "https://registry.npmmirror.com/-/binary/chrome-for-testing/"
        "145.0.7632.6/linux64/chrome-linux64.zip"
    )


def test_regular_playwright_path() -> None:
    assert module.mirror_url(
        "https://registry.npmmirror.com/-/binary",
        "/builds/ffmpeg/1011/ffmpeg-linux.zip",
    ) == (
        "https://registry.npmmirror.com/-/binary/playwright/"
        "builds/ffmpeg/1011/ffmpeg-linux.zip"
    )
