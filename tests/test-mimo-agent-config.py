#!/usr/bin/env python3
"""Validate the merged NAG Agent configuration against Mimo Agent's parser."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--projects-root", required=True, type=Path)
    parser.add_argument("--nag-root", required=True, type=Path)
    parser.add_argument("--agent-source", required=True, type=Path)
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="nag-agent-config-") as temporary_name:
        temporary = Path(temporary_name)
        instances_dir = temporary / "instances.d"
        instances_dir.mkdir()

        for kind, port in (("personal", 18091), ("official", 18092)):
            project_root = (args.projects_root / kind / "project").resolve()
            token_file = (args.projects_root / kind / f"{kind}.token").resolve()
            payload = {
                "instance_id": kind,
                "project_root": str(project_root),
                "compose_files": [
                    "docker-compose.yml",
                    "docker-compose.nag.yml",
                ],
                "compose_project": f"nag-test-{kind}",
                "service": "nonebot",
                "dockerfile": "Dockerfile.nag",
                "build_context": ".",
                "image_repository": f"local/nag-test-nonebot-{kind}",
                "override_file": ".mimo/docker-compose.override.yml",
                "environment_file": ".env.prod",
                "health_url": (
                    f"http://127.0.0.1:{port}"
                    "/mimo-console/api/auth/status"
                ),
                "token_file": str(token_file),
                "health_timeout": 180,
                "build_timeout": 3600,
                "deploy_timeout": 600,
                "keep_images": 3,
            }
            (instances_dir / f"{kind}.json").write_text(
                json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )

        config_file = temporary / "agent.json"
        subprocess.run(
            [
                sys.executable,
                str(args.nag_root / "scripts" / "build-mimo-agent-config.py"),
                "--instances-dir",
                str(instances_dir),
                "--output",
                str(config_file),
                "--uv-image",
                "local/mimo-agent-uv-git:0.9.29-1",
            ],
            check=True,
        )

        sys.path.insert(0, str(args.agent_source / "src"))
        from mimo_console_agent.config import AgentConfig

        config = AgentConfig.load(config_file)
        assert set(config.instances) == {"personal", "official"}
        assert config.instances["personal"].service == "nonebot"
        assert config.instances["official"].service == "nonebot"
        print("Mimo Agent configuration valid: personal, official")


if __name__ == "__main__":
    main()
