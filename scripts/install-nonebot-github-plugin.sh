#!/bin/sh

set -eu

repo_url=$1
repo_name=$2
import_override="${3:-}"
plugins_root="${NAG_PLUGIN_ROOT:-/plugins}"
target="${plugins_root}/${repo_name}"
dependency_refresh=0

find_module() {
  for base in "$1" "$1/src"; do
    [ -d "$base" ] || continue
    for candidate in "$base"/nonebot_plugin_*; do
      [ -f "$candidate/__init__.py" ] || continue
      basename "$candidate"
      return 0
    done
  done
  return 1
}

dependency_fingerprint() {
  for dependency_file in \
    "$1/requirements.txt" "$1/pyproject.toml" "$1/.nag-plugin-module"; do
    [ -f "$dependency_file" ] || continue
    printf '%s\n' "$dependency_file"
    cat "$dependency_file"
  done | sha256sum | awk '{print $1}'
}

normalize_github_origin() {
  origin=$1
  case "$origin" in
    git@github.com:*)
      origin="https://github.com/${origin#git@github.com:}"
      ;;
    git+https://github.com/*)
      origin="${origin#git+}"
      ;;
  esac
  origin="${origin%/}"
  origin="${origin%.git}"
  printf '%s' "$origin"
}

if [ -e "$target" ]; then
  [ -d "$target/.git" ] || {
    echo "目标目录已存在但不是 Git 仓库：$target" >&2
    exit 64
  }
  git config --global --add safe.directory "$target"
  current_origin="$(git -C "$target" remote get-url origin)"
  if [ "$(normalize_github_origin "$current_origin")" != \
    "$(normalize_github_origin "$repo_url")" ]; then
    echo "目标目录 origin 与请求仓库不一致：$current_origin" >&2
    exit 66
  fi
  before_dependencies="$(dependency_fingerprint "$target")"
  git -C "$target" pull --ff-only
else
  staging="$(mktemp -d "${plugins_root}/.${repo_name}.new.XXXXXX")"
  cleanup() {
    rm -rf "$staging"
  }
  trap cleanup EXIT INT TERM
  git clone --depth 1 "$repo_url" "$staging"
  if [ -z "$import_override" ] && ! find_module "$staging" >/dev/null; then
    echo "仓库中未自动识别到 nonebot_plugin_* 包；请使用 --plugin-import 指定导入名。" >&2
    exit 65
  fi
  mv "$staging" "$target"
  trap - EXIT INT TERM
  before_dependencies=""
fi

marker="$target/.nag-plugin-module"
if [ -n "$import_override" ]; then
  printf '%s\n' "$import_override" >"$marker"
  module="$import_override"
else
  rm -f "$marker"
  module="$(find_module "$target")"
fi
after_dependencies="$(dependency_fingerprint "$target")"
[ "$before_dependencies" = "$after_dependencies" ] || dependency_refresh=1
printf 'NAG_PLUGIN_MODULE=%s\nNAG_PLUGIN_CHANGED=%s\n' \
  "$module" "$dependency_refresh"
