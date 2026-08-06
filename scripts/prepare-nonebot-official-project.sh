#!/usr/bin/env bash
set -euo pipefail

NB_CLI_VERSION="${NB_CLI_VERSION:-1.7.4}"
NB_DOCKER_PLUGIN_VERSION="${NB_DOCKER_PLUGIN_VERSION:-0.6.1}"
MIMO_CONSOLE_COMMIT="${MIMO_CONSOLE_COMMIT:-acd83708b875245ba26617ed6cd7c622b59d1949}"
MIMO_CONSOLE_REPOSITORY="${MIMO_CONSOLE_REPOSITORY:-gufei233/nonebot-plugin-mimo-console}"
MIMO_CONSOLE_ARCHIVE_URL="${MIMO_CONSOLE_ARCHIVE_URL:-https://github.com/${MIMO_CONSOLE_REPOSITORY}/archive/${MIMO_CONSOLE_COMMIT}.zip}"
NONEBOT_PYTHON_INDEX="${NONEBOT_PYTHON_INDEX:-https://pypi.org/simple/}"
PLAYWRIGHT_DOWNLOAD_HOST="${PLAYWRIGHT_DOWNLOAD_HOST:-}"
NAG_DEBIAN_MIRROR="${NAG_DEBIAN_MIRROR:-}"
# 留空则保留 nb-cli 生成的 FROM python:...（Docker Hub）。大陆网络下由
# install.sh 传入镜像站上的同名副本。
NAG_NONEBOT_REQUIREMENTS_IMAGE="${NAG_NONEBOT_REQUIREMENTS_IMAGE:-}"
NAG_NONEBOT_RUNTIME_IMAGE="${NAG_NONEBOT_RUNTIME_IMAGE:-}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

usage() {
  cat <<'EOF'
Usage:
  prepare-nonebot-official-project.sh \
    --kind personal|official \
    --with-gs true|false \
    --project-dir PATH \
    --environment-file PATH \
    --data-dir PATH \
    --cache-dir PATH \
    --compose-project NAME \
    --container-name NAME \
    --network NAME \
    --network-alias NAME \
    --web-port PORT \
    --token-file PATH \
    --image-repository NAME

The project itself is created and maintained with the official NoneBot CLI:
  nb adapter install
  nb plugin install
  nb docker generate

NAG-specific mounts, networking and Mimo Agent access live only in
docker-compose.nag.yml. The official Dockerfile and docker-compose.yml remain
untouched.
EOF
}

kind=""
with_gs="true"
project_dir=""
environment_file=""
data_dir=""
cache_dir=""
compose_project=""
container_name=""
network_name=""
network_alias=""
web_port=""
token_file=""
image_repository=""

while (($#)); do
  case "$1" in
    --kind) kind="${2:-}"; shift 2 ;;
    --with-gs) with_gs="${2:-}"; shift 2 ;;
    --project-dir) project_dir="${2:-}"; shift 2 ;;
    --environment-file) environment_file="${2:-}"; shift 2 ;;
    --data-dir) data_dir="${2:-}"; shift 2 ;;
    --cache-dir) cache_dir="${2:-}"; shift 2 ;;
    --compose-project) compose_project="${2:-}"; shift 2 ;;
    --container-name) container_name="${2:-}"; shift 2 ;;
    --network) network_name="${2:-}"; shift 2 ;;
    --network-alias) network_alias="${2:-}"; shift 2 ;;
    --web-port) web_port="${2:-}"; shift 2 ;;
    --token-file) token_file="${2:-}"; shift 2 ;;
    --image-repository) image_repository="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 64 ;;
  esac
done

case "$kind" in
  personal|official) ;;
  *) printf '%s\n' "--kind must be personal or official" >&2; exit 64 ;;
esac
case "$with_gs" in
  true|false) ;;
  *) printf '%s\n' "--with-gs must be true or false" >&2; exit 64 ;;
esac
for required in project_dir environment_file data_dir cache_dir compose_project \
  container_name network_name network_alias web_port token_file image_repository; do
  [[ -n "${!required}" ]] || {
    printf 'Missing required option: %s\n' "$required" >&2
    exit 64
  }
