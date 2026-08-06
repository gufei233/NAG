from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "scripts" / "patch-nonebot-dockerfile.py"
SPEC = importlib.util.spec_from_file_location("patch_nonebot_dockerfile", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PatchDockerfileTest(unittest.TestCase):
    def test_replaces_both_python_stages_before_inserting_extensions(self) -> None:
        source_text = """\
FROM python:3.12 AS requirements_stage
COPY pyproject.toml uv.lock ./
RUN python -m pip wheel --wheel-dir=/wheel --no-cache-dir --requirement ./requirements.txt

FROM python:3.12-slim
COPY --from=requirements_stage /wheel /wheel
RUN python -m pip install --no-cache-dir --no-index --find-links=/wheel -r /wheel/requirements.txt
COPY . /app/
"""
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "Dockerfile"
            target = Path(temporary) / "Dockerfile.nag"
            source.write_text(source_text, encoding="utf-8")

            MODULE.patch(
                source,
                target,
                "mirror.invalid/python:3.12_amd64",
                "mirror.invalid/python:3.12-slim_amd64",
            )

            from_lines = [
                line
                for line in target.read_text(encoding="utf-8").splitlines()
                if line.startswith("FROM ")
            ]
            self.assertEqual(
                from_lines,
                [
                    "FROM mirror.invalid/python:3.12_amd64 AS requirements_stage",
                    "FROM mirror.invalid/python:3.12-slim_amd64",
                ],
            )
            patched = target.read_text(encoding="utf-8")
            self.assertIn(
                "Playwright mirror failed; retrying the official download host.",
                patched,
            )
            self.assertIn(
                "env -u PLAYWRIGHT_DOWNLOAD_HOST python -m playwright install",
                patched,
            )


if __name__ == "__main__":
    unittest.main()
