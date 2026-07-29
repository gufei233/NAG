#!/usr/bin/env bash
set -euo pipefail

MIMO_CONSOLE_COMMIT="${MIMO_CONSOLE_COMMIT:-bfce00254a60008018a91e9b61dc3b785f315ed9}"
MIMO_CONSOLE_GIT_URL="${MIMO_CONSOLE_GIT_URL:-https://github.com/gufei233/nonebot-plugin-mimo-console.git}"
MIMO_AGENT_UV_BASE_IMAGE="${MIMO_AGENT_UV_BASE_IMAGE:-ghcr.io/astral-sh/uv:0.9.29-python3.12-bookworm-slim}"
MIMO_AGENT_UV_GIT_IMAGE="${MIMO_AGENT_UV_GIT_IMAGE:-local/mimo-agent-uv-git:0.9.29-1}"
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
agent_python="$(command -v "$PYTHON_BIN")"
[[ -x "$agent_python" ]] || {
  printf 'Python interpreter is not executable: %s\n' "$agent_python" >&2
  exit 69
}
[[ "$MIMO_CONSOLE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || {
  printf '%s\n' "MIMO_CONSOLE_COMMIT must be a full lowercase Git commit" >&2
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
git -C "$source_root" fetch --quiet --depth 1 origin "$MIMO_CONSOLE_COMMIT"
git -C "$source_root" checkout --quiet --detach FETCH_HEAD

if ! docker image inspect "$MIMO_AGENT_UV_GIT_IMAGE" >/dev/null 2>&1; then
  docker build \
    --build-arg "UV_IMAGE=${MIMO_AGENT_UV_BASE_IMAGE}" \
    --file "${source_root}/agent/docker/uv-git.Dockerfile" \
    --tag "$MIMO_AGENT_UV_GIT_IMAGE" \
    "${source_root}/agent"
fi

action="install"
[[ ! -f /etc/systemd/system/mimo-console-agent.service ]] || action="upgrade"
"${source_root}/agent/scripts/manage-service.sh" "$action" \
  --source "${source_root}/agent" \
  --config "$config_file" \
  --python "$agent_python"

printf 'MIMO_AGENT_INSTANCE=%s\n' "$instance_id"
printf 'MIMO_AGENT_CONFIG=%s\n' "$config_file"
