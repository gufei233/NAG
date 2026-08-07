#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest
import yaml


repo_root = Path(__file__).resolve().parents[1]
module_path = repo_root / "scripts" / "run-playwright-with-mirror.py"
spec = importlib.util.spec_from_file_location("playwright_mirror", module_path)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

installer = (repo_root / "install.sh").read_text(encoding="utf-8")


def test_chrome_for_testing_path() -> None:
    assert module.mirror_url(
        "https://registry.npmmirror.com/-/binary/",
        "/builds/cft/145.0.7632.6/linux64/chrome-linux64.zip",
    ) == (
        "https://registry.npmmirror.com/-/binary/chrome-for-testing/"
        "145.0.7632.6/linux64/chrome-linux64.zip"
    )


def test_actual_playwright_chrome_for_testing_path() -> None:
    assert module.mirror_url(
        "https://registry.npmmirror.com/-/binary",
        "/145.0.7632.6/linux64/chrome-linux64.zip",
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


def test_installer_forces_mirror_into_every_init_path() -> None:
    assert installer.count("run_gscore_xwuid_deps_init() {") == 1
    assert installer.count("run_gscore_xwuid_deps_init official_compose") == 1
    assert installer.count("run_gscore_xwuid_deps_init guided_compose") == 1
    assert installer.count("run_gscore_xwuid_deps_init compose") == 1
    assert '-e "NAG_PLAYWRIGHT_NPMMIRROR_BASE=$mirror_base"' in installer
    assert (
        "--profile init run --rm gscore-xwuid-deps-init" not in installer
    )


@pytest.mark.parametrize(
    "compose_path",
    [
        "docker-compose.yml",
        "docker-compose.guided.yml",
        "docker-compose.nonebot.yml",
        "NG/docker-compose.yml",
    ],
)
def test_init_service_receives_playwright_mirror(compose_path: str) -> None:
    compose = yaml.safe_load(
        (repo_root / compose_path).read_text(encoding="utf-8")
    )
    environment = compose["services"]["gscore-xwuid-deps-init"]["environment"]
    assert "NAG_PLAYWRIGHT_NPMMIRROR_BASE" in environment
