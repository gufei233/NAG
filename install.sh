#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly STATE_DIR="${NAG_INSTALL_STATE_DIR:-${SCRIPT_DIR}/.installer}"
readonly DOCKER_BIN="${NAG_DOCKER_BIN:-docker}"
readonly NAPCAT_COMPAT_IMAGE="mlikiowa/napcat-docker:v4.18.5"
readonly NAPCAT_ADAPTER_LATEST_URL="https://github.com/xiowo/napcat-plugin-gscore-adapter/releases/latest/download/napcat-plugin-gscore-adapter.zip"

MODE=""
ASSUME_YES=0
DRY_RUN=0
INSTALL_WUWA=1
INSTALL_WUWA_DEPS=1
FIXED_MAC=1
USE_CNB_MIRRORS=0

log() {
  printf '[NAG] %s\n' "$*"
}

warn() {
  printf '[NAG] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[NAG] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: bash install.sh [options]

Interactive installer for NAG/NG.

Options:
  --mode MODE   Deployment mode:
                  astrbot         NapCat + AstrBot + GsCore, AstrBot adapter
                  hybrid          NapCat + AstrBot + GsCore, NapCat adapter
                  napcat          NapCat + GsCore, NapCat adapter
  --yes         Accept the recommended answers for optional questions
  --dry-run     Print the selected plan without changing the host
  -h, --help    Show this help

The installer stores its private Compose environment under .installer/.
Application login, tokens, and business settings remain manual WebUI steps.
EOF
}

while (($# > 0)); do
  case "$1" in
    --mode)
      (($# >= 2)) || die "--mode requires a value"
      MODE="$2"
      shift 2
      ;;
    --yes)
      ASSUME_YES=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

choose_mode() {
  if [[ -n "$MODE" ]]; then
    return
  fi

  [[ -t 0 ]] || die "no interactive terminal; pass --mode and optionally --yes"
  cat <<'EOF'

请选择部署方式：
  1) NapCat + AstrBot + GsCore，使用 AstrBot GScore 适配器
  2) NapCat + AstrBot + GsCore，使用 NapCat GScore 适配器
  3) NapCat + GsCore，使用 NapCat GScore 适配器（轻量版）
EOF

  local choice
  while true; do
    read -r -p "请输入 1、2 或 3: " choice
    case "$choice" in
      1) MODE="astrbot"; return ;;
      2) MODE="hybrid"; return ;;
      3) MODE="napcat"; return ;;
      *) warn "请输入有效选项" ;;
    esac
  done
}

prompt_value() {
  local prompt="$1"
  local default="$2"
  local value=""

  if ((ASSUME_YES)); then
    printf '%s' "$default"
    return
  fi

  read -r -p "${prompt} [${default}]: " value
  printf '%s' "${value:-$default}"
}

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-y}"
  local answer=""

  if ((ASSUME_YES)); then
    [[ "$default" == "y" ]]
    return
  fi

  while true; do
    if [[ "$default" == "y" ]]; then
      read -r -p "${prompt} [Y/n]: " answer
      answer="${answer:-y}"
    else
      read -r -p "${prompt} [y/N]: " answer
      answer="${answer:-n}"
    fi
    case "${answer,,}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) warn "请输入 y 或 n" ;;
    esac
  done
}

env_value() {
  local key="$1"
  local file="$2"
  [[ -f "$file" ]] || return 0
  awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); sub(/\r$/, ""); print; exit}' "$file"
}

env_default() {
  local key="$1"
  local fallback="$2"
  local value
  value="$(env_value "$key" "$ENV_FILE")"
  printf '%s' "${value:-$fallback}"
}

