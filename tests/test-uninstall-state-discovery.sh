#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_state_dir="$(mktemp -d)"
trap 'rm -rf -- "$test_state_dir"' EXIT

export NAG_INSTALL_STATE_DIR="$test_state_dir"
# Load function definitions without entering the interactive installer.
# shellcheck disable=SC1090
source <(sed '/^choose_mode$/,$d' "$repo_root/install.sh")

printf 'DATA_ROOT=/opt/interrupted-data\n' >"$test_state_dir/guided.env.tmp"
actual="$(newest_env_file_for_project nag)"
[[ "$actual" == "$test_state_dir/guided.env.tmp" ]]

printf 'DATA_ROOT=/opt/complete-data\n' >"$test_state_dir/guided.env"
actual="$(newest_env_file_for_project nag)"
[[ "$actual" == "$test_state_dir/guided.env" ]]

touch "$test_state_dir/guided.env.tmp"
actual="$(newest_env_file_for_project nag)"
[[ "$actual" == "$test_state_dir/guided.env.tmp" ]]
