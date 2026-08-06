#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
test_root="${NAG_TEST_ROOT:-$(mktemp -d)}"
expected_mimo_console_commit="acd83708b875245ba26617ed6cd7c622b59d1949"
cleanup=1
[[ -z "${NAG_TEST_ROOT:-}" ]] || cleanup=0
if ((cleanup)); then
  trap 'rm -rf "$test_root"' EXIT INT TERM
fi

mkdir -p "$test_root"

assert_project() {
  local kind="$1"
  local expected_adapter="$2"
  local expected_gs="$3"
  local project="${test_root}/${kind}/project"

  assert_contains "\"${expected_adapter}" "${project}/pyproject.toml"
  if [[ "$expected_gs" == "true" ]]; then
    assert_contains '"nonebot-plugin-genshinuid' "${project}/pyproject.toml"
  elif grep -Fq 'nonebot-plugin-genshinuid' "${project}/pyproject.toml"; then
    printf 'GenshinUID remained installed in non-GS project: %s\n' \
      "$project" >&2
    return 1
  fi
  assert_contains '"nonebot-plugin-mimo-console"' \
    "${project}/pyproject.toml"
  assert_contains 'https://github.com/gufei233/nonebot-plugin-mimo-console/archive/' \
    "${project}/pyproject.toml"
  assert_contains 'nonebot-plugin-mimo-console = ["nonebot_plugin_mimo_console"]' \
    "${project}/pyproject.toml"
  assert_contains 'COPY . /app/' "${project}/Dockerfile"
  assert_contains '3.12' "${project}/.python-version"
  assert_contains '# NAG managed exclusions' "${project}/.dockerignore"
  assert_contains '.env.*' "${project}/.dockerignore"
  assert_contains '.venv/' "${project}/.dockerignore"
  assert_contains 'playwright install --with-deps chromium' \
    "${project}/Dockerfile.nag"
  assert_contains 'ARG PIP_INDEX_URL' "${project}/Dockerfile.nag"
  assert_contains 'ARG PLAYWRIGHT_DOWNLOAD_HOST' "${project}/Dockerfile.nag"
  assert_contains 'ARG NAG_DEBIAN_MIRROR' "${project}/Dockerfile.nag"
  assert_contains 'FROM test.invalid/python:3.12' "${project}/Dockerfile.nag"
  assert_contains 'FROM test.invalid/python:3.12-slim' "${project}/Dockerfile.nag"
  assert_contains '--find-links=/wheel /wheel/*.whl' \
    "${project}/Dockerfile.nag"
  if grep -Fq "RUN python - <<'PY'" "${project}/Dockerfile.nag"; then
    printf 'Dockerfile heredoc is incompatible with older BuildKit: %s\n' \
      "${project}/Dockerfile.nag" >&2
    return 1
  fi
  assert_contains '/mimo-console/api/auth/status' \
    "${project}/docker-compose.nag.yml"
  assert_contains '/run/mimo-agent:/run/mimo-agent:ro' \
    "${project}/docker-compose.nag.yml"
  if [[ -e "${project}/.venv" || -L "${project}/.venv" ]]; then
    printf 'Disposable project environment leaked into build context: %s\n' \
      "${project}/.venv" >&2
    return 1
  fi
  uv lock --check --directory "$project"
}

assert_contains() {
  local needle="$1"
  local path="$2"
  grep -Fq -- "$needle" "$path" || {
    printf 'Missing expected text %q in %s\n' "$needle" "$path" >&2
    return 1
  }
}

assert_default_mimo_console_commit() {
  local path="$1"
  local actual
  actual="$(
    sed -n \
      's/.*MIMO_CONSOLE_COMMIT:-\([0-9a-f]\{40\}\).*/\1/p' \
      "$path"
  )"
  if [[ "$actual" != "$expected_mimo_console_commit" ]]; then
    printf 'Unexpected Mimo Console commit in %s: %s\n' \
      "$path" "${actual:-<missing>}" >&2
    return 1
  fi
}

prepare_project() {
  local kind="$1"
  local adapter="$2"
  local port="$3"
  local with_gs="$4"
  local root="${test_root}/${kind}"
  local project="${root}/project"
  local environment="${root}/env.prod"

  mkdir -p "$project"
  cat >"$environment" <<EOF
ENVIRONMENT=prod
HOST=0.0.0.0
PORT=8080
DRIVER=~fastapi+~httpx+~websockets
SUPERUSERS=[]
COMMAND_START=["/"]
MIMO_CONSOLE_DEPLOYMENT_MODE=auto
MIMO_CONSOLE_INSTANCE_ID=${kind}
MIMO_CONSOLE_AGENT_SOCKET=/run/mimo-agent/agent.sock
MIMO_CONSOLE_AGENT_TOKEN_FILE=/run/secrets/mimo-agent-token
EOF
  if [[ "$kind" == "official" ]]; then
    cat >>"$environment" <<'EOF'
QQ_IS_SANDBOX=true
QQ_BOTS=[]
EOF
  fi

  NAG_NONEBOT_REQUIREMENTS_IMAGE=test.invalid/python:3.12 \
  NAG_NONEBOT_RUNTIME_IMAGE=test.invalid/python:3.12-slim \
    bash "${repo_root}/scripts/prepare-nonebot-official-project.sh" \
    --kind "$kind" \
    --with-gs "$with_gs" \
    --project-dir "$project" \
    --environment-file "$environment" \
    --data-dir "${root}/data" \
    --cache-dir "${root}/cache" \
    --compose-project "nag-test-${kind}" \
    --container-name "nag-test-nonebot-${kind}" \
    --network nag-test-net \
    --network-alias "nonebot-${kind}" \
    --web-port "$port" \
    --token-file "${root}/${kind}.token" \
    --image-repository "local/nag-test-nonebot-${kind}"

  assert_project "$kind" "$adapter" "$with_gs"
}

assert_default_mimo_console_commit "${repo_root}/install.sh"
assert_default_mimo_console_commit \
  "${repo_root}/scripts/prepare-nonebot-official-project.sh"
assert_default_mimo_console_commit \
  "${repo_root}/scripts/register-mimo-agent-instance.sh"

prepare_project personal nonebot-adapter-onebot 18091 true
prepare_project official nonebot-adapter-qq 18092 true
# A personal NoneBot may be installed only as an extra framework while another
# adapter owns GsCore. Reconcile an existing project and ensure GS is removed
# without removing the OneBot adapter or Mimo Console.
prepare_project personal nonebot-adapter-onebot 18091 false
printf 'Official NoneBot project generation checks passed: %s\n' "$test_root"