validate_port() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || die "$name must be a number"
  ((10#$value >= 1 && 10#$value <= 65535)) || die "$name must be between 1 and 65535"
}

validate_single_line() {
  local name="$1"
  local value="$2"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "$name must be a single line"
}

random_mac() {
  printf '02:%02x:%02x:%02x:%02x:%02x' \
    "$((RANDOM % 256))" "$((RANDOM % 256))" "$((RANDOM % 256))" \
    "$((RANDOM % 256))" "$((RANDOM % 256))"
}

choose_mode

case "$MODE" in
  astrbot)
    MODE_LABEL="NapCat + AstrBot + GsCore（AstrBot GScore 适配器）"
    PROJECT_NAME="nag"
    PROJECT_DIR="$SCRIPT_DIR"
    ENV_FILE="${STATE_DIR}/astrbot.env"
    DEFAULT_DATA_ROOT="/opt/nag-data"
    COMPOSE_FILES=("${SCRIPT_DIR}/docker-compose.yml")
    ADAPTER_KIND="astrbot"
    ;;
  hybrid)
    MODE_LABEL="NapCat + AstrBot + GsCore（NapCat GScore 适配器）"
    PROJECT_NAME="nag"
    PROJECT_DIR="$SCRIPT_DIR"
    ENV_FILE="${STATE_DIR}/hybrid.env"
    DEFAULT_DATA_ROOT="/opt/nag-data"
    COMPOSE_FILES=(
      "${SCRIPT_DIR}/docker-compose.yml"
      "${SCRIPT_DIR}/docker-compose.napcat-adapter.yml"
    )
    ADAPTER_KIND="napcat"
    ;;
  napcat)
    MODE_LABEL="NapCat + GsCore（NapCat GScore 适配器）"
    PROJECT_NAME="ng"
    PROJECT_DIR="${SCRIPT_DIR}/NG"
    ENV_FILE="${STATE_DIR}/napcat.env"
    DEFAULT_DATA_ROOT="/opt/ng-data"
    COMPOSE_FILES=("${SCRIPT_DIR}/NG/docker-compose.yml")
    ADAPTER_KIND="napcat"
    ;;
  *)
    die "unsupported mode: $MODE (expected astrbot, hybrid, or napcat)"
    ;;
esac

DATA_ROOT="$(prompt_value "持久化数据目录" "$(env_default DATA_ROOT "$DEFAULT_DATA_ROOT")")"
BIND_IP="$(prompt_value "WebUI 绑定地址" "$(env_default BIND_IP "127.0.0.1")")"
GSCORE_PORT="$(prompt_value "GsCore WebUI 端口" "$(env_default GSCORE_PORT "8765")")"
NAPCAT_WEBUI_PORT="$(prompt_value "NapCat WebUI 端口" "$(env_default NAPCAT_WEBUI_PORT "6099")")"
ASTRBOT_WEBUI_PORT="$(env_default ASTRBOT_WEBUI_PORT "6185")"
if [[ "$MODE" != "napcat" ]]; then
  ASTRBOT_WEBUI_PORT="$(prompt_value "AstrBot WebUI 端口" "$ASTRBOT_WEBUI_PORT")"
fi

