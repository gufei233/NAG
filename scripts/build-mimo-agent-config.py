#!/usr/bin/env python3
"""Merge NAG-managed Mimo Agent instance fragments into one configuration."""

from __future__ import annotations

import argparse
import json
import os
import tempfile
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--instances-dir", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument(
        "--uv-image",
        default="local/mimo-agent-uv-git:0.9.29-1",
    )
    args = parser.parse_args()

    instances: dict[str, object] = {}
    for path in sorted(args.instances_dir.glob("*.json")):
        item = json.loads(path.read_text(encoding="utf-8"))
        instance_id = item.pop("instance_id")
        if instance_id in instances:
            raise ValueError(f"duplicate Mimo instance: {instance_id}")
        instances[instance_id] = item
    if not instances:
        raise ValueError("at least one Mimo instance fragment is required")

    config = {
        "socket_path": "/run/mimo-agent/agent.sock",
        "socket_mode": "0660",
        "state_dir": "/var/lib/mimo-console-agent",
        "docker_bin": "docker",
        "uv_image": args.uv_image,
        "instances": instances,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        dir=args.output.parent,
        prefix=f".{args.output.name}.",
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(config, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, args.output)
    finally:
        temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