done
[[ "$project_dir" == /* ]] || {
  printf '%s\n' "--project-dir must be absolute" >&2
  exit 64
}
[[ "$data_dir" == /* && "$cache_dir" == /* && "$token_file" == /* ]] || {
  printf '%s\n' "data, cache and token paths must be absolute" >&2
  exit 64
}
if [[ ! "$web_port" =~ ^[0-9]+$ ]] \
  || ((10#$web_port < 1 || 10#$web_port > 65535)); then
  printf '%s\n' "--web-port must be between 1 and 65535" >&2
  exit 64
fi
for safe_value in "$compose_project" "$container_name" "$network_name" \
  "$network_alias" "$image_repository"; do
  [[ "$safe_value" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || {
    printf 'Unsafe identifier: %s\n' "$safe_value" >&2
    exit 64
  }
done
command -v uv >/dev/null 2>&1 || {
  printf '%s\n' "uv is required" >&2
  exit 69
}
command -v "$PYTHON_BIN" >/dev/null 2>&1 || {
  printf '%s is required\n' "$PYTHON_BIN" >&2
  exit 69
}
[[ "$MIMO_CONSOLE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || {
  printf '%s\n' "MIMO_CONSOLE_COMMIT must be a full lowercase Git commit" >&2
  exit 64
}
[[ "$MIMO_CONSOLE_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
  printf '%s\n' "MIMO_CONSOLE_REPOSITORY must be owner/repository" >&2
  exit 64
}
[[ "$MIMO_CONSOLE_ARCHIVE_URL" == https://* ]] || {
  printf '%s\n' "MIMO_CONSOLE_ARCHIVE_URL must use HTTPS" >&2
  exit 64
}
[[ -f "$environment_file" ]] || {
  printf 'NoneBot environment file does not exist: %s\n' "$environment_file" >&2
  exit 66
}
if [[ ! -f "$token_file" ]]; then
  command -v openssl >/dev/null 2>&1 || {
    printf '%s\n' "openssl is required to create the Mimo Agent token" >&2
    exit 69
  }
  install -d -m 0700 "$(dirname "$token_file")"
  umask 077
  openssl rand -hex 32 >"$token_file"
fi
chmod 0600 "$token_file"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
mkdir -p \
  "$project_dir" \
  "$data_dir" \
  "$data_dir/localstore/data" \
  "$data_dir/localstore/config" \
  "$cache_dir"

# Project mutation needs a temporary Python environment, but the deployed
# project itself is image-only. Keeping that environment outside the build
# context avoids stale host wheels, large contexts and Docker Desktop symlink
# failures while preserving the official pyproject.toml + uv.lock workflow.
tool_runtime="$(mktemp -d)"
project_venv="${project_dir}/.venv"
cleanup_tool_runtime() {
  if [[ -L "$project_venv" \
    && "$(readlink -f -- "$project_venv")" == \
      "$(readlink -f -- "${tool_runtime}/project-venv")" ]]; then
    rm -f -- "$project_venv"
  fi
  rm -rf -- "$tool_runtime"
}
trap cleanup_tool_runtime EXIT
export UV_PROJECT_ENVIRONMENT="${tool_runtime}/project-venv"

kind_marker="${project_dir}/.nag-nonebot-kind"
if [[ -f "$kind_marker" && "$(<"$kind_marker")" != "$kind" ]]; then
  printf 'Project kind mismatch at %s\n' "$project_dir" >&2
  exit 65
fi

run_nb() {
  (
    cd "$project_dir"
    ENVIRONMENT=prod uvx --from "nb-cli==${NB_CLI_VERSION}" "$@"
  )
}

if [[ ! -f "${project_dir}/pyproject.toml" ]]; then
  uv init --bare --name "nag-nonebot-${kind}" --python 3.12 "$project_dir"
  if [[ ! -f "${project_dir}/.python-version" ]]; then
    printf '%s\n' '3.12' >"${project_dir}/.python-version"
  fi
  uv add --directory "$project_dir" \
    "nonebot2[fastapi,httpx,websockets]==2.5.0"
fi
if [[ ! -f "${project_dir}/.python-version" ]]; then
  printf '%s\n' '3.12' >"${project_dir}/.python-version"
fi
printf '%s\n' "$kind" >"$kind_marker"
if [[ ! -f "${project_dir}/uv.lock" ]]; then
  uv lock --directory "$project_dir"
fi
uv sync --directory "$project_dir" --frozen

# nb-cli discovers the project interpreter through .venv rather than
# UV_PROJECT_ENVIRONMENT. Expose the disposable environment only while the
# official CLI mutates/generates the project, then remove it before Docker sees
# the build context.
if [[ -e "$project_venv" || -L "$project_venv" ]]; then
  if [[ -f "${project_venv}/pyvenv.cfg" || -L "$project_venv" ]]; then
    rm -rf -- "$project_venv"
  else
    printf 'Refusing to replace unmanaged project path: %s\n' \
      "$project_venv" >&2
    exit 65
  fi
fi
ln -s "$UV_PROJECT_ENVIRONMENT" "$project_venv"

if [[ "$kind" == "personal" ]]; then
  adapter_project="nonebot-adapter-onebot"
  adapter_key="nonebot-adapter-onebot"
else
  adapter_project="nonebot-adapter-qq"
  adapter_key="nonebot-adapter-qq"
fi

if ! grep -Fq "${adapter_key} =" "${project_dir}/pyproject.toml"; then
  run_nb nb adapter install "$adapter_project" --no-restrict-version
fi
if [[ "$with_gs" == "true" ]] \
  && ! grep -Fq 'nonebot-plugin-genshinuid =' "${project_dir}/pyproject.toml"; then
  run_nb nb plugin install nonebot-plugin-genshinuid --no-restrict-version
elif [[ "$with_gs" == "false" ]] \
  && grep -Fq 'nonebot-plugin-genshinuid =' "${project_dir}/pyproject.toml"; then
  run_nb nb plugin uninstall nonebot-plugin-genshinuid
fi

mimo_requirement="$(
  printf 'nonebot-plugin-mimo-console @ %s' "$MIMO_CONSOLE_ARCHIVE_URL"
)"
# Reconcile the pinned Docker-capable build on every NAG run. This also upgrades
# projects created by an older NAG release instead of silently retaining it.
uv add --directory "$project_dir" \
  --upgrade-package nonebot-plugin-mimo-console \
  "$mimo_requirement"

uv run --directory "$project_dir" --frozen python - \
  "${project_dir}/pyproject.toml" "$with_gs" <<'PY'
import sys
from pathlib import Path

import tomlkit

path = Path(sys.argv[1])
with_gs = sys.argv[2] == "true"
document = tomlkit.parse(path.read_text(encoding="utf-8"))
tool = document.setdefault("tool", tomlkit.table())
nonebot = tool.setdefault("nonebot", tomlkit.table())
plugins = nonebot.setdefault("plugins", tomlkit.table())
if not isinstance(plugins, dict):
    raise TypeError("[tool.nonebot.plugins] must be a table")
plugins["nonebot-plugin-mimo-console"] = ["nonebot_plugin_mimo_console"]
if not with_gs:
    plugins.pop("nonebot-plugin-genshinuid", None)
path.write_text(tomlkit.dumps(document), encoding="utf-8")
PY
uv lock --directory "$project_dir"

environment_target="${project_dir}/.env.prod"
if [[ "$(realpath -m "$environment_file")" != "$(realpath -m "$environment_target")" ]]; then
  install -m 0600 "$environment_file" "$environment_target"
else
  chmod 0600 "$environment_target"
fi

run_nb \
  --with "nb-cli-plugin-docker==${NB_DOCKER_PLUGIN_VERSION}" \
  nb docker generate --force

dockerignore="${project_dir}/.dockerignore"
if ! grep -Fq '# NAG managed exclusions' "$dockerignore"; then
  cat >>"$dockerignore" <<'EOF'

# NAG managed exclusions: keep credentials, local tooling and deployment
# metadata out of the runtime image and its immutable build layers.
.env
.env.*
.venv/
.mimo/
.nag-*
Dockerfile.nag
docker-compose.nag.yml
EOF
fi

"$PYTHON_BIN" "$script_dir/patch-nonebot-dockerfile.py" \
  "${project_dir}/Dockerfile" "${project_dir}/Dockerfile.nag" \
  --requirements-image "$NAG_NONEBOT_REQUIREMENTS_IMAGE" \
  --runtime-image "$NAG_NONEBOT_RUNTIME_IMAGE"

cat >"${project_dir}/docker-compose.nag.yml" <<EOF
services:
  nonebot:
    image: ${image_repository}:base
    build:
      context: .
      dockerfile: Dockerfile.nag
      args:
        PIP_INDEX_URL: ${NONEBOT_PYTHON_INDEX}
        PLAYWRIGHT_DOWNLOAD_HOST: ${PLAYWRIGHT_DOWNLOAD_HOST}
        NAG_DEBIAN_MIRROR: ${NAG_DEBIAN_MIRROR}
    container_name: ${container_name}
    restart: unless-stopped
    init: true
    # Replace the anonymous host port emitted by the official template.
    ports: !override
      - "127.0.0.1:${web_port}:8080"
    volumes:
      - ${data_dir}:/app/data
      - ${data_dir}/localstore/data:/root/.local/share/nonebot2
      - ${data_dir}/localstore/config:/root/.config/nonebot2
      - ${cache_dir}:/root/.cache/nonebot2
      - ${environment_target}:/app/.env.prod:ro
      - /run/mimo-agent:/run/mimo-agent:ro
      - ${token_file}:/run/secrets/mimo-agent-token:ro
    healthcheck:
      test:
        - CMD
        - python
        - -c
        - from urllib.request import urlopen; r=urlopen("http://127.0.0.1:8080/mimo-console/api/auth/status",timeout=3); assert r.status == 200
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 45s
    stop_grace_period: 30s
    networks:
      ${network_name}:
        aliases:
          - ${network_alias}

networks:
  ${network_name}:
    external: true
    name: ${network_name}
EOF

cat >"${project_dir}/.nag-compose.env" <<EOF
COMPOSE_PROJECT_NAME=${compose_project}
COMPOSE_FILE=docker-compose.yml:docker-compose.nag.yml
EOF
chmod 0600 "${project_dir}/.nag-compose.env"

uv lock --check --directory "$project_dir"
cleanup_tool_runtime
trap - EXIT
printf 'NAG_NONEBOT_PROJECT=%s\n' "$project_dir"
printf 'NAG_NONEBOT_COMPOSE_PROJECT=%s\n' "$compose_project"
printf 'NAG_NONEBOT_SERVICE=nonebot\n'