[[ "$DATA_ROOT" == /* ]] || die "DATA_ROOT must be an absolute path"
case "$BIND_IP" in
  127.0.0.1|0.0.0.0) ;;
  *) die "BIND_IP must be 127.0.0.1 or 0.0.0.0" ;;
esac
validate_port GSCORE_PORT "$GSCORE_PORT"
validate_port NAPCAT_WEBUI_PORT "$NAPCAT_WEBUI_PORT"
if [[ "$MODE" != "napcat" ]]; then
  validate_port ASTRBOT_WEBUI_PORT "$ASTRBOT_WEBUI_PORT"
fi
[[ "$GSCORE_PORT" != "$NAPCAT_WEBUI_PORT" ]] || die "GsCore and NapCat ports must differ"
if [[ "$MODE" != "napcat" ]]; then
  [[ "$GSCORE_PORT" != "$ASTRBOT_WEBUI_PORT" && "$NAPCAT_WEBUI_PORT" != "$ASTRBOT_WEBUI_PORT" ]] || \
    die "all WebUI ports must differ"
fi

NAPCAT_UID="$(id -u)"
NAPCAT_GID="$(id -g)"
NAPCAT_MAC="$(env_default NAPCAT_MAC "")"
if prompt_yes_no "为 NapCat 生成并固定唯一 MAC 地址" y; then
  FIXED_MAC=1
  NAPCAT_MAC="${NAPCAT_MAC:-$(random_mac)}"
else
  FIXED_MAC=0
  NAPCAT_MAC=""
fi

if prompt_yes_no "安装鸣潮插件套件（XutheringWavesUID、RoverSign、ScoreEcho）" y; then
  INSTALL_WUWA=1
  if prompt_yes_no "安装 Playwright、OpenCV、字体及拼音等额外依赖" y; then
    INSTALL_WUWA_DEPS=1
  else
    INSTALL_WUWA_DEPS=0
  fi
else
  INSTALL_WUWA=0
  INSTALL_WUWA_DEPS=0
fi

if ((INSTALL_WUWA)) && prompt_yes_no "使用 CNB 镜像克隆鸣潮插件（适合 GitHub 访问较慢时）" n; then
  USE_CNB_MIRRORS=1
  XUTHERINGWAVESUID_REPO="https://cnb.cool/gscore-mirror/XutheringWavesUID"
  ROVERSIGN_REPO="https://cnb.cool/gscore-mirror/RoverSign"
  SCOREECHO_REPO="https://cnb.cool/gscore-mirror/ScoreEcho"
else
  USE_CNB_MIRRORS=0
  XUTHERINGWAVESUID_REPO="https://github.com/Loping151/XutheringWavesUID.git"
  ROVERSIGN_REPO="https://github.com/Loping151/RoverSign.git"
  SCOREECHO_REPO="https://github.com/Loping151/ScoreEcho.git"
fi

NAPCAT_ADAPTER_URL="$(env_default NAPCAT_GSCORE_ADAPTER_ZIP_URL "$NAPCAT_ADAPTER_LATEST_URL")"
if [[ "$ADAPTER_KIND" == "napcat" ]] && (( ! ASSUME_YES )); then
  NAPCAT_ADAPTER_URL="$(prompt_value "NapCat GScore 适配器 ZIP 地址" "$NAPCAT_ADAPTER_URL")"
fi

for pair in \
  "DATA_ROOT=$DATA_ROOT" "BIND_IP=$BIND_IP" \
  "GSCORE_PORT=$GSCORE_PORT" "ASTRBOT_WEBUI_PORT=$ASTRBOT_WEBUI_PORT" \
  "NAPCAT_WEBUI_PORT=$NAPCAT_WEBUI_PORT" "NAPCAT_ADAPTER_URL=$NAPCAT_ADAPTER_URL"; do
  validate_single_line "${pair%%=*}" "${pair#*=}"
done

if [[ "$ADAPTER_KIND" == "napcat" ]]; then
  NAPCAT_IMAGE="$NAPCAT_COMPAT_IMAGE"
else
  NAPCAT_IMAGE="mlikiowa/napcat-docker:latest"
fi

print_summary() {
  cat <<EOF

部署方案：$MODE_LABEL
数据目录：$DATA_ROOT
WebUI 绑定：$BIND_IP
GsCore 端口：$GSCORE_PORT
NapCat 端口：$NAPCAT_WEBUI_PORT
EOF
  if [[ "$MODE" != "napcat" ]]; then
    printf 'AstrBot 端口：%s\n' "$ASTRBOT_WEBUI_PORT"
  fi
  printf 'NapCat 镜像：%s\n' "$NAPCAT_IMAGE"
  printf '固定 MAC：%s\n' "${NAPCAT_MAC:-不启用}"
  printf '鸣潮插件：%s\n' "$([[ $INSTALL_WUWA -eq 1 ]] && printf 安装 || printf 跳过)"
  printf '额外依赖：%s\n\n' "$([[ $INSTALL_WUWA_DEPS -eq 1 ]] && printf 安装 || printf 跳过)"
  if ((INSTALL_WUWA)); then
    printf '插件仓库：%s\n\n' "$([[ $USE_CNB_MIRRORS -eq 1 ]] && printf CNB镜像 || printf GitHub)"
  fi
}

print_summary
if ((DRY_RUN)); then
  log "dry-run completed; no files, containers, or directories were changed"
  exit 0
fi

if ! prompt_yes_no "确认开始安装" y; then
  log "installation cancelled"
  exit 0
fi

command -v "$DOCKER_BIN" >/dev/null 2>&1 || die "Docker is not installed"
"$DOCKER_BIN" compose version >/dev/null 2>&1 || die "Docker Compose V2 is required"
"$DOCKER_BIN" info >/dev/null 2>&1 || die "cannot access the Docker daemon; check service status and user permissions"

case "$(uname -m)" in
  x86_64|amd64|aarch64|arm64) ;;
  *) warn "the current architecture ($(uname -m)) is not listed by the NapCat Docker image" ;;
esac

mkdir -p "$STATE_DIR"
tmp_env="${ENV_FILE}.tmp"
cat >"$tmp_env" <<EOF
# Generated by install.sh for mode: $MODE
DATA_ROOT=$DATA_ROOT
BIND_IP=$BIND_IP
TZ=Asia/Shanghai
GSCORE_PORT=$GSCORE_PORT
ASTRBOT_WEBUI_PORT=$ASTRBOT_WEBUI_PORT
NAPCAT_WEBUI_PORT=$NAPCAT_WEBUI_PORT
NAPCAT_UID=$NAPCAT_UID
NAPCAT_GID=$NAPCAT_GID
NAPCAT_MAC=$NAPCAT_MAC
GSCORE_IMAGE=docker.cnb.cool/gscore-mirror/gsuid_core:latest
ASTRBOT_IMAGE=soulter/astrbot:latest
NAPCAT_IMAGE=$NAPCAT_IMAGE
NAPCAT_GSCORE_ADAPTER_ZIP_URL=$NAPCAT_ADAPTER_URL
ASTRBOT_GSCORE_ADAPTER_REPO=https://github.com/KimigaiiWuyi/astrbot_plugin_gscore_adapter.git
XUTHERINGWAVESUID_REPO=$XUTHERINGWAVESUID_REPO
ROVERSIGN_REPO=$ROVERSIGN_REPO
SCOREECHO_REPO=$SCOREECHO_REPO
GSCORE_PYTHON_INDEX=https://pypi.org/simple/
UV_NO_CONFIG=0
PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
GSCORE_XWUID_PYTHON_PACKAGES=playwright opencv-python fonttools pypinyin
EOF
mv -f "$tmp_env" "$ENV_FILE"
chmod 600 "$ENV_FILE"

DATA_DIRS=(
  "$DATA_ROOT/gscore/data"
  "$DATA_ROOT/gscore/plugins"
  "$DATA_ROOT/napcat/config"
  "$DATA_ROOT/napcat/plugins"
  "$DATA_ROOT/napcat/qq"
)
if [[ "$MODE" != "napcat" ]]; then
  DATA_DIRS+=("$DATA_ROOT/astrbot")
fi

if ! mkdir -p "${DATA_DIRS[@]}" 2>/dev/null; then
  command -v sudo >/dev/null 2>&1 || die "cannot create $DATA_ROOT and sudo is unavailable"
  log "需要 sudo 创建数据目录"
  sudo install -d -m 0755 -o "$NAPCAT_UID" -g "$NAPCAT_GID" "${DATA_DIRS[@]}"
fi

for data_dir in "${DATA_DIRS[@]}"; do
  [[ -w "$data_dir" ]] || die "$data_dir is not writable by UID $NAPCAT_UID; fix its ownership or permissions"
done

if [[ "$MODE" == "hybrid" && -e "$DATA_ROOT/astrbot/plugins/astrbot_plugin_gscore_adapter" ]]; then
  warn "AstrBot GScore adapter already exists in persistent data. Disable it before using the NapCat adapter to avoid duplicate handling."
fi

COMPOSE=("$DOCKER_BIN" compose --project-directory "$PROJECT_DIR" --env-file "$ENV_FILE" -p "$PROJECT_NAME")
for compose_file in "${COMPOSE_FILES[@]}"; do
  COMPOSE+=(-f "$compose_file")
done
if ((FIXED_MAC)); then
  if [[ "$MODE" == "napcat" ]]; then
    COMPOSE+=(-f "${SCRIPT_DIR}/NG/docker-compose.mac.example.yml")
  else
    COMPOSE+=(-f "${SCRIPT_DIR}/docker-compose.mac.example.yml")
  fi
fi

compose() {
  "${COMPOSE[@]}" "$@"
}

compose config --quiet

if [[ "$ADAPTER_KIND" == "napcat" ]]; then
  resolved_napcat_image="$(compose config | awk '
    /^  napcat:$/ {in_napcat=1; next}
    in_napcat && /^  [^ ]/ {exit}
    in_napcat && /^    image:/ {sub(/^    image:[[:space:]]*/, ""); print; exit}
  ')"
  [[ "$resolved_napcat_image" == "$NAPCAT_COMPAT_IMAGE" ]] || \
    die "NapCat adapter mode resolved to unsafe image: ${resolved_napcat_image:-unknown}"
