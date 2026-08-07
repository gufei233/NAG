#!/usr/bin/env bash
set -euo pipefail

MIMO_CONSOLE_REF="${MIMO_CONSOLE_REF:-master}"
MIMO_CONSOLE_GIT_URL="${MIMO_CONSOLE_GIT_URL:-https://github.com/MimoKit/nonebot-plugin-mimo-console.git}"
MIMO_AGENT_UV_BASE_IMAGE="${MIMO_AGENT_UV_BASE_IMAGE:-ghcr.io/astral-sh/uv:0.9.29-python3.12-bookworm-slim}"
MIMO_AGENT_UV_GIT_IMAGE="${MIMO_AGENT_UV_GIT_IMAGE:-local/mimo-agent-uv-git:0.9.29-1}"
# Agent 的 pyproject 要求 >=3.10；Debian 11 之类的老发行版只带 3.9，写死
# /usr/bin/python3 会让 uv sync 直接判不兼容。留空则在下面用 uv 解析出
# 满足条件的解释器真实路径（必要时由 uv 下载 standalone 版本）。
MIMO_AGENT_PYTHON="${MIMO_AGENT_PYTHON:-}"
MIMO_AGENT_PYTHON_REQUEST="${MIMO_AGENT_PYTHON_REQUEST:-3.12}"
# 容器内 apt 走官方源在大陆网络只有几十 kB/s，由 install.sh 传入镜像站。
NAG_DEBIAN_MIRROR="${NAG_DEBIAN_MIRROR:-}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

usage() {
  cat <<'EOF'
Usage:
  register-mimo-agent-instance.sh \
    --instance-id ID \
    --project-dir PATH \
    --compose-project NAME \
    --image-repository NAME \
    --health-port PORT \
    --token-file PATH

Registers or updates one official Docker NoneBot project and installs/upgrades
the restricted host-side Mimo Agent. Existing instance fragments are preserved.
EOF
}

instance_id=""
project_dir=""
compose_project=""
image_repository=""
health_port=""
token_file=""

while (($#)); do
  case "$1" in
    --instance-id) instance_id="${2:-}"; shift 2 ;;
    --project-dir) project_dir="${2:-}"; shift 2 ;;
    --compose-project) compose_project="${2:-}"; shift 2 ;;
    --image-repository) image_repository="${2:-}"; shift 2 ;;
    --health-port) health_port="${2:-}"; shift 2 ;;
    --token-file) token_file="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 64 ;;
  esac
done

[[ "$(id -u)" -eq 0 ]] || {
  printf '%s\n' "register-mimo-agent-instance.sh must run as root" >&2
  exit 77
}
for required in instance_id project_dir compose_project image_repository \
  health_port token_file; do
  [[ -n "${!required}" ]] || {
    printf 'Missing required option: %s\n' "$required" >&2
    exit 64
  }
