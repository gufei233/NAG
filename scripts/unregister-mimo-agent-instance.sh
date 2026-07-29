#!/usr/bin/env bash
set -euo pipefail

[[ "$(id -u)" -eq 0 ]] || {
  printf '%s\n' "unregister-mimo-agent-instance.sh must run as root" >&2
  exit 77
}
(($# > 0)) || {
  printf 'Usage: %s [--project-dir PATH] INSTANCE_ID...\n' "$0" >&2
  exit 64
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
config_root="/etc/mimo-console-agent"
instances_dir="${config_root}/instances.d"
config_file="${config_root}/agent.json"
expected_project=""
instance_ids=()

while (($#)); do
  case "$1" in
    --project-dir)
      expected_project="${2:-}"
      shift 2
      ;;
    --)
      shift
      instance_ids+=("$@")
      break
      ;;
    -*)
      printf 'Unknown argument: %s\n' "$1" >&2
      exit 64
      ;;
    *)
      instance_ids+=("$1")
      shift
      ;;
  esac
done
((${#instance_ids[@]} > 0)) || {
  printf '%s\n' "At least one instance id is required" >&2
  exit 64
}
if [[ -n "$expected_project" ]]; then
  [[ "$expected_project" == /* ]] || {
    printf '%s\n' "--project-dir must be absolute" >&2
    exit 64
  }
  expected_project="$(realpath -m -- "$expected_project")"
fi

for instance_id in "${instance_ids[@]}"; do
  fragment="${instances_dir}/${instance_id}.json"
  [[ "$instance_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || {
    printf 'Invalid instance id: %s\n' "$instance_id" >&2
    exit 64
  }
  if [[ -n "$expected_project" && -f "$fragment" ]]; then
    registered_project="$(
      python3 - "$fragment" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(payload.get("project_root", ""), end="")
PY
    )"
    if [[ -n "$registered_project" \
      && "$(realpath -m -- "$registered_project")" != "$expected_project" ]]; then
      printf 'Skip %s: registered project is %s, not %s\n' \
        "$instance_id" "$registered_project" "$expected_project"
      continue
    fi
  elif [[ -n "$expected_project" && ! -f "$fragment" ]]; then
    printf 'Skip %s: no matching Agent registration\n' "$instance_id"
    continue
  fi
  rm -f -- \
    "$fragment" \
    "${config_root}/${instance_id}.token"
done

if compgen -G "${instances_dir}/*.json" >/dev/null; then
  uv_image="$(
    python3 - "$config_file" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
if path.is_file():
    payload = json.loads(path.read_text(encoding="utf-8"))
    print(payload.get("uv_image", ""), end="")
PY
  )"
  build_args=()
  [[ -z "$uv_image" ]] || build_args=(--uv-image "$uv_image")
  python3 "$script_dir/build-mimo-agent-config.py" \
    --instances-dir "$instances_dir" \
    --output "$config_file" \
    "${build_args[@]}"
  systemctl restart mimo-console-agent.service
else
  systemctl disable --now mimo-console-agent.service 2>/dev/null || true
  rm -f -- "$config_file"
fi