fi

log "pulling runtime images"
compose pull

log "starting GsCore"
compose up -d gscore

log "waiting for the persistent GsCore Python environment"
venv_ready=0
for ((attempt = 1; attempt <= 60; attempt++)); do
  if compose exec -T gscore test -x /venv/bin/python >/dev/null 2>&1; then
    venv_ready=1
    break
  fi
  sleep 2
done
if (( ! venv_ready )); then
  compose logs --tail=100 gscore || true
  die "GsCore did not create /venv/bin/python within 120 seconds"
fi

if ((INSTALL_WUWA)); then
  log "cloning or updating the Wuthering Waves plugin suite"
  compose --profile init run --rm gscore-plugin-init
fi

if ((INSTALL_WUWA_DEPS)); then
  log "installing Wuthering Waves extra dependencies and Chromium"
  compose --profile init run --rm gscore-xwuid-deps-init
fi

if [[ "$ADAPTER_KIND" == "astrbot" ]]; then
  log "installing the AstrBot GScore adapter"
  compose --profile init run --rm astrbot-plugin-init
else
  log "installing the NapCat GScore adapter"
  compose --profile init run --rm napcat-gscore-adapter-init
fi

log "starting selected services"
compose up -d
if ((INSTALL_WUWA || INSTALL_WUWA_DEPS)); then
  compose restart gscore
