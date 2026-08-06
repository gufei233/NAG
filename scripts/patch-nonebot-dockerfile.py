#!/usr/bin/env python3
"""Create NAG's additive Dockerfile from nb-cli-plugin-docker output."""

from __future__ import annotations

import argparse
from pathlib import Path


REQUIREMENTS_MARKER = "FROM python:"
FINAL_STAGE_MARKER = "-slim"
COPY_PROJECT_MARKER = "COPY . /app/"
WHEEL_BUILD_MARKER = (
    "RUN python -m pip wheel --wheel-dir=/wheel --no-cache-dir "
    "--requirement ./requirements.txt"
)


def patch(
    source: Path,
    target: Path,
    requirements_image: str = "",
    runtime_image: str = "",
) -> None:
    text = source.read_text(encoding="utf-8")
    lines = text.splitlines()

    from_indexes = [
        index for index, line in enumerate(lines) if line.startswith(REQUIREMENTS_MARKER)
    ]
    if len(from_indexes) != 2 or FINAL_STAGE_MARKER not in lines[from_indexes[1]]:
        raise ValueError(
            "Unsupported nb-cli-plugin-docker Dockerfile: expected two Python stages"
        )
    try:
        copy_project_index = lines.index(COPY_PROJECT_MARKER)
    except ValueError as exc:
        raise ValueError(
            "Unsupported nb-cli-plugin-docker Dockerfile: project copy marker missing"
        ) from exc
    try:
        wheel_build_index = lines.index(WHEEL_BUILD_MARKER)
    except ValueError as exc:
        raise ValueError(
            "Unsupported nb-cli-plugin-docker Dockerfile: wheel build marker missing"
        ) from exc

    if requirements_image or runtime_image:
        replacements = {
            from_indexes[0]: requirements_image,
            from_indexes[1]: runtime_image,
        }
        for index, image in replacements.items():
            if not image:
                continue
            suffix = lines[index][len("FROM ") :].split(" ", 1)
            stage = f" {suffix[1]}" if len(suffix) > 1 else ""
            lines[index] = f"FROM {image}{stage}"

    requirements_packages = [
        "ARG PIP_INDEX_URL",
        "ARG PLAYWRIGHT_DOWNLOAD_HOST",
        "ARG NAG_DEBIAN_MIRROR",
        "",
        "# NAG extension: allow locked Git/VCS dependencies in the official wheel stage.",
        'RUN if [ -n "$NAG_DEBIAN_MIRROR" ]; then \\',
        "      find /etc/apt -type f \\( -name '*.list' -o -name '*.sources' \\) \\",
        "        -exec sed -i \\",
        '          -e "s|deb.debian.org|$NAG_DEBIAN_MIRROR|g" \\',
        '          -e "s|security.debian.org|$NAG_DEBIAN_MIRROR|g" {} +; \\',
        "    fi",
        "RUN apt-get update \\",
        "  && apt-get install --no-install-recommends -y ca-certificates git \\",
        "  && rm -rf /var/lib/apt/lists/*",
    ]
    final_packages = [
        "ARG PIP_INDEX_URL",
        "ARG PLAYWRIGHT_DOWNLOAD_HOST",
        "ARG NAG_DEBIAN_MIRROR",
        "",
        "# NAG extension: baseline media libraries used by GS and common bot plugins.",
        'RUN if [ -n "$NAG_DEBIAN_MIRROR" ]; then \\',
        "      find /etc/apt -type f \\( -name '*.list' -o -name '*.sources' \\) \\",
        "        -exec sed -i \\",
        '          -e "s|deb.debian.org|$NAG_DEBIAN_MIRROR|g" \\',
        '          -e "s|security.debian.org|$NAG_DEBIAN_MIRROR|g" {} +; \\',
        "    fi",
        "RUN apt-get update \\",
        "  && apt-get install --no-install-recommends -y ca-certificates ffmpeg libcairo2 git \\",
        "  && rm -rf /var/lib/apt/lists/*",
    ]

    offset = 0
    first_insert = from_indexes[0] + 1
    lines[first_insert:first_insert] = requirements_packages
    offset += len(requirements_packages)

    second_insert = from_indexes[1] + offset + 1
    lines[second_insert:second_insert] = final_packages
    offset += len(final_packages)

    copy_project_index += offset
    browser_hook = [
        "",
        "# NAG extension: install Chromium only when a WebUI-installed plugin needs it.",
        'RUN if python -c "import playwright" >/dev/null 2>&1; then \\',
        "      if ! python -m playwright install --with-deps chromium; then \\",
        '        if [ -z "$PLAYWRIGHT_DOWNLOAD_HOST" ]; then exit 1; fi; \\',
        '        echo "Playwright mirror failed; retrying the official download host."; \\',
        "        env -u PLAYWRIGHT_DOWNLOAD_HOST python -m playwright install --with-deps chromium; \\",
        "      fi; \\",
        "    fi",
        "",
    ]
    lines[copy_project_index:copy_project_index] = browser_hook

    # Installing every wheel produced by the official requirements stage also
    # covers locked VCS/direct dependencies without requiring Git or network
    # access in the runtime stage. Avoid Dockerfile heredocs here so projects
    # still build on Docker Engine 20.10 and other older BuildKit frontends.
    lines = [
        line.replace(
            "--find-links=/wheel -r /wheel/requirements.txt",
            "--find-links=/wheel /wheel/*.whl",
        )
        for line in lines
    ]

    target.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("target", type=Path)
    parser.add_argument(
        "--requirements-image",
        default="",
        help="replace the wheel-building stage base image (default: keep upstream)",
    )
    parser.add_argument(
        "--runtime-image",
        default="",
        help="replace the runtime stage base image (default: keep upstream)",
    )
    args = parser.parse_args()
    patch(
        args.source.resolve(),
        args.target.resolve(),
        args.requirements_image,
        args.runtime_image,
    )


if __name__ == "__main__":
    main()