done
[[ "$instance_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || {
  printf '%s\n' "Invalid instance id" >&2
  exit 64
}
[[ "$compose_project" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || {
  printf '%s\n' "Invalid Compose project" >&2
  exit 64
}
[[ "$image_repository" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,254}$ ]] || {
  printf '%s\n' "Invalid image repository" >&2
  exit 64
}
if [[ ! "$health_port" =~ ^[0-9]+$ ]] \
  || ((10#$health_port < 1 || 10#$health_port > 65535)); then
  printf '%s\n' "Invalid health port" >&2
  exit 64
fi
project_dir="$(cd "$project_dir" && pwd -P)"
for required_file in pyproject.toml uv.lock Dockerfile.nag docker-compose.yml \
  docker-compose.nag.yml .env.prod; do
  [[ -f "${project_dir}/${required_file}" ]] || {
    printf 'Missing project file: %s\n' "${project_dir}/${required_file}" >&2
    exit 66
  }
done
[[ -f "$token_file" ]] || {
  printf 'Missing instance token: %s\n' "$token_file" >&2
  exit 66
}
command -v git >/dev/null 2>&1 || {
  printf '%s\n' "git is required" >&2
  exit 69
}
command -v uv >/dev/null 2>&1 || {
  printf '%s\n' "uv is required" >&2
  exit 69
}
command -v systemctl >/dev/null 2>&1 || {
  printf '%s\n' "systemd is required" >&2
  exit 69
}
command -v docker >/dev/null 2>&1 || {
  printf '%s\n' "docker is required" >&2
  exit 69
}
command -v "$PYTHON_BIN" >/dev/null 2>&1 || {
  printf '%s is required\n' "$PYTHON_BIN" >&2
  exit 69
}
[[ "$MIMO_CONSOLE_REF" =~ ^[A-Za-z0-9._/-]+$ ]] || {
  printf '%s\n' "MIMO_CONSOLE_REF contains unsafe characters" >&2
  exit 64
}
[[ "$MIMO_CONSOLE_REF" != *..* && "$MIMO_CONSOLE_REF" != *//* \
  && "$MIMO_CONSOLE_REF" != */ && "$MIMO_CONSOLE_REF" != *. ]] || {
  printf '%s\n' "MIMO_CONSOLE_REF is not a valid branch or tag" >&2
  exit 64
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
config_root="/etc/mimo-console-agent"
instances_dir="${config_root}/instances.d"
fragment="${instances_dir}/${instance_id}.json"
config_file="${config_root}/agent.json"
install -d -m 0700 "$instances_dir"

if ! compgen -G "${instances_dir}/*.json" >/dev/null \
  && [[ -f "$config_file" ]]; then
  "$PYTHON_BIN" - "$config_file" "$instances_dir" <<'PY'
import json
import os
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
instances_dir = Path(sys.argv[2])
config = json.loads(config_path.read_text(encoding="utf-8"))
for instance_id, value in config.get("instances", {}).items():
    fragment = instances_dir / f"{instance_id}.json"
    payload = {"instance_id": instance_id, **value}
    fragment.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    os.chmod(fragment, 0o600)
PY
fi

"$PYTHON_BIN" - "$fragment" "$instance_id" "$project_dir" "$compose_project" \
  "$image_repository" "$health_port" "$token_file" <<'PY'
import json
import os
import sys
import tempfile
from pathlib import Path

(
    output_name,
    instance_id,
    project_root,
    compose_project,
    image_repository,
    health_port,
    token_file,
) = sys.argv[1:]
output = Path(output_name)
payload = {
    "instance_id": instance_id,
    "project_root": project_root,
    "compose_files": [
        "docker-compose.yml",
        "docker-compose.nag.yml",
    ],
    "compose_project": compose_project,
    "service": "nonebot",
    "dockerfile": "Dockerfile.nag",
    "build_context": ".",
    "image_repository": image_repository,
    "override_file": ".mimo/docker-compose.override.yml",
    "environment_file": ".env.prod",
    "build_args": [
        "PIP_INDEX_URL",
        "PLAYWRIGHT_DOWNLOAD_HOST",
        "NAG_DEBIAN_MIRROR",
    ],
    "health_url": (
        f"http://127.0.0.1:{health_port}"
        "/mimo-console/api/auth/status"
    ),
    "token_file": token_file,
    "health_timeout": 180,
    "build_timeout": 3600,
    "deploy_timeout": 600,
    "keep_images": 3,
}
descriptor, temporary_name = tempfile.mkstemp(
    dir=output.parent,
    prefix=f".{output.name}.",
)
temporary = Path(temporary_name)
try:
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temporary, 0o600)
    os.replace(temporary, output)
finally:
    temporary.unlink(missing_ok=True)
PY

"$PYTHON_BIN" "$script_dir/build-mimo-agent-config.py" \
  --instances-dir "$instances_dir" \
  --output "$config_file" \
  --uv-image "$MIMO_AGENT_UV_GIT_IMAGE"

source_root="$(mktemp -d /opt/mimo-console-source.XXXXXX)"
trap 'rm -rf "$source_root"' EXIT INT TERM
git -C "$source_root" init --quiet
git -C "$source_root" remote add origin "$MIMO_CONSOLE_GIT_URL"
git -C "$source_root" fetch --quiet --depth 1 origin "$MIMO_CONSOLE_REF"
git -C "$source_root" checkout --quiet --detach FETCH_HEAD

if ! docker image inspect "$MIMO_AGENT_UV_GIT_IMAGE" >/dev/null 2>&1; then
  dockerfile="${source_root}/agent/docker/uv-git.Dockerfile"
  # 上游 Dockerfile 没有换源开关，容器内 apt 会直连 deb.debian.org；大陆网络下
  # 实测只有几十 kB/s（18MB 装了 7 分钟）。这里另写一份带换源的 Dockerfile，
  # 既拿到镜像站速度，又不必改上游仓库。
  if [[ -n "$NAG_DEBIAN_MIRROR" ]]; then
    # 与 patch-nonebot-dockerfile.py 保持同一约定：这里收的是主机名而非 URL。
    [[ "$NAG_DEBIAN_MIRROR" != *://* ]] || {
      printf 'NAG_DEBIAN_MIRROR must be a bare host, not a URL: %s\n' \
        "$NAG_DEBIAN_MIRROR" >&2
      exit 64
    }
    # 换源串会进 Dockerfile 的 sed 表达式，只放行主机名字符。
    [[ "$NAG_DEBIAN_MIRROR" != *[!A-Za-z0-9.:/-]* ]] || {
      printf '%s\n' "NAG_DEBIAN_MIRROR contains unsafe characters" >&2
      exit 64
    }
    dockerfile="${source_root}/agent/docker/uv-git.nag.Dockerfile"
    # bookworm 起用 deb822 格式（sources.list.d/*.sources），旧版仍是
    # sources.list；两处都换才对得上不同 base 镜像。
    cat >"$dockerfile" <<DOCKERFILE
ARG UV_IMAGE=${MIMO_AGENT_UV_BASE_IMAGE}
FROM \${UV_IMAGE}

RUN find /etc/apt -type f \\( -name '*.list' -o -name '*.sources' \\) \\
      -exec sed -i \\
        -e "s|deb.debian.org|${NAG_DEBIAN_MIRROR}|g" \\
        -e "s|security.debian.org|${NAG_DEBIAN_MIRROR}|g" {} + \\
    && apt-get update \\
    && apt-get install --no-install-recommends --yes ca-certificates git \\
    && rm -rf /var/lib/apt/lists/*
DOCKERFILE
    printf 'Using Debian mirror %s for the uv-git image\n' "$NAG_DEBIAN_MIRROR"
  fi
  docker build \
    --build-arg "UV_IMAGE=${MIMO_AGENT_UV_BASE_IMAGE}" \
    --file "$dockerfile" \
    --tag "$MIMO_AGENT_UV_GIT_IMAGE" \
    "${source_root}/agent"
fi

action="install"
[[ ! -f /etc/systemd/system/mimo-console-agent.service ]] || action="upgrade"
# manage-service.sh 会对 --python 做 [ -x ] 校验，所以只能给真实路径，不能给
# "3.12" 这类版本请求。Agent 要求 >=3.10，而 Debian 11 之类的老发行版只带 3.9，
# 写死 /usr/bin/python3 会让 uv sync 判不兼容；这里先让 uv 解析出满足条件的
# 解释器（本机没有就下载 standalone 版），再把真实路径传下去。
if [[ -z "$MIMO_AGENT_PYTHON" ]]; then
  if ! MIMO_AGENT_PYTHON="$(
    uv python find "$MIMO_AGENT_PYTHON_REQUEST" 2>/dev/null
  )"; then
    uv python install "$MIMO_AGENT_PYTHON_REQUEST" >&2 || {
      printf 'Failed to provision Python %s for the Agent\n' \
        "$MIMO_AGENT_PYTHON_REQUEST" >&2
      exit 69
    }
    MIMO_AGENT_PYTHON="$(uv python find "$MIMO_AGENT_PYTHON_REQUEST")" || {
      printf 'Failed to locate Python %s after install\n' \
        "$MIMO_AGENT_PYTHON_REQUEST" >&2
      exit 69
    }
  fi
fi
[[ -x "$MIMO_AGENT_PYTHON" ]] || {
  printf 'Agent Python interpreter is not executable: %s\n' \
    "$MIMO_AGENT_PYTHON" >&2
  exit 69
}
printf 'Using %s for the Mimo Agent runtime\n' "$MIMO_AGENT_PYTHON"
"${source_root}/agent/scripts/manage-service.sh" "$action" \
  --source "${source_root}/agent" \
  --config "$config_file" \
  --python "$MIMO_AGENT_PYTHON"

printf 'MIMO_AGENT_INSTANCE=%s\n' "$instance_id"
printf 'MIMO_AGENT_CONFIG=%s\n' "$config_file"