fi
compose ps

cat <<EOF

安装完成。

WebUI：
  GsCore: http://${BIND_IP}:${GSCORE_PORT}/app/
  NapCat: http://${BIND_IP}:${NAPCAT_WEBUI_PORT}
EOF
if [[ "$MODE" != "napcat" ]]; then
  printf '  AstrBot: http://%s:%s\n' "$BIND_IP" "$ASTRBOT_WEBUI_PORT"
fi

cat <<EOF

接下来仍需手动完成：
  1. 在 NapCat WebUI 修改密码并扫码登录 QQ。
  2. 在 GsCore WebUI 注册、设置管理员和 WS_TOKEN。
EOF
if [[ "$ADAPTER_KIND" == "astrbot" ]]; then
  cat <<'EOF'
  3. 在 AstrBot 启用 aiocqhttp/OneBot 平台和 GScore 适配器。
  4. AstrBot GScore 适配器的 IP 填写 gscore、PORT 填写 8765，并同步 WS_TOKEN。
EOF
elif [[ "$MODE" == "hybrid" ]]; then
  cat <<'EOF'
  3. 在 NapCat 启用 GScore 适配器，地址填写 ws://gscore:8765。
  4. 在 AstrBot 配置 OneBot 平台，并让 LLM 忽略 GScore 指令前缀，避免重复回复。
EOF
else
  cat <<'EOF'
  3. 在 NapCat 启用 GScore 适配器，地址填写 ws://gscore:8765，并同步 WS_TOKEN。
EOF
fi

printf '\n管理环境文件：%s\n' "$ENV_FILE"
printf '查看状态命令：'
printf ' %q' "${COMPOSE[@]}" ps
printf '\n'
