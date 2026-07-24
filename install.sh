#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly STATE_DIR="${NAG_INSTALL_STATE_DIR:-${SCRIPT_DIR}/.installer}"
readonly DOCKER_BIN="${NAG_DOCKER_BIN:-docker}"
readonly NAPCAT_COMPAT_IMAGE="mlikiowa/napcat-docker:v4.18.5"
readonly NAPCAT_ADAPTER_LATEST_URL="https://github.com/xiowo/napcat-plugin-gscore-adapter/releases/latest/download/napcat-plugin-gscore-adapter.zip"
readonly BOTSHEPHERD_IMAGE_DEFAULT="ghcr.io/gufei233/botshepherd:v1.2.1-docker.1"
readonly GSCORE_QQOFFICIAL_COMMIT="2d582f6478a0c0d94aa31d7151c0acabce65ea21"

MODE=""
ASSUME_YES=0
DRY_RUN=0
INSTALL_WUWA=1
INSTALL_WUWA_DEPS=1
FIXED_MAC=1
USE_CNB_MIRRORS=0
USE_BOTSHEPHERD=0
NAPCAT_MASTER_QQ_OVERRIDE=""
NAPCAT_ACCOUNT_OVERRIDE=""

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
                  guided           Interactive component-based installer
                  astrbot         NapCat + AstrBot + GsCore, AstrBot adapter
                  hybrid          NapCat + AstrBot + GsCore, NapCat adapter
                  napcat          NapCat + GsCore, NapCat adapter
                  nonebot         NapCat + NoneBot + GsCore, NoneBot adapter
                  nonebot-napcat  NapCat + NoneBot + GsCore, NapCat adapter
                  qqofficial-nonebot
                                  QQ Official + NoneBot QQ adapter + GsCore
                  qqofficial-direct
                                  QQ Official + gscore-qqofficial + GsCore
                  botshepherd-ports
                                  Manage host port mappings for an existing
                                  BotShepherd deployment
  --botshepherd
                Add BotShepherd between NapCat and AstrBot/NoneBot in modes
                that include one of those frameworks
  --yes         Accept the recommended answers for optional questions
  --master-qq QQ
                Master QQ for GsCore and the NapCat GScore adapter. Separate
                multiple accounts with commas.
  --bot-qq QQ   QQ account used by NapCat. Persist it for quick login after
                rebuilding the container.
  --dry-run     Print the selected plan without changing the host
  -h, --help    Show this help

The installer stores its private Compose environment under .installer/.
QQ Official credentials can be supplied through QQ_APP_ID, QQ_APP_SECRET, and
QQ_TOKEN (NoneBot route only) for unattended installation.
Personal QQ login and GsCore administrator registration remain manual WebUI steps.
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
    --master-qq)
      (($# >= 2)) || die "--master-qq requires a value"
      NAPCAT_MASTER_QQ_OVERRIDE="$2"
      shift 2
      ;;
    --bot-qq)
      (($# >= 2)) || die "--bot-qq requires a value"
      NAPCAT_ACCOUNT_OVERRIDE="$2"
      shift 2
      ;;
    --botshepherd)
      USE_BOTSHEPHERD=1
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
  MODE="guided"
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

detect_napcat_account() {
  local data_root="$1"
  local path
  local filename
  local account

  for path in \
    "$data_root"/napcat/config/onebot11_*.json \
    "$data_root"/napcat/config/napcat_[0-9]*.json; do
    [[ -f "$path" ]] || continue
    filename="${path##*/}"
    account="${filename%.json}"
    account="${account#onebot11_}"
    account="${account#napcat_}"
    if [[ "$account" =~ ^[1-9][0-9]{4,11}$ ]]; then
      printf '%s' "$account"
      return 0
    fi
  done

  return 1
}

parse_port_range() {
  local value="$1"

  if [[ "$value" =~ ^([0-9]+)(-([0-9]+))?$ ]]; then
    RANGE_START="${BASH_REMATCH[1]}"
    RANGE_END="${BASH_REMATCH[3]:-${BASH_REMATCH[1]}}"
  else
    return 1
  fi

  validate_port port "$RANGE_START"
  validate_port port "$RANGE_END"
  ((10#$RANGE_START <= 10#$RANGE_END)) || die "port range start must not exceed its end"
  ((10#$RANGE_END - 10#$RANGE_START < 100)) || \
    die "a single managed port range may contain at most 100 ports"
}

port_ranges_overlap() {
  local first="$1"
  local second="$2"
  local first_start first_end second_start second_end

  parse_port_range "$first"
  first_start="$RANGE_START"
  first_end="$RANGE_END"
  parse_port_range "$second"
  second_start="$RANGE_START"
  second_end="$RANGE_END"

  ((10#$first_start <= 10#$second_end && 10#$second_start <= 10#$first_end))
}

choose_botshepherd_env_file() {
  local candidates=()
  local candidate
  local choice

  for candidate in \
    "${STATE_DIR}/guided.env" \
    "${STATE_DIR}/astrbot-botshepherd.env" \
    "${STATE_DIR}/hybrid-botshepherd.env" \
    "${STATE_DIR}/nonebot-botshepherd.env" \
    "${STATE_DIR}/nonebot-napcat-botshepherd.env"; do
    [[ -f "$candidate" ]] || continue
    if [[ "$(basename "$candidate")" == "guided.env" \
      && "$(env_value BOTSHEPHERD_ENABLED "$candidate")" != "1" ]]; then
      continue
    fi
    candidates+=("$candidate")
  done

  ((${#candidates[@]} > 0)) || \
    die "no BotShepherd installer environment found; first install an AstrBot or NoneBot route with BotShepherd enabled"

  if ((${#candidates[@]} == 1)); then
    MANAGED_ENV_FILE="${candidates[0]}"
    return
  fi

  printf '\n检测到多个 BotShepherd 安装环境：\n'
  for ((choice = 0; choice < ${#candidates[@]}; choice++)); do
    printf '  %d) %s\n' "$((choice + 1))" "$(basename "${candidates[$choice]}")"
  done

  while true; do
    read -r -p "请选择当前正在使用的环境: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] \
      && ((10#$choice >= 1 && 10#$choice <= ${#candidates[@]})); then
      MANAGED_ENV_FILE="${candidates[$((10#$choice - 1))]}"
      return
    fi
    warn "请输入有效选项"
  done
}

write_botshepherd_ports_override() {
  local temporary="${BOTSHEPHERD_PORTS_OVERRIDE}.tmp"
  local entry bind_ip port_spec

  if [[ -s "$BOTSHEPHERD_PORTS_STATE" ]]; then
    {
      printf 'services:\n'
      printf '  botshepherd:\n'
      printf '    ports:\n'
      while IFS='|' read -r bind_ip port_spec; do
        [[ -n "$bind_ip" && -n "$port_spec" ]] || continue
        printf '      - "%s:%s:%s"\n' "$bind_ip" "$port_spec" "$port_spec"
      done <"$BOTSHEPHERD_PORTS_STATE"
    } >"$temporary"
  else
    {
      printf 'services:\n'
      printf '  botshepherd: {}\n'
    } >"$temporary"
  fi

  mv -f "$temporary" "$BOTSHEPHERD_PORTS_OVERRIDE"
  chmod 600 "$BOTSHEPHERD_PORTS_OVERRIDE"
}

show_botshepherd_port_mappings() {
  local index=0
  local bind_ip port_spec

  printf '\n当前由安装器管理的 BotShepherd 端口映射：\n'
  if [[ ! -s "$BOTSHEPHERD_PORTS_STATE" ]]; then
    printf '  （无）\n'
    return
  fi

  while IFS='|' read -r bind_ip port_spec; do
    [[ -n "$bind_ip" && -n "$port_spec" ]] || continue
    index=$((index + 1))
    printf '  %d) %s:%s -> botshepherd:%s\n' \
      "$index" "$bind_ip" "$port_spec" "$port_spec"
  done <"$BOTSHEPHERD_PORTS_STATE"
}

apply_botshepherd_port_mappings() {
  local base_compose
  local botshepherd_compose
  local managed_name
  local compose

  managed_name="$(basename "$MANAGED_ENV_FILE")"
  if [[ "$managed_name" == "guided.env" ]]; then
    base_compose="${SCRIPT_DIR}/docker-compose.guided.yml"
    botshepherd_compose=""
  elif [[ "$managed_name" == nonebot-* ]]; then
    base_compose="${SCRIPT_DIR}/docker-compose.nonebot.yml"
    botshepherd_compose="${SCRIPT_DIR}/docker-compose.botshepherd-nonebot.yml"
  else
    base_compose="${SCRIPT_DIR}/docker-compose.yml"
    botshepherd_compose="${SCRIPT_DIR}/docker-compose.botshepherd.yml"
  fi

  compose=(
    "$DOCKER_BIN" compose
    --project-directory "$SCRIPT_DIR"
    --env-file "$MANAGED_ENV_FILE"
    -p nag
    -f "$base_compose"
  )
  [[ -z "$botshepherd_compose" ]] || compose+=(-f "$botshepherd_compose")
  compose+=(-f "$BOTSHEPHERD_PORTS_OVERRIDE")

  write_botshepherd_ports_override
  "${compose[@]}" config --quiet
  log "recreating only nag-botshepherd to apply port mappings"
  "${compose[@]}" up -d --no-deps --force-recreate botshepherd
}

add_botshepherd_port_mapping() {
  local bind_ip port_spec
  local selected_start
  local existing_bind existing_spec
  local reserved_name reserved_port
  local reserved_ports=()

  read -r -p "宿主机监听地址 [127.0.0.1]: " bind_ip
  bind_ip="${bind_ip:-127.0.0.1}"
  case "$bind_ip" in
    127.0.0.1|0.0.0.0) ;;
    *) die "binding address must be 127.0.0.1 or 0.0.0.0" ;;
  esac
  if [[ "$bind_ip" == "0.0.0.0" ]]; then
    warn "此映射将监听所有网络接口；请同时配置防火墙或安全组"
  fi

  while true; do
    read -r -p "端口或端口范围（例如 2537 或 2537-2547）: " port_spec
    if parse_port_range "$port_spec"; then
      selected_start="$RANGE_START"
      break
    fi
    warn "请输入有效端口或端口范围"
  done

  reserved_ports+=(
    "GsCore|$(env_value GSCORE_PORT "$MANAGED_ENV_FILE")"
    "AstrBot|$(env_value ASTRBOT_WEBUI_PORT "$MANAGED_ENV_FILE")"
    "NapCat|$(env_value NAPCAT_WEBUI_PORT "$MANAGED_ENV_FILE")"
    "BotShepherd WebUI|$(env_value BOTSHEPHERD_WEBUI_PORT "$MANAGED_ENV_FILE")"
  )
  for reserved_name in "${reserved_ports[@]}"; do
    reserved_port="${reserved_name#*|}"
    reserved_name="${reserved_name%%|*}"
    [[ -n "$reserved_port" ]] || continue
    if port_ranges_overlap "$port_spec" "$reserved_port"; then
      die "$port_spec conflicts with the ${reserved_name} host port ${reserved_port}"
    fi
  done

  if [[ -s "$BOTSHEPHERD_PORTS_STATE" ]]; then
    while IFS='|' read -r existing_bind existing_spec; do
      [[ -n "$existing_spec" ]] || continue
      if port_ranges_overlap "$port_spec" "$existing_spec"; then
        die "$port_spec overlaps an existing managed mapping: ${existing_bind}:${existing_spec}"
      fi
    done <"$BOTSHEPHERD_PORTS_STATE"
  fi

  printf '%s|%s\n' "$bind_ip" "$port_spec" >>"$BOTSHEPHERD_PORTS_STATE"
  sort -u -o "$BOTSHEPHERD_PORTS_STATE" "$BOTSHEPHERD_PORTS_STATE"
  chmod 600 "$BOTSHEPHERD_PORTS_STATE"
  apply_botshepherd_port_mappings

  cat <<EOF

映射已建立：${bind_ip}:${port_spec} -> botshepherd:${port_spec}

请在 BotShepherd WebUI 中为每个实际使用的端口创建独立连接配置，例如：
  客户端端点：ws://0.0.0.0:${selected_start}/OneBotv11

如果下游 NoneBot 运行在同一宿主机，请把目标端点填写为：
  ws://host.docker.internal:<NoneBot端口>/<WebSocket路径>
EOF
}

remove_botshepherd_port_mapping() {
  local mappings=()
  local selection
  local temporary="${BOTSHEPHERD_PORTS_STATE}.tmp"

  [[ -s "$BOTSHEPHERD_PORTS_STATE" ]] || {
    warn "当前没有由安装器管理的端口映射"
    return
  }

  mapfile -t mappings <"$BOTSHEPHERD_PORTS_STATE"
  show_botshepherd_port_mappings
  while true; do
    read -r -p "请输入要删除的序号: " selection
    if [[ "$selection" =~ ^[0-9]+$ ]] \
      && ((10#$selection >= 1 && 10#$selection <= ${#mappings[@]})); then
      break
    fi
    warn "请输入有效序号"
  done

  : >"$temporary"
  for ((index = 0; index < ${#mappings[@]}; index++)); do
    ((index == 10#$selection - 1)) || printf '%s\n' "${mappings[$index]}" >>"$temporary"
  done
  mv -f "$temporary" "$BOTSHEPHERD_PORTS_STATE"
  chmod 600 "$BOTSHEPHERD_PORTS_STATE"
  apply_botshepherd_port_mappings
  log "port mapping removed"
}

manage_botshepherd_ports() {
  local action

  [[ -t 0 ]] || die "BotShepherd port management requires an interactive terminal"
  (( ! DRY_RUN )) || die "--dry-run is not supported with botshepherd-ports mode"
  command -v "$DOCKER_BIN" >/dev/null 2>&1 || die "Docker is not installed"
  "$DOCKER_BIN" compose version >/dev/null 2>&1 || die "Docker Compose V2 is required"
  "$DOCKER_BIN" info >/dev/null 2>&1 || die "cannot access the Docker daemon"
  "$DOCKER_BIN" inspect nag-botshepherd >/dev/null 2>&1 || \
    die "nag-botshepherd does not exist; first install an AstrBot or NoneBot route with BotShepherd enabled"

  choose_botshepherd_env_file
  BOTSHEPHERD_PORTS_STATE="${STATE_DIR}/botshepherd-ports.list"
  BOTSHEPHERD_PORTS_OVERRIDE="${STATE_DIR}/docker-compose.botshepherd-ports.yml"
  mkdir -p "$STATE_DIR"
  touch "$BOTSHEPHERD_PORTS_STATE"
  chmod 600 "$BOTSHEPHERD_PORTS_STATE"

  while true; do
    show_botshepherd_port_mappings
    cat <<'EOF'

请选择操作：
  1) 新增端口或端口范围
  2) 删除端口映射
  3) 重新应用当前映射
  4) 退出
EOF
    read -r -p "请输入 1、2、3 或 4: " action
    case "$action" in
      1) add_botshepherd_port_mapping ;;
      2) remove_botshepherd_port_mapping ;;
      3) apply_botshepherd_port_mappings ;;
      4) return ;;
      *) warn "请输入有效选项" ;;
    esac
  done
}

install_qqofficial() {
  local route_kind="$1"
  local route_label
  local env_file
  local data_root
  local bind_ip
  local gscore_port
  local qq_app_id
  local qq_app_secret
  local qq_token
  local qq_admin_ids
  local qq_is_sandbox
  local qq_api_base
  local gscore_ws_token
  local register_code=""
  local venv_ready=0
  local nonebot_ready=0
  local qq_gateway_ready=0
  local gscore_adapter_ready=0
  local connection_check_since=""
  local attempt
  local tmp_env
  local input_app_id="${QQ_APP_ID:-}"
  local input_app_secret="${QQ_APP_SECRET:-}"
  local input_token="${QQ_TOKEN:-}"
  local input_admin_ids="${QQ_ADMIN_IDS:-}"
  local input_is_sandbox="${QQ_IS_SANDBOX:-}"
  local input_data_root="${DATA_ROOT:-}"
  local input_bind_ip="${BIND_IP:-}"
  local input_gscore_port="${GSCORE_PORT:-}"

  (( ! USE_BOTSHEPHERD )) || \
    die "--botshepherd is not used by QQ Official routes"

  if [[ "$route_kind" == "nonebot" ]]; then
    route_label="QQ 官方机器人 + NoneBot QQ 官方适配器 + GsCore"
    env_file="${STATE_DIR}/qqofficial-nonebot.env"
  else
    route_label="QQ 官方机器人 + gscore-qqofficial + GsCore（轻量版）"
    env_file="${STATE_DIR}/qqofficial-direct.env"
  fi

  data_root="${input_data_root:-$(env_value DATA_ROOT "$env_file" || true)}"
  data_root="${data_root:-/opt/nag-qqofficial-data}"
  data_root="$(prompt_value "持久化数据目录" "$data_root")"
  bind_ip="${input_bind_ip:-$(env_value BIND_IP "$env_file" || true)}"
  bind_ip="${bind_ip:-127.0.0.1}"
  bind_ip="$(prompt_value "WebUI 绑定地址" "$bind_ip")"
  gscore_port="${input_gscore_port:-$(env_value GSCORE_PORT "$env_file" || true)}"
  gscore_port="${gscore_port:-8765}"
  gscore_port="$(prompt_value "GsCore WebUI 端口" "$gscore_port")"

  qq_app_id="${input_app_id:-$(env_value QQ_APP_ID "$env_file" || true)}"
  qq_app_secret="${input_app_secret:-$(env_value QQ_APP_SECRET "$env_file" || true)}"
  qq_token="${input_token:-$(env_value QQ_TOKEN "$env_file" || true)}"
  qq_admin_ids="${input_admin_ids:-$(env_value QQ_ADMIN_IDS "$env_file" || true)}"

  if ((DRY_RUN && ASSUME_YES)); then
    qq_app_id="${qq_app_id:-dry-run-appid}"
    qq_app_secret="${qq_app_secret:-dry-run-secret}"
    if [[ "$route_kind" == "nonebot" ]]; then
      qq_token="${qq_token:-dry-run-token}"
    fi
  else
    qq_app_id="$(prompt_value "QQ 官方机器人 AppID" "$qq_app_id")"
    qq_app_secret="$(prompt_value "QQ 官方机器人 AppSecret" "$qq_app_secret")"
    if [[ "$route_kind" == "nonebot" ]]; then
      qq_token="$(prompt_value "QQ 官方机器人 Token" "$qq_token")"
    fi
  fi

  [[ -n "$qq_app_id" ]] || \
    die "QQ_APP_ID is required (set it in the environment for --yes mode)"
  [[ -n "$qq_app_secret" ]] || \
    die "QQ_APP_SECRET is required (set it in the environment for --yes mode)"
  if [[ "$route_kind" == "nonebot" ]]; then
    [[ -n "$qq_token" ]] || \
      die "QQ_TOKEN is required by the NoneBot QQ adapter"
  fi

  if (( ! ASSUME_YES )); then
    qq_admin_ids="$(
      prompt_value \
        "管理员 OpenID（不是 QQ 号，可留空，多个用英文逗号分隔）" \
        "$qq_admin_ids"
    )"
  fi
  qq_admin_ids="${qq_admin_ids//[[:space:]]/}"

  qq_is_sandbox="${input_is_sandbox:-$(env_value QQ_IS_SANDBOX "$env_file" || true)}"
  qq_is_sandbox="${qq_is_sandbox:-false}"
  if (( ! ASSUME_YES )); then
    if prompt_yes_no "使用 QQ 开放平台沙盒环境" n; then
      qq_is_sandbox=true
    else
      qq_is_sandbox=false
    fi
  fi
  if [[ "$qq_is_sandbox" == "true" ]]; then
    qq_api_base="https://sandbox.api.sgroup.qq.com"
  else
    qq_api_base="https://api.sgroup.qq.com"
  fi

  [[ "$data_root" == /* ]] || die "DATA_ROOT must be an absolute path"
  case "$bind_ip" in
    127.0.0.1|0.0.0.0) ;;
    *) die "BIND_IP must be 127.0.0.1 or 0.0.0.0" ;;
  esac
  validate_port GSCORE_PORT "$gscore_port"
  [[ "$qq_app_id" =~ ^[A-Za-z0-9._~-]+$ ]] || \
    die "QQ_APP_ID contains unsupported characters"
  [[ "$qq_app_secret" =~ ^[A-Za-z0-9._~-]+$ ]] || \
    die "QQ_APP_SECRET contains unsupported characters"
  if [[ -n "$qq_token" && ! "$qq_token" =~ ^[A-Za-z0-9._~-]+$ ]]; then
    die "QQ_TOKEN contains unsupported characters"
  fi
  if [[ -n "$qq_admin_ids" \
    && ! "$qq_admin_ids" =~ ^[A-Za-z0-9._~-]+(,[A-Za-z0-9._~-]+)*$ ]]; then
    die "QQ_ADMIN_IDS must contain comma-separated OpenIDs"
  fi

  if prompt_yes_no "安装鸣潮插件套件（XutheringWavesUID、RoverSign、ScoreEcho）" y; then
    INSTALL_WUWA=1
    if prompt_yes_no "安装 Playwright、OpenCV、字体、拼音和 Chromium 等额外依赖" y; then
      INSTALL_WUWA_DEPS=1
    else
      INSTALL_WUWA_DEPS=0
    fi
  else
    INSTALL_WUWA=0
    INSTALL_WUWA_DEPS=0
  fi

  if ((INSTALL_WUWA)) \
    && prompt_yes_no "使用 CNB 镜像克隆鸣潮插件（适合 GitHub 访问较慢时）" n; then
    XUTHERINGWAVESUID_REPO="https://cnb.cool/gscore-mirror/XutheringWavesUID"
    ROVERSIGN_REPO="https://cnb.cool/gscore-mirror/RoverSign"
    SCOREECHO_REPO="https://cnb.cool/gscore-mirror/ScoreEcho"
  else
    XUTHERINGWAVESUID_REPO="https://github.com/Loping151/XutheringWavesUID.git"
    ROVERSIGN_REPO="https://github.com/Loping151/RoverSign.git"
    SCOREECHO_REPO="https://github.com/Loping151/ScoreEcho.git"
  fi

  gscore_ws_token="$(env_value GSCORE_WS_TOKEN "$env_file" || true)"
  if [[ -z "$gscore_ws_token" ]]; then
    command -v od >/dev/null 2>&1 || die "od is required to generate GSCORE_WS_TOKEN"
    gscore_ws_token="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
  fi

  for pair in \
    "DATA_ROOT=$data_root" "BIND_IP=$bind_ip" "GSCORE_PORT=$gscore_port" \
    "QQ_APP_ID=$qq_app_id" "QQ_APP_SECRET=$qq_app_secret" \
    "QQ_TOKEN=$qq_token" "QQ_ADMIN_IDS=$qq_admin_ids" \
    "GSCORE_WS_TOKEN=$gscore_ws_token"; do
    validate_single_line "${pair%%=*}" "${pair#*=}"
  done

  cat <<EOF

部署方案：$route_label
数据目录：$data_root
GsCore WebUI：http://${bind_ip}:${gscore_port}/app/
QQ 环境：$([[ "$qq_is_sandbox" == "true" ]] && printf 沙盒 || printf 正式)
管理员 OpenID：${qq_admin_ids:-未填写，可从首次消息日志获取后重新运行脚本}
鸣潮插件：$([[ $INSTALL_WUWA -eq 1 ]] && printf 安装 || printf 跳过)
额外依赖：$([[ $INSTALL_WUWA_DEPS -eq 1 ]] && printf 安装 || printf 跳过)
EOF
  if [[ "$route_kind" == "nonebot" ]]; then
    printf '连接链路：QQ 官方 Gateway <-> NoneBot adapter-qq <-> GenshinUID <-> GsCore\n\n'
  else
    printf '连接链路：QQ 官方 Gateway <-> gscore-qqofficial <-> GsCore\n'
    printf '上游版本：gscore-qqofficial 0.7.0 (%s)\n\n' "${GSCORE_QQOFFICIAL_COMMIT:0:7}"
  fi

  if ((DRY_RUN)); then
    log "dry-run completed; credentials were not written and the host was not changed"
    return
  fi
  if ! prompt_yes_no "确认开始安装" y; then
    log "installation cancelled"
    return
  fi

  command -v "$DOCKER_BIN" >/dev/null 2>&1 || die "Docker is not installed"
  "$DOCKER_BIN" compose version >/dev/null 2>&1 || die "Docker Compose V2 is required"
  "$DOCKER_BIN" info >/dev/null 2>&1 || \
    die "cannot access the Docker daemon; check service status and user permissions"

  mkdir -p "$STATE_DIR"
  tmp_env="${env_file}.tmp"
  cat >"$tmp_env" <<EOF
# Generated by install.sh for mode: qqofficial-${route_kind}
DATA_ROOT=$data_root
BIND_IP=$bind_ip
TZ=Asia/Shanghai
GSCORE_PORT=$gscore_port
GSCORE_IMAGE=docker.cnb.cool/gscore-mirror/gsuid_core:latest
NONEBOT_IMAGE=nag-nonebot:local
GSCORE_QQOFFICIAL_IMAGE=nag-gscore-qqofficial:0.7.0-2d582f6
GSCORE_QQOFFICIAL_BUILD_CONTEXT=https://github.com/An-Sun110/gscore-qqofficial.git#$GSCORE_QQOFFICIAL_COMMIT
QQ_APP_ID=$qq_app_id
QQ_APP_SECRET=$qq_app_secret
QQ_TOKEN=$qq_token
QQ_ADMIN_IDS=$qq_admin_ids
NAPCAT_MASTER_QQ=$qq_admin_ids
QQ_IS_SANDBOX=$qq_is_sandbox
QQ_API_BASE=$qq_api_base
GSCORE_WS_TOKEN=$gscore_ws_token
XUTHERINGWAVESUID_REPO=$XUTHERINGWAVESUID_REPO
ROVERSIGN_REPO=$ROVERSIGN_REPO
SCOREECHO_REPO=$SCOREECHO_REPO
GSCORE_PYTHON_INDEX=https://pypi.org/simple/
UV_NO_CONFIG=0
PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
GSCORE_XWUID_PYTHON_PACKAGES=playwright opencv-python fonttools pypinyin
EOF
  mv -f "$tmp_env" "$env_file"
  chmod 600 "$env_file"

  local data_dirs=(
    "$data_root/gscore/data"
    "$data_root/gscore/plugins"
  )
  if [[ "$route_kind" == "nonebot" ]]; then
    data_dirs+=("$data_root/nonebot/data" "$data_root/nonebot/plugins")
  else
    data_dirs+=("$data_root/gscore-qqofficial")
  fi
  if ! mkdir -p "${data_dirs[@]}" 2>/dev/null; then
    command -v sudo >/dev/null 2>&1 || die "cannot create $data_root and sudo is unavailable"
    sudo install -d -m 0755 -o "$(id -u)" -g "$(id -g)" "${data_dirs[@]}"
  fi
  if [[ "$route_kind" == "direct" ]]; then
    if ! chown 10001:10001 "$data_root/gscore-qqofficial" 2>/dev/null; then
      command -v sudo >/dev/null 2>&1 || \
        die "cannot assign the gscore-qqofficial data directory to container UID 10001"
      sudo chown 10001:10001 "$data_root/gscore-qqofficial"
    fi
    chmod 0700 "$data_root/gscore-qqofficial"
  fi

  local official_compose_cmd=(
    "$DOCKER_BIN" compose
    --project-directory "$SCRIPT_DIR"
    --env-file "$env_file"
    -p nag-qqofficial
    -f "${SCRIPT_DIR}/docker-compose.qqofficial.yml"
  )
  official_compose() {
    "${official_compose_cmd[@]}" "$@"
  }
  official_finalize_gscore_plugins() {
    local finalize_attempt

    if ((INSTALL_WUWA || INSTALL_WUWA_DEPS)); then
      log "stopping GsCore after the base services have started"
      official_compose stop gscore
    fi
    if ((INSTALL_WUWA)); then
      log "cloning or updating the Wuthering Waves plugin suite"
      official_compose --profile init run --rm gscore-plugin-init
    fi
    if ((INSTALL_WUWA_DEPS)); then
      log "installing Wuthering Waves dependencies and Chromium"
      official_compose --profile init run --rm gscore-xwuid-deps-init
    fi
    if ((INSTALL_WUWA || INSTALL_WUWA_DEPS)); then
      log "starting GsCore with the completed plugin environment"
      official_compose up -d gscore
      for ((finalize_attempt = 1; finalize_attempt <= 90; finalize_attempt++)); do
        if official_compose exec -T gscore /venv/bin/python -c \
          'from urllib.request import urlopen; r=urlopen("http://127.0.0.1:8765/app/",timeout=3); assert r.status == 200' \
          >/dev/null 2>&1; then
          return
        fi
        sleep 2
      done
      official_compose logs --tail=120 gscore || true
      die "GsCore WebUI did not become ready after plugin initialization"
    fi
  }

  official_compose config --quiet
  log "pulling GsCore image"
  official_compose pull gscore
  if [[ "$route_kind" == "nonebot" ]]; then
    log "building NoneBot with nonebot-adapter-qq 1.7.1"
    official_compose build nonebot
  else
    log "building gscore-qqofficial from pinned upstream commit"
    official_compose build gscore-qqofficial
  fi

  log "starting GsCore"
  official_compose up -d gscore
  for ((attempt = 1; attempt <= 60; attempt++)); do
    if official_compose exec -T gscore sh -c \
      'test -x /venv/bin/python && test -f /gsuid_core/data/config.json' \
      >/dev/null 2>&1; then
      venv_ready=1
      break
    fi
    sleep 2
  done
  if (( ! venv_ready )); then
    official_compose logs --tail=100 gscore || true
    die "GsCore did not initialize within 120 seconds"
  fi

  log "configuring GsCore WebSocket token and administrator OpenIDs"
  official_compose exec -T gscore /venv/bin/python - \
    "$gscore_ws_token" "$qq_admin_ids" <<'PY'
import json
import sys
from pathlib import Path

config_path = Path("/gsuid_core/data/config.json")
config = json.loads(config_path.read_text(encoding="utf-8-sig"))
config["WS_TOKEN"] = sys.argv[1]
if sys.argv[2]:
    config["masters"] = list(dict.fromkeys(sys.argv[2].split(",")))
config_path.write_text(
    json.dumps(config, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
PY
  official_compose restart gscore
  log "waiting for the base GsCore WebUI"
  for ((attempt = 1; attempt <= 90; attempt++)); do
    if official_compose exec -T gscore /venv/bin/python -c \
      'from urllib.request import urlopen; r=urlopen("http://127.0.0.1:8765/app/",timeout=3); assert r.status == 200' \
      >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  if ((attempt > 90)); then
    official_compose logs --tail=120 gscore || true
    die "GsCore WebUI did not become ready after base configuration"
  fi

  if [[ "$route_kind" == "nonebot" ]]; then
    official_compose stop gscore-qqofficial >/dev/null 2>&1 || true
    log "starting NoneBot QQ Official adapter"
    connection_check_since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    official_compose up -d --no-deps --force-recreate nonebot
    for ((attempt = 1; attempt <= 60; attempt++)); do
      if official_compose exec -T nonebot python -c \
        'import socket; s=socket.create_connection(("127.0.0.1",8080),3); s.close()' \
        >/dev/null 2>&1; then
        nonebot_ready=1
        break
      fi
      sleep 2
    done
    if (( ! nonebot_ready )); then
      official_compose logs --tail=120 nonebot || true
      die "NoneBot QQ Official adapter did not become healthy within 120 seconds"
    fi
    official_finalize_gscore_plugins
    for ((attempt = 1; attempt <= 60; attempt++)); do
      local nonebot_logs
      nonebot_logs="$(
        official_compose logs \
          --since "$connection_check_since" --no-color nonebot 2>/dev/null \
          || true
      )"
      if [[ "$nonebot_logs" == *"Bot "*" connected"* ]]; then
        qq_gateway_ready=1
      fi
      if [[ "$nonebot_logs" == *"与[gsuid-core]成功连接"* ]]; then
        gscore_adapter_ready=1
      fi
      if ((qq_gateway_ready && gscore_adapter_ready)); then
        break
      fi
      if [[ "$nonebot_logs" == *"code=11298"* \
        || "$nonebot_logs" == *"接口访问源IP不在白名单"* ]]; then
        die "QQ rejected the server IP (11298). Add this server's public IP to the bot's IP whitelist, then rerun the installer."
      fi
      sleep 2
    done
    if (( ! qq_gateway_ready )); then
      official_compose logs --tail=120 nonebot || true
      die "NoneBot started, but the QQ Official Gateway did not connect within 120 seconds"
    fi
    if (( ! gscore_adapter_ready )); then
      official_compose logs --tail=120 nonebot || true
      die "NoneBot connected to QQ, but GenshinUID did not connect to GsCore within 120 seconds"
    fi
  else
    official_compose stop nonebot >/dev/null 2>&1 || true
    log "starting gscore-qqofficial"
    connection_check_since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    official_compose up -d --no-deps --force-recreate gscore-qqofficial
    official_finalize_gscore_plugins
    for ((attempt = 1; attempt <= 60; attempt++)); do
      local adapter_logs
      adapter_logs="$(
        official_compose logs \
          --since "$connection_check_since" --no-color gscore-qqofficial \
          2>/dev/null || true
      )"
      if [[ "$adapter_logs" == *"已连接 QQ Gateway"* \
        && "$adapter_logs" == *"已连接 gsuid_core"* ]]; then
        break
      fi
      if [[ "$adapter_logs" == *"11298"* \
        || "$adapter_logs" == *"接口访问源IP不在白名单"* ]]; then
        die "QQ rejected the server IP (11298). Add this server's public IP to the bot's IP whitelist, then rerun the installer."
      fi
      sleep 2
    done
    if ((attempt > 60)); then
      official_compose logs --tail=100 gscore-qqofficial || true
      die "gscore-qqofficial did not connect to both QQ Gateway and GsCore within 120 seconds"
    fi
  fi

  register_code="$(
    official_compose exec -T gscore /venv/bin/python -c '
import json
from pathlib import Path
config = json.loads(Path("/gsuid_core/data/config.json").read_text(encoding="utf-8-sig"))
print(config.get("REGISTER_CODE", ""), end="")
' 2>/dev/null || true
  )"
  official_compose ps

  cat <<EOF

安装完成。

GsCore WebUI：http://${bind_ip}:${gscore_port}/app/
GsCore 注册码：${register_code:-未读取到，请查看 $data_root/gscore/data/config.json}
QQ 官方凭据：已保存到 $env_file（权限 600，未写入仓库）
EOF
  if [[ -z "$qq_admin_ids" ]]; then
    cat <<'EOF'

管理员 OpenID 当前为空。先向机器人发送一条消息，从适配器日志中取得
user_openid/member_openid 后重新运行同一路线，即可同步写入适配器与 GsCore。
EOF
  fi
}

guided_choice() {
  local prompt="$1"
  local min="$2"
  local max="$3"
  local value

  while true; do
    read -r -p "$prompt" value
    if [[ "$value" =~ ^[0-9]+$ ]] \
      && ((10#$value >= min && 10#$value <= max)); then
      printf '%s' "$value"
      return
    fi
    warn "请输入 ${min}-${max} 之间的有效选项"
  done
}

guided_choice_default() {
  local prompt="$1"
  local min="$2"
  local max="$3"
  local default="$4"
  local value

  while true; do
    read -r -p "${prompt} [${default}]: " value
    value="${value:-$default}"
    if [[ "$value" =~ ^[0-9]+$ ]] \
      && ((10#$value >= min && 10#$value <= max)); then
      printf '%s' "$value"
      return
    fi
    warn "请输入 ${min}-${max} 之间的有效选项"
  done
}

guided_profile_name() {
  local use_personal="$1"
  local use_official="$2"

  if ((use_personal && use_official)); then
    printf '双通道方案'
  elif ((use_personal)); then
    printf '个人 QQ 方案'
  else
    printf 'QQ 官方机器人方案'
  fi
}

guided_render_catalog() {
  cat <<'EOF'

部署方案总览

  1) 个人 QQ 方案
     个人 QQ
        └─ [固定] NapCat
              ├─ [可自定义] GScore 处理方 ──> [共享] GsCore
              └─ [可选] AstrBot / NoneBot / BotShepherd

  2) QQ 官方机器人方案
     QQ Gateway
        └─ [可自定义] 官方适配器 ───────────> [共享] GsCore
           [固定] 不安装 NapCat

  3) 双通道方案
     同时启用方案 1 和方案 2，两条链路共用同一个 GsCore

图例：
  [固定] 始终存在  [可自定义] 可在方案内切换
  [可选] 可随时增删  [共享] 两条链路复用同一服务和数据
EOF
}

guided_render_topology() {
  local use_personal="$1"
  local use_official="$2"
  local personal_adapter="$3"
  local official_adapter="$4"
  local enable_astrbot="$5"
  local enable_nonebot="$6"
  local use_botshepherd="$7"
  local napcat_version="当前稳定版"
  local personal_handler="未启用"
  local official_handler="未启用"

  [[ "$personal_adapter" == "napcat" ]] && napcat_version="v4.18.5（自动锁定）"
  case "$personal_adapter" in
    napcat) personal_handler="NapCat GScore 插件" ;;
    nonebot) personal_handler="NoneBot GenshinUID" ;;
    astrbot) personal_handler="AstrBot GScore 适配器" ;;
  esac
  case "$official_adapter" in
    nonebot) official_handler="NoneBot adapter-qq" ;;
    direct) official_handler="gscore-qqofficial" ;;
  esac

  printf '\n当前解析后的部署流程：%s\n\n' \
    "$(guided_profile_name "$use_personal" "$use_official")"
  if ((use_personal)); then
    cat <<EOF
  个人 QQ
     └─ [固定] NapCat ${napcat_version}
EOF
    if ((use_botshepherd)) \
      && [[ "$personal_adapter" != "napcat" ]]; then
      printf '           ├─ GScore 指令 ── [可选] BotShepherd\n'
      printf '           │                    └─ [当前处理方] %s ──> [共享] GsCore\n' \
        "$personal_handler"
    else
      printf '           ├─ GScore 指令 ── [当前处理方] %s ──> [共享] GsCore\n' \
        "$personal_handler"
    fi
    if ((enable_astrbot || enable_nonebot)); then
      if ((use_botshepherd)); then
        printf '           └─ 普通消息 ── [可选] BotShepherd\n'
        if ((enable_astrbot && enable_nonebot)); then
          printf '                              ├─ %sAstrBot\n' \
            "$([[ "$personal_adapter" == "astrbot" ]] && printf '[处理方] ' || printf '[可选] ')"
          printf '                              └─ %sNoneBot\n' \
            "$([[ "$personal_adapter" == "nonebot" ]] && printf '[处理方] ' || printf '[可选] ')"
        elif ((enable_astrbot)); then
          printf '                              └─ %sAstrBot\n' \
            "$([[ "$personal_adapter" == "astrbot" ]] && printf '[处理方] ' || printf '[可选] ')"
        else
          printf '                              └─ %sNoneBot\n' \
            "$([[ "$personal_adapter" == "nonebot" ]] && printf '[处理方] ' || printf '[可选] ')"
        fi
      elif ((enable_astrbot && enable_nonebot)); then
        printf '           └─ 普通消息\n'
        printf '                ├─ %sAstrBot\n' \
          "$([[ "$personal_adapter" == "astrbot" ]] && printf '[处理方] ' || printf '[可选] ')"
        printf '                └─ %sNoneBot\n' \
          "$([[ "$personal_adapter" == "nonebot" ]] && printf '[处理方] ' || printf '[可选] ')"
      elif ((enable_astrbot)); then
        printf '           └─ 普通消息 ── %sAstrBot\n' \
          "$([[ "$personal_adapter" == "astrbot" ]] && printf '[处理方] ' || printf '[可选] ')"
      else
        printf '           └─ 普通消息 ── %sNoneBot\n' \
          "$([[ "$personal_adapter" == "nonebot" ]] && printf '[处理方] ' || printf '[可选] ')"
      fi
    else
      printf '           └─ 普通消息 ── 无额外框架\n'
    fi
  fi
  if ((use_official)); then
    cat <<EOF

  QQ 官方机器人
     └─ [当前适配器] ${official_handler} ──────────> [共享] GsCore
        [固定] 不安装 NapCat
EOF
  fi
  cat <<'EOF'

  [共享] GsCore
     └─ [可选] GsCore 游戏插件
EOF
}

guided_validate_topology() {
  local use_personal="$1"
  local use_official="$2"
  local personal_adapter="$3"
  local official_adapter="$4"
  local enable_astrbot="$5"
  local enable_nonebot="$6"
  local use_botshepherd="$7"

  ((use_personal || use_official)) || return 1
  if ((use_personal)); then
    [[ "$personal_adapter" == "napcat" \
      || "$personal_adapter" == "nonebot" \
      || "$personal_adapter" == "astrbot" ]] || return 1
    [[ "$personal_adapter" != "nonebot" || "$enable_nonebot" == "1" ]] \
      || return 1
    [[ "$personal_adapter" != "astrbot" || "$enable_astrbot" == "1" ]] \
      || return 1
    (( ! use_botshepherd || enable_astrbot || enable_nonebot)) || return 1
  else
    [[ "$personal_adapter" == "none" \
      && "$enable_astrbot" == "0" \
      && "$enable_nonebot" == "0" \
      && "$use_botshepherd" == "0" ]] || return 1
  fi
  if ((use_official)); then
    [[ "$official_adapter" == "nonebot" \
      || "$official_adapter" == "direct" ]] || return 1
  else
    [[ "$official_adapter" == "none" ]] || return 1
  fi
}

install_guided() {
  (( ! ASSUME_YES )) || \
    die "guided mode requires interactive choices; use a legacy --mode preset for unattended installation"
  [[ -t 0 ]] || die "guided mode requires an interactive terminal"

  local env_file="${STATE_DIR}/guided.env"
  local state_file="${STATE_DIR}/guided.state"
  local identity_file="${STATE_DIR}/napcat-identity.env"
  local topology_file="$env_file"
  local existing_state=0
  local incremental_mode=0
  local repair_mode=0
  local full_reconfigure=0
  local old_use_personal=0
  local old_use_official=0
  local old_personal_adapter="none"
  local old_official_adapter="none"
  local old_enable_astrbot=0
  local old_enable_nonebot=0
  local old_enable_official_nonebot=0
  local old_enable_official_direct=0
  local old_use_botshepherd=0
  local old_data_root=""
  local old_bind_ip=""
  local old_gscore_port=""
  local old_napcat_port=""
  local old_astrbot_port=""
  local old_botshepherd_port=""
  local old_personal_masters=""
  local old_napcat_account=""
  local old_napcat_mac=""
  local old_qq_app_id=""
  local old_qq_app_secret=""
  local old_qq_token=""
  local old_qq_admin_ids=""
  local old_qq_is_sandbox="false"
  local old_gscore_ws_token=""
  local old_napcat_image=""

  [[ -f "$state_file" ]] && topology_file="$state_file"
  if [[ -f "$env_file" || -f "$state_file" ]]; then
    existing_state=1
    old_data_root="$(env_value DATA_ROOT "$env_file" || true)"
    old_bind_ip="$(env_value BIND_IP "$env_file" || true)"
    old_gscore_port="$(env_value GSCORE_PORT "$env_file" || true)"
    old_napcat_port="$(env_value NAPCAT_WEBUI_PORT "$env_file" || true)"
    old_astrbot_port="$(env_value ASTRBOT_WEBUI_PORT "$env_file" || true)"
    old_botshepherd_port="$(env_value BOTSHEPHERD_WEBUI_PORT "$env_file" || true)"
    old_personal_masters="$(env_value NAPCAT_MASTER_QQ "$env_file" || true)"
    old_napcat_account="$(env_value NAPCAT_ACCOUNT "$identity_file" || true)"
    old_napcat_mac="$(env_value NAPCAT_MAC "$identity_file" || true)"
    old_qq_app_id="$(env_value QQ_APP_ID "$env_file" || true)"
    old_qq_app_secret="$(env_value QQ_APP_SECRET "$env_file" || true)"
    old_qq_token="$(env_value QQ_TOKEN "$env_file" || true)"
    old_qq_admin_ids="$(env_value QQ_ADMIN_IDS "$env_file" || true)"
    old_qq_is_sandbox="$(env_value QQ_IS_SANDBOX "$env_file" || true)"
    old_qq_is_sandbox="${old_qq_is_sandbox:-false}"
    old_gscore_ws_token="$(env_value GSCORE_WS_TOKEN "$env_file" || true)"
    old_napcat_image="$(env_value NAPCAT_IMAGE "$env_file" || true)"

    old_use_personal="$(env_value USE_PERSONAL "$topology_file" || true)"
    if [[ "$old_use_personal" != "0" && "$old_use_personal" != "1" ]]; then
      if [[ -n "$old_personal_masters" || -n "$old_napcat_account" ]]; then
        old_use_personal=1
      else
        old_use_personal=0
      fi
    fi
    old_use_official="$(env_value USE_OFFICIAL "$topology_file" || true)"
    if [[ "$old_use_official" != "0" && "$old_use_official" != "1" ]]; then
      [[ -n "$old_qq_app_id" ]] && old_use_official=1 || old_use_official=0
    fi
    old_enable_astrbot="$(env_value ENABLE_ASTRBOT "$topology_file" || true)"
    [[ "$old_enable_astrbot" == "1" ]] || old_enable_astrbot=0
    old_enable_nonebot="$(env_value ENABLE_NONEBOT "$topology_file" || true)"
    [[ "$old_enable_nonebot" == "1" ]] || old_enable_nonebot=0
    old_use_botshepherd="$(env_value BOTSHEPHERD_ENABLED "$topology_file" || true)"
    [[ "$old_use_botshepherd" == "1" ]] || old_use_botshepherd=0

    old_personal_adapter="$(env_value PERSONAL_ADAPTER "$topology_file" || true)"
    if [[ "$old_use_personal" == "1" \
      && "$old_personal_adapter" != "napcat" \
      && "$old_personal_adapter" != "nonebot" \
      && "$old_personal_adapter" != "astrbot" ]]; then
      if [[ "$(env_value ENABLE_NONEBOT_GSCORE_ADAPTER "$env_file" || true)" == "true" ]]; then
        old_personal_adapter="nonebot"
      elif [[ "$old_enable_astrbot" == "1" \
        && "$old_napcat_image" != "$NAPCAT_COMPAT_IMAGE" ]]; then
        old_personal_adapter="astrbot"
      else
        old_personal_adapter="napcat"
      fi
    elif [[ "$old_use_personal" != "1" ]]; then
      old_personal_adapter="none"
    fi

    old_official_adapter="$(env_value OFFICIAL_ADAPTER "$topology_file" || true)"
    if [[ "$old_use_official" == "1" \
      && "$old_official_adapter" != "nonebot" \
      && "$old_official_adapter" != "direct" ]]; then
      if command -v "$DOCKER_BIN" >/dev/null 2>&1 \
        && [[ "$("$DOCKER_BIN" inspect -f '{{.State.Running}}' \
          nag-nonebot-qqofficial 2>/dev/null || true)" == "true" ]]; then
        old_official_adapter="nonebot"
      elif command -v "$DOCKER_BIN" >/dev/null 2>&1 \
        && [[ "$("$DOCKER_BIN" inspect -f '{{.State.Running}}' \
          nag-gscore-qqofficial 2>/dev/null || true)" == "true" ]]; then
        old_official_adapter="direct"
      elif [[ -n "$old_qq_token" ]]; then
        old_official_adapter="nonebot"
      else
        old_official_adapter="direct"
      fi
    elif [[ "$old_use_official" != "1" ]]; then
      old_official_adapter="none"
    fi
    [[ "$old_official_adapter" == "nonebot" ]] \
      && old_enable_official_nonebot=1 || old_enable_official_nonebot=0
    [[ "$old_official_adapter" == "direct" ]] \
      && old_enable_official_direct=1 || old_enable_official_direct=0
  fi

  local use_personal=0
  local use_official=0
  local personal_adapter="none"
  local official_adapter="none"
  local enable_astrbot=0
  local enable_nonebot=0
  local enable_official_nonebot=0
  local enable_official_direct=0
  local use_botshepherd=0
  local channel_choice
  local adapter_choice
  local topology_action=""

  if ((existing_state)); then
    printf '\n检测到现有部署状态。\n'
    guided_render_topology \
      "$old_use_personal" "$old_use_official" \
      "$old_personal_adapter" "$old_official_adapter" \
      "$old_enable_astrbot" "$old_enable_nonebot" \
      "$old_use_botshepherd"
    cat <<'EOF'

请选择操作：
  1) 在当前大方案内自定义组件（推荐）
  2) 按当前拓扑修复或更新
  3) 更换大方案
EOF
    topology_action="$(guided_choice_default "请输入 1、2 或 3" 1 3 1)"
  else
    topology_action=3
  fi

  if [[ "$topology_action" == "1" ]]; then
    incremental_mode=1
    use_personal="$old_use_personal"
    use_official="$old_use_official"
    personal_adapter="$old_personal_adapter"
    official_adapter="$old_official_adapter"
    enable_astrbot="$old_enable_astrbot"
    enable_nonebot="$old_enable_nonebot"
    use_botshepherd="$old_use_botshepherd"

    if ((old_use_personal)) \
      && prompt_yes_no "切换个人 QQ 的 GScore 处理方" n; then
      cat <<'EOF'

请选择个人 QQ 的 GScore 处理方（单选）：
  1) NapCat GScore 插件（推荐）
  2) NoneBot GenshinUID
  3) AstrBot GScore 适配器
EOF
      local personal_default=1
      [[ "$old_personal_adapter" == "nonebot" ]] && personal_default=2
      [[ "$old_personal_adapter" == "astrbot" ]] && personal_default=3
      adapter_choice="$(guided_choice_default "请输入 1、2 或 3" 1 3 "$personal_default")"
      case "$adapter_choice" in
        1) personal_adapter="napcat" ;;
        2) personal_adapter="nonebot"; enable_nonebot=1 ;;
        3) personal_adapter="astrbot"; enable_astrbot=1 ;;
      esac
    fi

    if ((old_use_official)) \
      && prompt_yes_no "切换 QQ 官方机器人的接入方式" n; then
      cat <<'EOF'

请选择 QQ 官方机器人的 GScore 接入方式（单选）：
  1) gscore-qqofficial 轻量直连（推荐）
  2) NoneBot + nonebot-adapter-qq
EOF
      local official_default=1
      [[ "$old_official_adapter" == "nonebot" ]] && official_default=2
      adapter_choice="$(guided_choice_default "请输入 1 或 2" 1 2 "$official_default")"
      [[ "$adapter_choice" == "1" ]] \
        && official_adapter="direct" || official_adapter="nonebot"
    fi

    if ((use_personal)) \
      && prompt_yes_no "修改 AstrBot、NoneBot 或 BotShepherd 组件" n; then
      if [[ "$personal_adapter" == "astrbot" ]]; then
        enable_astrbot=1
        log "AstrBot 是当前 GScore 处理方，必须保留"
      elif prompt_yes_no "启用 AstrBot" "$([[ "$old_enable_astrbot" == "1" ]] && printf y || printf n)"; then
        enable_astrbot=1
      else
        enable_astrbot=0
      fi
      if [[ "$personal_adapter" == "nonebot" ]]; then
        enable_nonebot=1
        log "NoneBot 是当前 GScore 处理方，必须保留"
      elif prompt_yes_no "启用 NoneBot" "$([[ "$old_enable_nonebot" == "1" ]] && printf y || printf n)"; then
        enable_nonebot=1
      else
        enable_nonebot=0
      fi
      if ((enable_astrbot || enable_nonebot)); then
        if prompt_yes_no "启用 BotShepherd" "$([[ "$old_use_botshepherd" == "1" ]] && printf y || printf n)"; then
          use_botshepherd=1
        else
          use_botshepherd=0
        fi
      else
        use_botshepherd=0
      fi
    fi
  elif [[ "$topology_action" == "2" ]]; then
    repair_mode=1
    use_personal="$old_use_personal"
    use_official="$old_use_official"
    personal_adapter="$old_personal_adapter"
    official_adapter="$old_official_adapter"
    enable_astrbot="$old_enable_astrbot"
    enable_nonebot="$old_enable_nonebot"
    use_botshepherd="$old_use_botshepherd"
  else
    full_reconfigure=1
    guided_render_catalog
    cat <<'EOF'

请选择大方案：
  1) 个人 QQ 方案
  2) QQ 官方机器人方案
  3) 双通道方案
EOF
  channel_choice="$(guided_choice "请输入 1、2 或 3: " 1 3)"
  case "$channel_choice" in
    1) use_personal=1 ;;
    2) use_official=1 ;;
    3) use_personal=1; use_official=1 ;;
  esac

  if ((use_personal)); then
    cat <<'EOF'

个人 QQ 默认使用 NapCatQQ。请选择个人 QQ 的 GScore 处理方（单选）：
  1) NapCat GScore 插件（推荐）
  2) NoneBot GenshinUID
  3) AstrBot GScore 适配器
EOF
    adapter_choice="$(guided_choice "请输入 1、2 或 3: " 1 3)"
    case "$adapter_choice" in
      1)
        personal_adapter="napcat"
        prompt_yes_no "是否同时安装 AstrBot" n && enable_astrbot=1
        prompt_yes_no "是否同时安装 NoneBot" n && enable_nonebot=1
        ;;
      2)
        personal_adapter="nonebot"
        enable_nonebot=1
        prompt_yes_no "是否额外安装 AstrBot" n && enable_astrbot=1
        ;;
      3)
        personal_adapter="astrbot"
        enable_astrbot=1
        prompt_yes_no "是否额外安装 NoneBot" n && enable_nonebot=1
        warn "AstrBot GScore 适配器完成度相对较低；如无特殊需求，建议改用 NapCat 或 NoneBot 适配器"
        ;;
    esac

    if ((enable_astrbot || enable_nonebot)); then
      local bs_default=n
      ((enable_astrbot && enable_nonebot)) && bs_default=y
      if prompt_yes_no "是否在 NapCat 与下游框架之间加入 BotShepherd" "$bs_default"; then
        use_botshepherd=1
      fi
    fi
  fi

  if ((full_reconfigure && use_official)); then
    cat <<'EOF'

请选择 QQ 官方机器人的 GScore 接入方式（单选）：
  1) gscore-qqofficial 轻量直连（推荐）
  2) NoneBot + nonebot-adapter-qq
EOF
    adapter_choice="$(guided_choice "请输入 1 或 2: " 1 2)"
    if [[ "$adapter_choice" == "1" ]]; then
      official_adapter="direct"
      enable_official_direct=1
    else
      official_adapter="nonebot"
      enable_official_nonebot=1
    fi
  fi
  fi

  if ((use_official)); then
    [[ "$official_adapter" == "nonebot" ]] \
      && enable_official_nonebot=1 || enable_official_nonebot=0
    [[ "$official_adapter" == "direct" ]] \
      && enable_official_direct=1 || enable_official_direct=0
  else
    official_adapter="none"
    enable_official_nonebot=0
    enable_official_direct=0
  fi
  if ((use_personal)); then
    [[ "$personal_adapter" == "nonebot" ]] && enable_nonebot=1
    [[ "$personal_adapter" == "astrbot" ]] && enable_astrbot=1
  fi
  guided_validate_topology \
    "$use_personal" "$use_official" \
    "$personal_adapter" "$official_adapter" \
    "$enable_astrbot" "$enable_nonebot" "$use_botshepherd" \
    || die "所选组件组合不满足方案约束"

  local data_root
  local bind_ip
  local gscore_port
  local napcat_port
  local astrbot_port
  local botshepherd_port
  local personal_masters=""
  local napcat_account=""
  local napcat_mac=""
  local fixed_mac=0
  local qq_app_id=""
  local qq_app_secret=""
  local qq_token=""
  local qq_admin_ids=""
  local qq_is_sandbox
  local qq_api_base
  local gscore_ws_token
  local napcat_image="mlikiowa/napcat-docker:latest"

  napcat_port="$(env_value NAPCAT_WEBUI_PORT "$env_file" || true)"
  napcat_port="${napcat_port:-6099}"
  astrbot_port="$(env_value ASTRBOT_WEBUI_PORT "$env_file" || true)"
  astrbot_port="${astrbot_port:-6185}"
  botshepherd_port="$(env_value BOTSHEPHERD_WEBUI_PORT "$env_file" || true)"
  botshepherd_port="${botshepherd_port:-5111}"
  personal_masters="$(env_value NAPCAT_MASTER_QQ "$env_file" || true)"
  napcat_account="$(env_value NAPCAT_ACCOUNT "$identity_file" || true)"
  napcat_mac="$(env_value NAPCAT_MAC "$identity_file" || true)"
  qq_app_id="$(env_value QQ_APP_ID "$env_file" || true)"
  qq_app_secret="$(env_value QQ_APP_SECRET "$env_file" || true)"
  qq_token="$(env_value QQ_TOKEN "$env_file" || true)"
  qq_admin_ids="$(env_value QQ_ADMIN_IDS "$env_file" || true)"
  qq_is_sandbox="$(env_value QQ_IS_SANDBOX "$env_file" || true)"
  qq_is_sandbox="${qq_is_sandbox:-false}"
  qq_api_base="$(env_value QQ_API_BASE "$env_file" || true)"
  qq_api_base="${qq_api_base:-https://api.sgroup.qq.com}"

  data_root="$(env_value DATA_ROOT "$env_file" || true)"
  data_root="${data_root:-/opt/nag-data}"
  bind_ip="$(env_value BIND_IP "$env_file" || true)"
  bind_ip="${bind_ip:-127.0.0.1}"
  gscore_port="$(env_value GSCORE_PORT "$env_file" || true)"
  gscore_port="${gscore_port:-8765}"
  local edit_shared_settings=1
  if ((existing_state)); then
    edit_shared_settings=0
    if prompt_yes_no "修改数据目录、绑定地址、端口或账号凭据" n; then
      edit_shared_settings=1
    fi
  fi
  if ((edit_shared_settings)); then
    data_root="$(prompt_value "持久化数据目录" "$data_root")"
    bind_ip="$(prompt_value "WebUI 绑定地址" "$bind_ip")"
    gscore_port="$(prompt_value "GsCore WebUI 端口" "$gscore_port")"
  fi

  local personal_added=0
  local official_added=0
  local astrbot_added=0
  local nonebot_added=0
  local botshepherd_added=0
  ((use_personal && ! old_use_personal)) && personal_added=1
  ((use_official && ! old_use_official)) && official_added=1
  ((enable_astrbot && ! old_enable_astrbot)) && astrbot_added=1
  ((enable_nonebot && ! old_enable_nonebot)) && nonebot_added=1
  ((use_botshepherd && ! old_use_botshepherd)) && botshepherd_added=1

  if ((use_personal)); then
    if ((! existing_state || personal_added || edit_shared_settings)); then
      while [[ -z "$personal_masters" ]]; do
        personal_masters="$(
          prompt_value \
            "个人 QQ 主人账号（多个使用英文逗号分隔）" \
            "$personal_masters"
        )"
        [[ -n "$personal_masters" ]] || warn "主人 QQ 不能为空"
      done
    fi
    personal_masters="${personal_masters//[[:space:]]/}"
    [[ "$personal_masters" =~ ^[1-9][0-9]{4,11}(,[1-9][0-9]{4,11})*$ ]] || \
      die "主人 QQ 格式无效"

    napcat_account="${napcat_account:-$(detect_napcat_account "$data_root" || true)}"
    if ((! existing_state || personal_added || edit_shared_settings)); then
      napcat_account="$(
        prompt_value \
          "机器人 QQ（首次部署可留空）" \
          "$napcat_account"
      )"
    fi
    napcat_account="${napcat_account//[[:space:]]/}"
    if [[ -n "$napcat_account" \
      && ! "$napcat_account" =~ ^[1-9][0-9]{4,11}$ ]]; then
      die "机器人 QQ 格式无效"
    fi

    if ((! existing_state || personal_added || edit_shared_settings)); then
      napcat_port="$(
        prompt_value \
          "NapCat WebUI 端口" \
          "$napcat_port"
      )"
    fi
    napcat_port="${napcat_port:-6099}"
    if ((! existing_state || personal_added || edit_shared_settings)); then
      local mac_default=y
      ((existing_state)) && [[ -z "$napcat_mac" ]] && mac_default=n
      if prompt_yes_no "为 NapCat 生成并固定唯一 MAC 地址" "$mac_default"; then
        fixed_mac=1
        napcat_mac="${napcat_mac:-$(random_mac)}"
      else
        napcat_mac=""
      fi
    elif [[ -n "$napcat_mac" ]]; then
      fixed_mac=1
    fi
    if [[ "$personal_adapter" == "napcat" ]]; then
      napcat_image="$NAPCAT_COMPAT_IMAGE"
    fi
  fi

  if ((enable_astrbot)); then
    if ((! existing_state || astrbot_added || edit_shared_settings)); then
      astrbot_port="$(
        prompt_value \
          "AstrBot WebUI 端口" \
          "$astrbot_port"
      )"
    fi
    astrbot_port="${astrbot_port:-6185}"
  fi
  if ((use_botshepherd)); then
    if ((! existing_state || botshepherd_added || edit_shared_settings)); then
      botshepherd_port="$(
        prompt_value \
          "BotShepherd WebUI 端口" \
          "$botshepherd_port"
      )"
    fi
    botshepherd_port="${botshepherd_port:-5111}"
  fi

  if ((use_official)); then
    if ((! existing_state || official_added || edit_shared_settings)) \
      || [[ "$official_adapter" != "$old_official_adapter" ]]; then
      qq_app_id="$(prompt_value "QQ 官方机器人 AppID" "$qq_app_id")"
      qq_app_secret="$(prompt_value "QQ 官方机器人 AppSecret" "$qq_app_secret")"
      if [[ "$official_adapter" == "nonebot" ]]; then
        qq_token="$(prompt_value "QQ 官方机器人 Token" "$qq_token")"
      fi
    fi
    [[ -n "$qq_app_id" && -n "$qq_app_secret" ]] || \
      die "QQ 官方机器人 AppID 和 AppSecret 不能为空"
    if [[ "$official_adapter" == "nonebot" && -z "$qq_token" ]]; then
      die "NoneBot QQ 官方适配器需要 Token"
    fi
    if ((! existing_state || official_added || edit_shared_settings)); then
      qq_admin_ids="$(
        prompt_value \
          "官方机器人管理员 OpenID（可留空，多个用英文逗号分隔）" \
          "$qq_admin_ids"
      )"
    fi
    qq_admin_ids="${qq_admin_ids//[[:space:]]/}"
    local sandbox_default=n
    [[ "$qq_is_sandbox" == "true" ]] && sandbox_default=y
    if ((! existing_state || official_added || edit_shared_settings)); then
      if prompt_yes_no "使用 QQ 开放平台沙盒环境" "$sandbox_default"; then
        qq_is_sandbox=true
        qq_api_base="https://sandbox.api.sgroup.qq.com"
      else
        qq_is_sandbox=false
        qq_api_base="https://api.sgroup.qq.com"
      fi
    fi
  fi

  [[ "$data_root" == /* ]] || die "DATA_ROOT must be an absolute path"
  case "$bind_ip" in
    127.0.0.1|0.0.0.0) ;;
    *) die "BIND_IP must be 127.0.0.1 or 0.0.0.0" ;;
  esac
  validate_port GSCORE_PORT "$gscore_port"
  (( ! use_personal )) || validate_port NAPCAT_WEBUI_PORT "$napcat_port"
  (( ! enable_astrbot )) || validate_port ASTRBOT_WEBUI_PORT "$astrbot_port"
  (( ! use_botshepherd )) || \
    validate_port BOTSHEPHERD_WEBUI_PORT "$botshepherd_port"
  local selected_ports=("$gscore_port")
  ((use_personal)) && selected_ports+=("$napcat_port")
  ((enable_astrbot)) && selected_ports+=("$astrbot_port")
  ((use_botshepherd)) && selected_ports+=("$botshepherd_port")
  local port_index other_index
  for ((port_index = 0; port_index < ${#selected_ports[@]}; port_index++)); do
    for ((other_index = port_index + 1; other_index < ${#selected_ports[@]}; other_index++)); do
      [[ "${selected_ports[$port_index]}" != "${selected_ports[$other_index]}" ]] || \
        die "所有 WebUI 端口必须不同"
    done
  done

  local plugin_prompt="安装鸣潮插件套件（XutheringWavesUID、RoverSign、ScoreEcho）"
  local plugin_default=y
  if ((existing_state)); then
    plugin_prompt="更新或补装鸣潮插件套件与额外依赖"
    plugin_default=n
  fi
  if prompt_yes_no "$plugin_prompt" "$plugin_default"; then
    INSTALL_WUWA=1
    prompt_yes_no "安装 Playwright、OpenCV、字体、拼音和 Chromium 等额外依赖" y \
      && INSTALL_WUWA_DEPS=1 || INSTALL_WUWA_DEPS=0
  else
    INSTALL_WUWA=0
    INSTALL_WUWA_DEPS=0
  fi
  if ((INSTALL_WUWA)) \
    && prompt_yes_no "使用 CNB 镜像克隆鸣潮插件" n; then
    XUTHERINGWAVESUID_REPO="https://cnb.cool/gscore-mirror/XutheringWavesUID"
    ROVERSIGN_REPO="https://cnb.cool/gscore-mirror/RoverSign"
    SCOREECHO_REPO="https://cnb.cool/gscore-mirror/ScoreEcho"
  else
    XUTHERINGWAVESUID_REPO="https://github.com/Loping151/XutheringWavesUID.git"
    ROVERSIGN_REPO="https://github.com/Loping151/RoverSign.git"
    SCOREECHO_REPO="https://github.com/Loping151/ScoreEcho.git"
  fi

  gscore_ws_token="$(env_value GSCORE_WS_TOKEN "$env_file" || true)"
  if [[ -z "$gscore_ws_token" ]]; then
    gscore_ws_token="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
  fi

  local profile
  profile="$(
    if ((use_personal && use_official)); then
      printf dual
    elif ((use_personal)); then
      printf personal
    else
      printf official
    fi
  )"
  local personal_changed=0
  local official_changed=0
  local astrbot_changed=0
  local nonebot_changed=0
  local botshepherd_changed=0
  local shared_settings_changed=0
  local personal_settings_changed=0
  local official_settings_changed=0
  local napcat_runtime_changed=0
  local napcat_image_changed=0
  local storage_root_changed=0
  local force_reconcile=0
  (( ! existing_state || repair_mode)) && force_reconcile=1
  if [[ "$use_personal" != "$old_use_personal" \
    || "$personal_adapter" != "$old_personal_adapter" ]]; then
    personal_changed=1
  fi
  [[ "$use_official" != "$old_use_official" \
    || "$official_adapter" != "$old_official_adapter" ]] \
    && official_changed=1
  [[ "$enable_astrbot" != "$old_enable_astrbot" ]] && astrbot_changed=1
  [[ "$enable_nonebot" != "$old_enable_nonebot" ]] && nonebot_changed=1
  [[ "$use_botshepherd" != "$old_use_botshepherd" ]] && botshepherd_changed=1
  [[ "$astrbot_port" != "${old_astrbot_port:-$astrbot_port}" ]] \
    && astrbot_changed=1
  [[ "$botshepherd_port" != "${old_botshepherd_port:-$botshepherd_port}" ]] \
    && botshepherd_changed=1
  if [[ "$data_root" != "${old_data_root:-$data_root}" \
    || "$bind_ip" != "${old_bind_ip:-$bind_ip}" \
    || "$gscore_port" != "${old_gscore_port:-$gscore_port}" ]]; then
    shared_settings_changed=1
  fi
  [[ "$data_root" != "${old_data_root:-$data_root}" ]] \
    && storage_root_changed=1
  if [[ "$personal_masters" != "$old_personal_masters" \
    || "$napcat_account" != "$old_napcat_account" \
    || "$napcat_mac" != "$old_napcat_mac" \
    || "$napcat_port" != "${old_napcat_port:-$napcat_port}" \
    || "$napcat_image" != "${old_napcat_image:-$napcat_image}" ]]; then
    personal_settings_changed=1
  fi
  if [[ "$data_root" != "${old_data_root:-$data_root}" \
    || "$bind_ip" != "${old_bind_ip:-$bind_ip}" \
    || "$napcat_account" != "$old_napcat_account" \
    || "$napcat_mac" != "$old_napcat_mac" \
    || "$napcat_port" != "${old_napcat_port:-$napcat_port}" \
    || "$napcat_image" != "${old_napcat_image:-$napcat_image}" ]]; then
    napcat_runtime_changed=1
  fi
  [[ "$napcat_image" != "${old_napcat_image:-$napcat_image}" ]] \
    && napcat_image_changed=1
  if [[ "$qq_app_id" != "$old_qq_app_id" \
    || "$qq_app_secret" != "$old_qq_app_secret" \
    || "$qq_token" != "$old_qq_token" \
    || "$qq_admin_ids" != "$old_qq_admin_ids" \
    || "$qq_is_sandbox" != "$old_qq_is_sandbox" ]]; then
    official_settings_changed=1
  fi

  local topology_personal="未启用"
  local topology_official="未启用"
  if ((use_personal)); then
    topology_personal="NapCat；GScore=${personal_adapter}；AstrBot=$enable_astrbot；NoneBot=$enable_nonebot；BotShepherd=$use_botshepherd"
  fi
  if ((use_official)); then
    topology_official="GScore=${official_adapter}；不使用 NapCat"
  fi
  guided_render_topology \
    "$use_personal" "$use_official" \
    "$personal_adapter" "$official_adapter" \
    "$enable_astrbot" "$enable_nonebot" "$use_botshepherd"
  cat <<EOF

配置摘要：
  个人 QQ：$topology_personal
  官方 QQ：$topology_official
  数据目录：$data_root
  GsCore WebUI：http://${bind_ip}:${gscore_port}/app/
  本次插件操作：$([[ $INSTALL_WUWA -eq 1 ]] && printf 更新或补装 || printf 保持现状)
EOF
  if ((existing_state)); then
    printf '\n本次差异计划：\n'
    ((repair_mode)) && printf '  [修复] 重新校验并应用当前大方案的全部组件配置\n'
    if [[ "$old_use_personal" == "0" && "$use_personal" == "1" ]]; then
      printf '  [新增] 个人 QQ 链路\n'
    elif [[ "$old_use_personal" == "1" && "$use_personal" == "0" ]]; then
      printf '  [停止] 个人 QQ 链路（保留 NapCat 登录和配置数据）\n'
    elif [[ "$personal_adapter" != "$old_personal_adapter" ]]; then
      printf '  [切换] 个人 GScore 处理方：%s → %s\n' \
        "$old_personal_adapter" "$personal_adapter"
    fi
    if [[ "$old_use_official" == "0" && "$use_official" == "1" ]]; then
      printf '  [新增] QQ 官方机器人链路\n'
    elif [[ "$old_use_official" == "1" && "$use_official" == "0" ]]; then
      printf '  [停止] QQ 官方机器人链路（保留适配器数据）\n'
    elif [[ "$official_adapter" != "$old_official_adapter" ]]; then
      printf '  [切换] 官方适配器：%s → %s\n' \
        "$old_official_adapter" "$official_adapter"
    fi
    if [[ "$old_enable_astrbot" == "0" && "$enable_astrbot" == "1" ]]; then
      printf '  [新增] AstrBot\n'
    elif [[ "$old_enable_astrbot" == "1" && "$enable_astrbot" == "0" ]]; then
      printf '  [停止] AstrBot（保留数据）\n'
    fi
    if [[ "$old_enable_nonebot" == "0" && "$enable_nonebot" == "1" ]]; then
      printf '  [新增] 个人 QQ NoneBot\n'
    elif [[ "$old_enable_nonebot" == "1" && "$enable_nonebot" == "0" ]]; then
      printf '  [停止] 个人 QQ NoneBot（保留数据）\n'
    fi
    if [[ "$old_use_botshepherd" == "0" && "$use_botshepherd" == "1" ]]; then
      printf '  [新增] BotShepherd\n'
    elif [[ "$old_use_botshepherd" == "1" && "$use_botshepherd" == "0" ]]; then
      printf '  [停止] BotShepherd（保留数据）\n'
    fi
    ((shared_settings_changed)) && printf '  [修改] GsCore 或共享网络配置\n'
    ((personal_settings_changed)) && printf '  [修改] NapCat 镜像、身份、端口或主人配置\n'
    ((official_settings_changed)) && printf '  [修改] QQ 官方机器人凭据或管理员配置\n'
    ((INSTALL_WUWA || INSTALL_WUWA_DEPS)) && printf '  [更新] GsCore 游戏插件与依赖\n'
    if ((use_personal && old_use_personal \
      && (force_reconcile || personal_changed || astrbot_changed || nonebot_changed \
        || botshepherd_changed || personal_settings_changed \
        || napcat_runtime_changed || storage_root_changed))); then
      printf '  [修改] NapCat OneBot/适配器配置\n'
      if ((napcat_runtime_changed)); then
        printf '  [重建] NapCat（镜像或容器参数发生变化）\n'
      else
        printf '  [重启] NapCat（仅一次）\n'
      fi
    fi
    if ((use_official && (force_reconcile || official_changed \
      || official_settings_changed || shared_settings_changed))); then
      printf '  [重建] 当前 QQ 官方适配器\n'
    fi
    local old_combined_masters=""
    local planned_combined_masters=""
    [[ "$old_use_personal" == "1" ]] \
      && old_combined_masters="$old_personal_masters"
    if [[ "$old_use_official" == "1" && -n "$old_qq_admin_ids" ]]; then
      old_combined_masters="${old_combined_masters:+${old_combined_masters},}${old_qq_admin_ids}"
    fi
    ((use_personal)) && planned_combined_masters="$personal_masters"
    if ((use_official)) && [[ -n "$qq_admin_ids" ]]; then
      planned_combined_masters="${planned_combined_masters:+${planned_combined_masters},}${qq_admin_ids}"
    fi
    if ((repair_mode || shared_settings_changed || INSTALL_WUWA || INSTALL_WUWA_DEPS)) \
      || [[ "$old_combined_masters" != "$planned_combined_masters" ]]; then
      printf '  [重启] GsCore（配置或插件发生变化）\n'
    fi
    if (( ! repair_mode && ! personal_changed && ! official_changed \
      && ! astrbot_changed && ! nonebot_changed && ! botshepherd_changed \
      && ! shared_settings_changed && ! personal_settings_changed \
      && ! official_settings_changed && ! INSTALL_WUWA && ! INSTALL_WUWA_DEPS)); then
      printf '  [保持] 当前拓扑和组件不变\n'
    else
      printf '  [保持] 未在上方列出的组件和持久化数据\n'
    fi
  else
    printf '\n本次差异计划：\n  [新增] %s及其所选组件\n' \
      "$(guided_profile_name "$use_personal" "$use_official")"
  fi
  if ((enable_astrbot && enable_nonebot)); then
    warn "AstrBot 与 NoneBot 会同时收到普通 OneBot 消息；请避免安装功能重叠的普通插件"
  fi
  if ((DRY_RUN)); then
    log "guided dry-run completed; no credentials or files were written"
    return
  fi
  prompt_yes_no "确认开始安装" y || {
    log "installation cancelled"
    return
  }

  command -v "$DOCKER_BIN" >/dev/null 2>&1 || die "Docker is not installed"
  "$DOCKER_BIN" compose version >/dev/null 2>&1 || die "Docker Compose V2 is required"
  "$DOCKER_BIN" info >/dev/null 2>&1 || die "cannot access the Docker daemon"
  if ((use_personal)); then
    case "$(uname -m)" in
      x86_64|amd64|aarch64|arm64) ;;
      *) warn "the current architecture ($(uname -m)) is not listed by the NapCat Docker image" ;;
    esac
  fi
  if ((use_botshepherd)); then
    case "$(uname -m)" in
      x86_64|amd64) ;;
      *) die "the published BotShepherd image currently supports linux/amd64 only" ;;
    esac
  fi
  mkdir -p "$STATE_DIR"

  if ((use_personal)); then
    local identity_tmp="${identity_file}.tmp"
    cat >"$identity_tmp" <<EOF
# Shared NapCat identity generated by install.sh.
NAPCAT_MAC=$napcat_mac
NAPCAT_ACCOUNT=$napcat_account
EOF
    chmod 600 "$identity_tmp"
  fi

  local targets=()
  ((enable_astrbot)) && targets+=("ws://astrbot:6199/ws")
  ((enable_nonebot)) && targets+=("ws://nonebot:8080/onebot/v11/ws")
  local targets_csv=""
  if ((${#targets[@]})); then
    targets_csv="$(IFS=,; printf '%s' "${targets[*]}")"
  fi
  local state_tmp="${state_file}.tmp"
  cat >"$state_tmp" <<EOF
# Generated by install.sh. Contains topology only; no credentials.
NAG_GUIDED_STATE_VERSION=2
PROFILE=$profile
USE_PERSONAL=$use_personal
USE_OFFICIAL=$use_official
PERSONAL_ADAPTER=$personal_adapter
OFFICIAL_ADAPTER=$official_adapter
ENABLE_ASTRBOT=$enable_astrbot
ENABLE_NONEBOT=$enable_nonebot
BOTSHEPHERD_ENABLED=$use_botshepherd
FIXED_MAC=$fixed_mac
EOF
  local env_tmp="${env_file}.tmp"
  cat >"$env_tmp" <<EOF
# Generated by install.sh guided component installer.
NAG_GUIDED_STATE_VERSION=2
PROFILE=$profile
USE_PERSONAL=$use_personal
USE_OFFICIAL=$use_official
PERSONAL_ADAPTER=$personal_adapter
OFFICIAL_ADAPTER=$official_adapter
DATA_ROOT=$data_root
BIND_IP=$bind_ip
TZ=Asia/Shanghai
GSCORE_PORT=$gscore_port
NAPCAT_WEBUI_PORT=$napcat_port
ASTRBOT_WEBUI_PORT=$astrbot_port
BOTSHEPHERD_WEBUI_PORT=$botshepherd_port
NAPCAT_UID=$(id -u)
NAPCAT_GID=$(id -g)
NAPCAT_ACCOUNT=$napcat_account
NAPCAT_MAC=$napcat_mac
NAPCAT_MASTER_QQ=$personal_masters
NAPCAT_IMAGE=$napcat_image
GSCORE_IMAGE=docker.cnb.cool/gscore-mirror/gsuid_core:latest
ASTRBOT_IMAGE=soulter/astrbot:latest
NONEBOT_IMAGE=nag-nonebot:local
BOTSHEPHERD_IMAGE=$BOTSHEPHERD_IMAGE_DEFAULT
GSCORE_QQOFFICIAL_IMAGE=nag-gscore-qqofficial:0.7.0-2d582f6
GSCORE_QQOFFICIAL_BUILD_CONTEXT=https://github.com/An-Sun110/gscore-qqofficial.git#$GSCORE_QQOFFICIAL_COMMIT
GSCORE_WS_TOKEN=$gscore_ws_token
ENABLE_ASTRBOT=$enable_astrbot
ENABLE_NONEBOT=$enable_nonebot
ENABLE_NONEBOT_GSCORE_ADAPTER=$([[ "$personal_adapter" == "nonebot" ]] && printf true || printf false)
BOTSHEPHERD_ENABLED=$use_botshepherd
BOTSHEPHERD_TARGET_ENDPOINTS=$targets_csv
QQ_APP_ID=$qq_app_id
QQ_APP_SECRET=$qq_app_secret
QQ_TOKEN=$qq_token
QQ_ADMIN_IDS=$qq_admin_ids
QQ_IS_SANDBOX=$qq_is_sandbox
QQ_API_BASE=$qq_api_base
NAPCAT_GSCORE_ADAPTER_ZIP_URL=$NAPCAT_ADAPTER_LATEST_URL
ASTRBOT_GSCORE_ADAPTER_REPO=https://github.com/KimigaiiWuyi/astrbot_plugin_gscore_adapter.git
XUTHERINGWAVESUID_REPO=$XUTHERINGWAVESUID_REPO
ROVERSIGN_REPO=$ROVERSIGN_REPO
SCOREECHO_REPO=$SCOREECHO_REPO
GSCORE_PYTHON_INDEX=https://pypi.org/simple/
UV_NO_CONFIG=0
PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
GSCORE_XWUID_PYTHON_PACKAGES=playwright opencv-python fonttools pypinyin
EOF
  chmod 600 "$env_tmp"

  local data_dirs=(
    "$data_root/gscore/data"
    "$data_root/gscore/plugins"
  )
  if ((use_personal)); then
    data_dirs+=(
      "$data_root/napcat/config"
      "$data_root/napcat/plugins"
      "$data_root/napcat/qq"
    )
  fi
  ((enable_astrbot)) && data_dirs+=("$data_root/astrbot")
  ((enable_nonebot)) && \
    data_dirs+=("$data_root/nonebot/data" "$data_root/nonebot/plugins")
  ((enable_official_nonebot)) && \
    data_dirs+=(
      "$data_root/nonebot-qqofficial/data"
      "$data_root/nonebot-qqofficial/plugins"
    )
  ((enable_official_direct)) && data_dirs+=("$data_root/gscore-qqofficial")
  if ((use_botshepherd)); then
    data_dirs+=(
      "$data_root/botshepherd/config"
      "$data_root/botshepherd/data"
      "$data_root/botshepherd/logs"
    )
  fi
  if ! mkdir -p "${data_dirs[@]}" 2>/dev/null; then
    command -v sudo >/dev/null 2>&1 || die "cannot create $data_root"
    sudo install -d -m 0755 -o "$(id -u)" -g "$(id -g)" "${data_dirs[@]}"
  fi
  if ((enable_official_direct)); then
    chown 10001:10001 "$data_root/gscore-qqofficial" 2>/dev/null \
      || sudo chown 10001:10001 "$data_root/gscore-qqofficial"
    chmod 0700 "$data_root/gscore-qqofficial"
  fi

  local guided_compose_cmd=(
    "$DOCKER_BIN" compose
    --project-directory "$SCRIPT_DIR"
    --env-file "$env_tmp"
    -p nag
    -f "${SCRIPT_DIR}/docker-compose.guided.yml"
  )
  if ((fixed_mac)); then
    guided_compose_cmd+=(-f "${SCRIPT_DIR}/docker-compose.mac.example.yml")
  fi
  guided_compose() {
    "${guided_compose_cmd[@]}" "$@"
  }
  guided_service_exists() {
    [[ -n "$(guided_compose ps -aq "$1" 2>/dev/null || true)" ]]
  }
  guided_service_running() {
    [[ -n "$(guided_compose ps --status running -q "$1" 2>/dev/null || true)" ]]
  }

  guided_compose config --quiet
  local stop_services=()
  ((use_personal)) || stop_services+=(napcat)
  ((enable_astrbot)) || stop_services+=(astrbot)
  ((enable_nonebot)) || stop_services+=(nonebot)
  ((enable_official_nonebot)) || stop_services+=(nonebot-qqofficial)
  ((enable_official_direct)) || stop_services+=(gscore-qqofficial)
  ((use_botshepherd)) || stop_services+=(botshepherd)
  if ((${#stop_services[@]})); then
    log "stopping components that are not part of the selected topology"
    guided_compose stop "${stop_services[@]}" >/dev/null 2>&1 || true
  fi

  if ((force_reconcile)) || ! guided_service_exists gscore; then
    log "pulling the shared GsCore image"
    guided_compose pull gscore
  fi
  if ((use_personal)) \
    && { ((force_reconcile || personal_added || napcat_image_changed)) \
      || ! guided_service_exists napcat; }; then
    log "pulling the selected NapCat image"
    guided_compose pull napcat
  fi
  if ((enable_astrbot)) \
    && { ((force_reconcile || astrbot_added)) \
      || ! guided_service_exists astrbot; }; then
    log "pulling the AstrBot image"
    guided_compose pull astrbot
  fi
  if ((use_botshepherd)) \
    && { ((force_reconcile || botshepherd_added)) \
      || ! guided_service_exists botshepherd; }; then
    log "pulling the BotShepherd image"
    guided_compose pull botshepherd
  fi
  if ((enable_nonebot || enable_official_nonebot)) \
    && { ((force_reconcile || nonebot_added || official_changed)) \
      || { ((enable_nonebot)) && ! guided_service_exists nonebot; } \
      || { ((enable_official_nonebot)) && ! guided_service_exists nonebot-qqofficial; }; }; then
    log "building the shared NoneBot image"
    guided_compose build nonebot
  fi
  if ((enable_official_direct)) \
    && { ((force_reconcile || official_changed)) \
      || ! guided_service_exists gscore-qqofficial; }; then
    log "building gscore-qqofficial from pinned upstream commit"
    guided_compose build gscore-qqofficial
  fi

  local apply_started_at
  apply_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local gscore_restarted=0
  log "ensuring the shared GsCore is running"
  guided_compose up -d gscore
  local attempt
  local venv_ready=0
  for ((attempt = 1; attempt <= 60; attempt++)); do
    if guided_compose exec -T gscore sh -c \
      'test -x /venv/bin/python && test -f /gsuid_core/data/config.json' \
      >/dev/null 2>&1; then
      venv_ready=1
      break
    fi
    sleep 2
  done
  ((venv_ready)) || die "GsCore did not initialize within 120 seconds"

  local combined_masters=""
  if ((use_personal)); then
    combined_masters="$personal_masters"
  fi
  if ((use_official)) && [[ -n "$qq_admin_ids" ]]; then
    combined_masters="${combined_masters:+${combined_masters},}${qq_admin_ids}"
  fi
  local gscore_config_changed
  gscore_config_changed="$(
    guided_compose exec -T gscore /venv/bin/python - \
    "$gscore_ws_token" "$combined_masters" <<'PY'
import json
import sys
from pathlib import Path

path = Path("/gsuid_core/data/config.json")
config = json.loads(path.read_text(encoding="utf-8-sig"))
masters = list(
    dict.fromkeys(item for item in sys.argv[2].split(",") if item)
)
changed = config.get("WS_TOKEN") != sys.argv[1] or config.get("masters") != masters
if changed:
    config["WS_TOKEN"] = sys.argv[1]
    config["masters"] = masters
    path.write_text(
        json.dumps(config, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
print("1" if changed else "0", end="")
PY
  )"
  if [[ "$gscore_config_changed" == "1" ]] || ((repair_mode)); then
    log "restarting GsCore to apply configuration"
    guided_compose restart gscore
    gscore_restarted=1
  else
    log "GsCore configuration is unchanged; keeping the current process"
  fi
  log "waiting for the base GsCore WebUI"
  for ((attempt = 1; attempt <= 90; attempt++)); do
    if guided_compose exec -T gscore /venv/bin/python -c \
      'from urllib.request import urlopen; r=urlopen("http://127.0.0.1:8765/app/",timeout=3); assert r.status == 200' \
      >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  ((attempt <= 90)) || die "GsCore WebUI did not become ready"

  local personal_adapter_reconfigure=0
  local astrbot_reconfigure=0
  local napcat_reconfigure=0
  ((force_reconcile || personal_changed || personal_added \
    || personal_settings_changed || storage_root_changed)) \
    && personal_adapter_reconfigure=1
  ((force_reconcile || astrbot_changed || personal_changed \
    || botshepherd_changed || personal_settings_changed \
    || storage_root_changed)) \
    && astrbot_reconfigure=1
  ((force_reconcile || personal_changed || astrbot_changed \
    || nonebot_changed || botshepherd_changed || personal_settings_changed \
    || storage_root_changed)) \
    && napcat_reconfigure=1

  if ((use_personal && personal_adapter_reconfigure)); then
    if [[ "$personal_adapter" == "napcat" ]]; then
      log "enabling and configuring the NapCat GScore adapter"
      guided_compose --profile init run --rm napcat-gscore-adapter-init
    else
      log "disabling the NapCat GScore adapter to prevent duplicate replies"
      guided_compose --profile init run --rm napcat-gscore-adapter-disable
    fi
  fi
  if ((enable_astrbot && astrbot_reconfigure)); then
    if [[ "$personal_adapter" == "astrbot" ]]; then
      guided_compose --profile init run --rm astrbot-plugin-init
    else
      guided_compose --profile init run --rm astrbot-plugin-disable
    fi
  fi

  if ((enable_astrbot && astrbot_reconfigure)); then
    guided_compose up -d astrbot
    for ((attempt = 1; attempt <= 60; attempt++)); do
      if guided_compose exec -T astrbot sh -c \
        'test -s /AstrBot/data/cmd_config.json' >/dev/null 2>&1; then
        break
      fi
      sleep 2
    done
    ((attempt <= 60)) || die "AstrBot did not create cmd_config.json"
    guided_compose stop astrbot
    guided_compose --profile init run --rm astrbot-onebot-init
  fi

  if ((use_personal && napcat_reconfigure)); then
    guided_compose --profile init run --rm guided-onebot-init
  fi

  local start_services=(gscore)
  ((enable_astrbot)) && start_services+=(astrbot)
  ((enable_nonebot)) && start_services+=(nonebot)
  ((use_botshepherd)) && start_services+=(botshepherd)
  guided_compose up -d "${start_services[@]}"
  local official_reconfigure=0
  ((force_reconcile || official_changed || official_settings_changed \
    || shared_settings_changed)) && official_reconfigure=1
  local official_check_since="$apply_started_at"
  if ((enable_official_nonebot)); then
    if ((official_reconfigure)) || ! guided_service_exists nonebot-qqofficial; then
      guided_compose up -d \
        --no-deps --force-recreate nonebot-qqofficial
      official_reconfigure=1
    else
      guided_compose up -d --no-deps nonebot-qqofficial
    fi
  elif ((enable_official_direct)); then
    if ((official_reconfigure)) || ! guided_service_exists gscore-qqofficial; then
      guided_compose up -d \
        --no-deps --force-recreate gscore-qqofficial
      official_reconfigure=1
    else
      guided_compose up -d --no-deps gscore-qqofficial
    fi
  fi
  if ((use_personal)); then
    guided_compose up -d napcat
    if ((napcat_reconfigure && old_use_personal && ! napcat_runtime_changed)); then
      log "restarting NapCat once to load the updated OneBot configuration"
      guided_compose restart napcat
    fi
  fi

  if ((INSTALL_WUWA || INSTALL_WUWA_DEPS)); then
    log "stopping GsCore after the selected base services have started"
    guided_compose stop gscore
  fi
  if ((INSTALL_WUWA)); then
    log "cloning or updating the Wuthering Waves plugin suite"
    guided_compose --profile init run --rm gscore-plugin-init
  fi
  if ((INSTALL_WUWA_DEPS)); then
    log "installing Wuthering Waves dependencies and Chromium"
    guided_compose --profile init run --rm gscore-xwuid-deps-init
  fi
  if ((INSTALL_WUWA || INSTALL_WUWA_DEPS)); then
    log "starting GsCore with the completed plugin environment"
    guided_compose up -d gscore
    gscore_restarted=1
    for ((attempt = 1; attempt <= 90; attempt++)); do
      if guided_compose exec -T gscore /venv/bin/python -c \
        'from urllib.request import urlopen; r=urlopen("http://127.0.0.1:8765/app/",timeout=3); assert r.status == 200' \
        >/dev/null 2>&1; then
        break
      fi
      sleep 2
    done
    if ((attempt > 90)); then
      guided_compose logs --tail=120 gscore || true
      die "GsCore WebUI did not become ready after plugin initialization"
    fi
  fi

  local napcat_webui_token=""
  local astrbot_initial_password=""
  local botshepherd_initial_password=""
  if ((use_personal)); then
    log "waiting for the NapCat WebUI token"
    for ((attempt = 1; attempt <= 60; attempt++)); do
      napcat_webui_token="$(
        guided_compose logs --no-color napcat 2>/dev/null \
          | sed -n 's/.*WebUi Token:[[:space:]]*\([^[:space:]]*\).*/\1/p' \
          | tail -n 1 || true
      )"
      [[ -z "$napcat_webui_token" ]] || break
      sleep 2
    done
    [[ -n "$napcat_webui_token" ]] || \
      warn "NapCat 已启动，但 120 秒内没有从日志读取到 WebUI Token"
  fi
  if ((enable_astrbot)); then
    log "waiting for the AstrBot initial WebUI password"
    local astrbot_password_attempts=1
    ((astrbot_added || ! existing_state || repair_mode)) \
      && astrbot_password_attempts=60
    for ((attempt = 1; attempt <= astrbot_password_attempts; attempt++)); do
      astrbot_initial_password="$(
        guided_compose logs --no-color astrbot 2>/dev/null \
          | sed -E 's/\x1B\[[0-9;]*[[:alpha:]]//g' \
          | sed -n 's/.*Initial password:[[:space:]]*\([[:graph:]][[:graph:]]*\).*/\1/p' \
          | tail -n 1 || true
      )"
      [[ -z "$astrbot_initial_password" ]] || break
      sleep 2
    done
    [[ -n "$astrbot_initial_password" ]] || \
      warn "未从当前容器日志读取到 AstrBot 初始密码；复用已有数据时配置文件只保存密码哈希，无法恢复明文，请使用此前设置的密码或在 WebUI 外重置"
  fi
  if ((use_botshepherd)); then
    for ((attempt = 1; attempt <= 30; attempt++)); do
      botshepherd_initial_password="$(
        guided_compose logs --no-color botshepherd 2>/dev/null \
          | sed -n 's/.*BotShepherd generated initial password:[[:space:]]*\([[:graph:]][[:graph:]]*\).*/\1/p' \
          | tail -n 1 || true
      )"
      [[ -z "$botshepherd_initial_password" ]] || break
      sleep 2
    done
    [[ -n "$botshepherd_initial_password" ]] || \
      warn "未从日志读取到 BotShepherd 初始密码；复用已有数据时请使用此前设置的密码"
  fi

  if ((enable_official_direct && (official_reconfigure || gscore_restarted))); then
    for ((attempt = 1; attempt <= 60; attempt++)); do
      local direct_logs
      direct_logs="$(
        guided_compose logs \
          --since "$official_check_since" --no-color gscore-qqofficial \
          2>/dev/null || true
      )"
      if [[ "$direct_logs" == *"已连接 QQ Gateway"* \
        && "$direct_logs" == *"已连接 gsuid_core"* ]]; then
        break
      fi
      if [[ "$direct_logs" == *"11298"* ]]; then
        die "QQ rejected the server IP (11298); add it to the bot IP whitelist"
      fi
      sleep 2
    done
    ((attempt <= 60)) || die "gscore-qqofficial did not complete both connections"
  elif ((enable_official_direct)); then
    guided_service_running gscore-qqofficial \
      || die "gscore-qqofficial is not running"
  fi
  if ((enable_official_nonebot && (official_reconfigure || gscore_restarted))); then
    for ((attempt = 1; attempt <= 60; attempt++)); do
      local official_nb_logs
      official_nb_logs="$(
        guided_compose logs \
          --since "$official_check_since" --no-color nonebot-qqofficial \
          2>/dev/null || true
      )"
      if [[ "$official_nb_logs" == *"Bot "*" connected"* \
        && "$official_nb_logs" == *"与[gsuid-core]成功连接"* ]]; then
        break
      fi
      if [[ "$official_nb_logs" == *"code=11298"* ]]; then
        die "QQ rejected the server IP (11298); add it to the bot IP whitelist"
      fi
      sleep 2
    done
    ((attempt <= 60)) || die "QQ Official NoneBot did not complete both connections"
  elif ((enable_official_nonebot)); then
    guided_service_running nonebot-qqofficial \
      || die "QQ Official NoneBot is not running"
  fi

  local register_code
  register_code="$(
    guided_compose exec -T gscore /venv/bin/python -c '
import json
from pathlib import Path
config=json.loads(Path("/gsuid_core/data/config.json").read_text(encoding="utf-8-sig"))
print(config.get("REGISTER_CODE",""),end="")
' 2>/dev/null || true
  )"
  guided_compose ps
  mv -f "$env_tmp" "$env_file"
  chmod 600 "$env_file"
  if ((use_personal)); then
    mv -f "$identity_tmp" "$identity_file"
    chmod 600 "$identity_file"
  fi
  mv -f "$state_tmp" "$state_file"
  chmod 600 "$state_file"
  cat <<EOF

组合安装完成。
GsCore：http://${bind_ip}:${gscore_port}/app/
GsCore 注册码：${register_code:-请查看 $data_root/gscore/data/config.json}
私有配置：$env_file
EOF
  if ((use_personal)); then
    printf 'NapCat：http://%s:%s\n' "$bind_ip" "$napcat_port"
    if [[ -n "$napcat_webui_token" ]]; then
      printf 'NapCat Token：%s\n' "$napcat_webui_token"
      printf 'NapCat 登录地址：http://%s:%s/webui?token=%s\n' \
        "$bind_ip" "$napcat_port" "$napcat_webui_token"
    fi
  fi
  if ((enable_astrbot)); then
    printf 'AstrBot：http://%s:%s\n' "$bind_ip" "$astrbot_port"
    printf 'AstrBot 初始密码：%s\n' \
      "${astrbot_initial_password:-当前容器日志中无可恢复的明文密码}"
  fi
  if ((use_botshepherd)); then
    printf 'BotShepherd：http://%s:%s\n' "$bind_ip" "$botshepherd_port"
    printf 'BotShepherd 初始密码：%s\n' \
      "${botshepherd_initial_password:-未从本次启动日志中读取到}"
  fi
  ((use_official)) && \
    printf 'QQ 官方管理员 OpenID：%s\n' "${qq_admin_ids:-未填写，可稍后手动填写并重跑}"
  return 0
}

choose_mode

if [[ "$MODE" == "botshepherd-ports" ]]; then
  manage_botshepherd_ports
  exit 0
fi

if [[ "$MODE" == "guided" ]]; then
  install_guided
  exit 0
fi

if [[ "$MODE" == "qqofficial-nonebot" ]]; then
  install_qqofficial nonebot
  exit 0
elif [[ "$MODE" == "qqofficial-direct" ]]; then
  install_qqofficial direct
  exit 0
fi

case "$MODE" in
  astrbot)
    MODE_LABEL="NapCat + AstrBot + GsCore（AstrBot GScore 适配器）"
    PROJECT_NAME="nag"
    PROJECT_DIR="$SCRIPT_DIR"
    ENV_FILE="${STATE_DIR}/astrbot.env"
    DEFAULT_DATA_ROOT="/opt/nag-data"
    COMPOSE_FILES=("${SCRIPT_DIR}/docker-compose.yml")
    ADAPTER_KIND="astrbot"
    FRAMEWORK_KIND="astrbot"
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
    FRAMEWORK_KIND="astrbot"
    ;;
  napcat)
    MODE_LABEL="NapCat + GsCore（NapCat GScore 适配器）"
    PROJECT_NAME="ng"
    PROJECT_DIR="${SCRIPT_DIR}/NG"
    ENV_FILE="${STATE_DIR}/napcat.env"
    DEFAULT_DATA_ROOT="/opt/ng-data"
    COMPOSE_FILES=("${SCRIPT_DIR}/NG/docker-compose.yml")
    ADAPTER_KIND="napcat"
    FRAMEWORK_KIND="none"
    ;;
  nonebot)
    MODE_LABEL="NapCat + NoneBot + GsCore（NoneBot GScore 适配器）"
    PROJECT_NAME="nag"
    PROJECT_DIR="$SCRIPT_DIR"
    ENV_FILE="${STATE_DIR}/nonebot.env"
    DEFAULT_DATA_ROOT="/opt/nag-data"
    COMPOSE_FILES=("${SCRIPT_DIR}/docker-compose.nonebot.yml")
    ADAPTER_KIND="nonebot"
    FRAMEWORK_KIND="nonebot"
    ;;
  nonebot-napcat)
    MODE_LABEL="NapCat + NoneBot + GsCore（NapCat GScore 适配器）"
    PROJECT_NAME="nag"
    PROJECT_DIR="$SCRIPT_DIR"
    ENV_FILE="${STATE_DIR}/nonebot-napcat.env"
    DEFAULT_DATA_ROOT="/opt/nag-data"
    COMPOSE_FILES=(
      "${SCRIPT_DIR}/docker-compose.nonebot.yml"
      "${SCRIPT_DIR}/docker-compose.napcat-adapter.yml"
    )
    ADAPTER_KIND="napcat"
    FRAMEWORK_KIND="nonebot"
    ;;
  *)
    die "unsupported mode: $MODE (expected astrbot, hybrid, napcat, nonebot, or nonebot-napcat)"
    ;;
esac

if [[ "$FRAMEWORK_KIND" == "none" ]]; then
  (( ! USE_BOTSHEPHERD )) || \
    die "--botshepherd is only available in AstrBot or NoneBot modes"
elif (( ! USE_BOTSHEPHERD && ! ASSUME_YES )); then
  if [[ "$FRAMEWORK_KIND" == "astrbot" ]]; then
    FRAMEWORK_LABEL="AstrBot"
  else
    FRAMEWORK_LABEL="NoneBot"
  fi
  if prompt_yes_no "是否在 NapCat 与 ${FRAMEWORK_LABEL} 之间加入 BotShepherd" n; then
    USE_BOTSHEPHERD=1
  fi
fi

if ((USE_BOTSHEPHERD)); then
  if [[ "$FRAMEWORK_KIND" == "astrbot" ]]; then
    MODE_LABEL="${MODE_LABEL/NapCat + AstrBot/NapCat + BotShepherd + AstrBot}"
    COMPOSE_FILES+=("${SCRIPT_DIR}/docker-compose.botshepherd.yml")
  else
    MODE_LABEL="${MODE_LABEL/NapCat + NoneBot/NapCat + BotShepherd + NoneBot}"
    COMPOSE_FILES+=("${SCRIPT_DIR}/docker-compose.botshepherd-nonebot.yml")
  fi
  ENV_FILE="${STATE_DIR}/${MODE}-botshepherd.env"
  if [[ -f "${STATE_DIR}/docker-compose.botshepherd-ports.yml" ]]; then
    COMPOSE_FILES+=("${STATE_DIR}/docker-compose.botshepherd-ports.yml")
  fi
fi

NAPCAT_IDENTITY_FILE="${STATE_DIR}/napcat-identity.env"

NAPCAT_MASTER_QQ="$(env_default NAPCAT_MASTER_QQ "")"
if [[ -n "$NAPCAT_MASTER_QQ_OVERRIDE" ]]; then
  NAPCAT_MASTER_QQ="$NAPCAT_MASTER_QQ_OVERRIDE"
fi
if ((ASSUME_YES)); then
  [[ -n "$NAPCAT_MASTER_QQ" ]] || \
    die "--master-qq is required on the first unattended installation"
else
  while [[ -z "$NAPCAT_MASTER_QQ" ]]; do
    NAPCAT_MASTER_QQ="$(prompt_value "主人 QQ（多个 QQ 使用英文逗号分隔）" "$NAPCAT_MASTER_QQ")"
    [[ -n "$NAPCAT_MASTER_QQ" ]] || warn "主人 QQ 不能为空"
  done
fi
NAPCAT_MASTER_QQ="${NAPCAT_MASTER_QQ//[[:space:]]/}"
[[ "$NAPCAT_MASTER_QQ" =~ ^[1-9][0-9]{4,11}(,[1-9][0-9]{4,11})*$ ]] || \
  die "主人 QQ 格式无效；请输入 5-12 位 QQ 号，多个号码使用英文逗号分隔"

DATA_ROOT="$(prompt_value "持久化数据目录" "$(env_default DATA_ROOT "$DEFAULT_DATA_ROOT")")"

NAPCAT_ACCOUNT="$(env_value NAPCAT_ACCOUNT "$NAPCAT_IDENTITY_FILE")"
NAPCAT_ACCOUNT="${NAPCAT_ACCOUNT:-$(env_default NAPCAT_ACCOUNT "")}"
if [[ -n "$NAPCAT_ACCOUNT_OVERRIDE" ]]; then
  NAPCAT_ACCOUNT="$NAPCAT_ACCOUNT_OVERRIDE"
elif [[ -z "$NAPCAT_ACCOUNT" ]]; then
  NAPCAT_ACCOUNT="$(detect_napcat_account "$DATA_ROOT" || true)"
fi
if (( ! ASSUME_YES )); then
  NAPCAT_ACCOUNT="$(
    prompt_value \
      "机器人 QQ（用于重建后快速登录，首次部署可留空）" \
      "$NAPCAT_ACCOUNT"
  )"
fi
NAPCAT_ACCOUNT="${NAPCAT_ACCOUNT//[[:space:]]/}"
if [[ -n "$NAPCAT_ACCOUNT" \
  && ! "$NAPCAT_ACCOUNT" =~ ^[1-9][0-9]{4,11}$ ]]; then
  die "机器人 QQ 格式无效；请输入 5-12 位 QQ 号"
fi

BIND_IP="$(prompt_value "WebUI 绑定地址" "$(env_default BIND_IP "127.0.0.1")")"
GSCORE_PORT="$(prompt_value "GsCore WebUI 端口" "$(env_default GSCORE_PORT "8765")")"
NAPCAT_WEBUI_PORT="$(prompt_value "NapCat WebUI 端口" "$(env_default NAPCAT_WEBUI_PORT "6099")")"
ASTRBOT_WEBUI_PORT="$(env_default ASTRBOT_WEBUI_PORT "6185")"
BOTSHEPHERD_WEBUI_PORT="$(env_default BOTSHEPHERD_WEBUI_PORT "5111")"
if [[ "$FRAMEWORK_KIND" == "astrbot" ]]; then
  ASTRBOT_WEBUI_PORT="$(prompt_value "AstrBot WebUI 端口" "$ASTRBOT_WEBUI_PORT")"
fi
if ((USE_BOTSHEPHERD)); then
  BOTSHEPHERD_WEBUI_PORT="$(prompt_value "BotShepherd WebUI 端口" "$BOTSHEPHERD_WEBUI_PORT")"
fi

[[ "$DATA_ROOT" == /* ]] || die "DATA_ROOT must be an absolute path"
case "$BIND_IP" in
  127.0.0.1|0.0.0.0) ;;
  *) die "BIND_IP must be 127.0.0.1 or 0.0.0.0" ;;
esac
validate_port GSCORE_PORT "$GSCORE_PORT"
validate_port NAPCAT_WEBUI_PORT "$NAPCAT_WEBUI_PORT"
if [[ "$FRAMEWORK_KIND" == "astrbot" ]]; then
  validate_port ASTRBOT_WEBUI_PORT "$ASTRBOT_WEBUI_PORT"
fi
if ((USE_BOTSHEPHERD)); then
  validate_port BOTSHEPHERD_WEBUI_PORT "$BOTSHEPHERD_WEBUI_PORT"
fi
[[ "$GSCORE_PORT" != "$NAPCAT_WEBUI_PORT" ]] || die "GsCore and NapCat ports must differ"
if [[ "$FRAMEWORK_KIND" == "astrbot" ]]; then
  [[ "$GSCORE_PORT" != "$ASTRBOT_WEBUI_PORT" && "$NAPCAT_WEBUI_PORT" != "$ASTRBOT_WEBUI_PORT" ]] || \
    die "all WebUI ports must differ"
fi
if ((USE_BOTSHEPHERD)); then
  [[ "$BOTSHEPHERD_WEBUI_PORT" != "$GSCORE_PORT" \
    && "$BOTSHEPHERD_WEBUI_PORT" != "$NAPCAT_WEBUI_PORT" ]] || \
    die "all WebUI ports must differ"
  if [[ "$FRAMEWORK_KIND" == "astrbot" ]]; then
    [[ "$BOTSHEPHERD_WEBUI_PORT" != "$ASTRBOT_WEBUI_PORT" ]] || \
      die "all WebUI ports must differ"
  fi
fi

NAPCAT_UID="$(id -u)"
NAPCAT_GID="$(id -g)"
NAPCAT_MAC="$(env_value NAPCAT_MAC "$NAPCAT_IDENTITY_FILE")"
NAPCAT_MAC="${NAPCAT_MAC:-$(env_default NAPCAT_MAC "")}"
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

GSCORE_WS_TOKEN="$(env_default GSCORE_WS_TOKEN "")"
if [[ -z "$GSCORE_WS_TOKEN" ]]; then
  command -v od >/dev/null 2>&1 || die "od is required to generate GSCORE_WS_TOKEN"
  GSCORE_WS_TOKEN="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
fi
[[ "$GSCORE_WS_TOKEN" =~ ^[A-Za-z0-9._~-]+$ ]] || \
  die "GSCORE_WS_TOKEN may only contain letters, numbers, dot, underscore, tilde, and hyphen"

for pair in \
  "DATA_ROOT=$DATA_ROOT" "BIND_IP=$BIND_IP" \
  "GSCORE_PORT=$GSCORE_PORT" "ASTRBOT_WEBUI_PORT=$ASTRBOT_WEBUI_PORT" \
  "BOTSHEPHERD_WEBUI_PORT=$BOTSHEPHERD_WEBUI_PORT" \
  "NAPCAT_WEBUI_PORT=$NAPCAT_WEBUI_PORT" "NAPCAT_ADAPTER_URL=$NAPCAT_ADAPTER_URL" \
  "GSCORE_WS_TOKEN=$GSCORE_WS_TOKEN" "NAPCAT_MASTER_QQ=$NAPCAT_MASTER_QQ" \
  "NAPCAT_ACCOUNT=$NAPCAT_ACCOUNT"; do
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
  if [[ "$FRAMEWORK_KIND" == "astrbot" ]]; then
    printf 'AstrBot 端口：%s\n' "$ASTRBOT_WEBUI_PORT"
    if ((USE_BOTSHEPHERD)); then
      printf 'BotShepherd 端口：%s\n' "$BOTSHEPHERD_WEBUI_PORT"
      printf 'OneBot 连接：自动配置 NapCat -> BotShepherd -> AstrBot\n'
    else
      printf 'OneBot 连接：自动配置 NapCat -> ws://astrbot:6199/ws\n'
    fi
  elif [[ "$FRAMEWORK_KIND" == "nonebot" ]]; then
    if ((USE_BOTSHEPHERD)); then
      printf 'BotShepherd 端口：%s\n' "$BOTSHEPHERD_WEBUI_PORT"
      printf 'OneBot 连接：自动配置 NapCat -> BotShepherd -> NoneBot\n'
    else
      printf 'OneBot 连接：自动配置 NapCat -> ws://nonebot:8080/onebot/v11/ws\n'
    fi
  fi
  printf 'NapCat 镜像：%s\n' "$NAPCAT_IMAGE"
  printf 'NapCat 快速登录账号：%s\n' "${NAPCAT_ACCOUNT:-未指定，首次登录后重跑脚本可自动识别}"
  printf 'GsCore 主人列表：%s（自动配置）\n' "$NAPCAT_MASTER_QQ"
  if [[ "$FRAMEWORK_KIND" == "astrbot" ]]; then
    printf 'AstrBot 管理员 ID：%s（自动配置）\n' "$NAPCAT_MASTER_QQ"
  elif [[ "$FRAMEWORK_KIND" == "nonebot" ]]; then
    printf 'NoneBot SUPERUSERS：%s（自动配置）\n' "$NAPCAT_MASTER_QQ"
  fi
  case "$ADAPTER_KIND" in
    napcat)
      printf 'GScore 适配器：NapCat 插件，自动启用并连接 ws://gscore:8765\n'
      ;;
    nonebot)
      printf 'GScore 适配器：NoneBot GenshinUID，自动连接 gscore:8765\n'
      ;;
  esac
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
if ((USE_BOTSHEPHERD)); then
  case "$(uname -m)" in
    x86_64|amd64) ;;
    *) die "the published BotShepherd image currently supports linux/amd64 only" ;;
  esac
fi

mkdir -p "$STATE_DIR"

tmp_identity="${NAPCAT_IDENTITY_FILE}.tmp"
cat >"$tmp_identity" <<EOF
# Shared NapCat identity generated by install.sh.
# Reused across deployment modes to keep the device identity stable.
NAPCAT_MAC=$NAPCAT_MAC
NAPCAT_ACCOUNT=$NAPCAT_ACCOUNT
EOF
mv -f "$tmp_identity" "$NAPCAT_IDENTITY_FILE"
chmod 600 "$NAPCAT_IDENTITY_FILE"

tmp_env="${ENV_FILE}.tmp"
cat >"$tmp_env" <<EOF
# Generated by install.sh for mode: $MODE
DATA_ROOT=$DATA_ROOT
BIND_IP=$BIND_IP
TZ=Asia/Shanghai
GSCORE_PORT=$GSCORE_PORT
ASTRBOT_WEBUI_PORT=$ASTRBOT_WEBUI_PORT
BOTSHEPHERD_WEBUI_PORT=$BOTSHEPHERD_WEBUI_PORT
NAPCAT_WEBUI_PORT=$NAPCAT_WEBUI_PORT
NAPCAT_UID=$NAPCAT_UID
NAPCAT_GID=$NAPCAT_GID
NAPCAT_MAC=$NAPCAT_MAC
NAPCAT_ACCOUNT=$NAPCAT_ACCOUNT
NAPCAT_MASTER_QQ=$NAPCAT_MASTER_QQ
GSCORE_IMAGE=docker.cnb.cool/gscore-mirror/gsuid_core:latest
ASTRBOT_IMAGE=soulter/astrbot:latest
NONEBOT_IMAGE=nag-nonebot:local
BOTSHEPHERD_IMAGE=$BOTSHEPHERD_IMAGE_DEFAULT
NAPCAT_IMAGE=$NAPCAT_IMAGE
ENABLE_NONEBOT_GSCORE_ADAPTER=$([[ "$ADAPTER_KIND" == "nonebot" ]] && printf true || printf false)
BOTSHEPHERD_ENABLED=$USE_BOTSHEPHERD
NAPCAT_GSCORE_ADAPTER_ZIP_URL=$NAPCAT_ADAPTER_URL
ASTRBOT_GSCORE_ADAPTER_REPO=https://github.com/KimigaiiWuyi/astrbot_plugin_gscore_adapter.git
XUTHERINGWAVESUID_REPO=$XUTHERINGWAVESUID_REPO
ROVERSIGN_REPO=$ROVERSIGN_REPO
SCOREECHO_REPO=$SCOREECHO_REPO
GSCORE_PYTHON_INDEX=https://pypi.org/simple/
GSCORE_WS_TOKEN=$GSCORE_WS_TOKEN
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
if [[ "$FRAMEWORK_KIND" == "astrbot" ]]; then
  DATA_DIRS+=("$DATA_ROOT/astrbot")
elif [[ "$FRAMEWORK_KIND" == "nonebot" ]]; then
  DATA_DIRS+=(
    "$DATA_ROOT/nonebot/data"
    "$DATA_ROOT/nonebot/plugins"
  )
fi
if ((USE_BOTSHEPHERD)); then
  DATA_DIRS+=(
    "$DATA_ROOT/botshepherd/config"
    "$DATA_ROOT/botshepherd/data"
    "$DATA_ROOT/botshepherd/logs"
  )
fi

if ! mkdir -p "${DATA_DIRS[@]}" 2>/dev/null; then
  command -v sudo >/dev/null 2>&1 || die "cannot create $DATA_ROOT and sudo is unavailable"
  log "需要 sudo 创建数据目录"
  sudo install -d -m 0755 -o "$NAPCAT_UID" -g "$NAPCAT_GID" "${DATA_DIRS[@]}"
fi

for data_dir in "${DATA_DIRS[@]}"; do
  [[ -w "$data_dir" ]] || die "$data_dir is not writable by UID $NAPCAT_UID; fix its ownership or permissions"
done

if [[ "$ADAPTER_KIND" == "napcat" && "$FRAMEWORK_KIND" == "astrbot" \
  && -e "$DATA_ROOT/astrbot/plugins/astrbot_plugin_gscore_adapter" ]]; then
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

wait_gscore_ready() {
  local stage="$1"
  local attempt

  log "waiting for GsCore WebUI (${stage})"
  for ((attempt = 1; attempt <= 90; attempt++)); do
    if compose exec -T gscore /venv/bin/python -c \
      'from urllib.request import urlopen; response = urlopen("http://127.0.0.1:8765/app/", timeout=3); assert response.status == 200' \
      >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  compose logs --tail=100 gscore || true
  die "GsCore WebUI did not become ready within 180 seconds (${stage})"
}

wait_napcat_webui_token() {
  local attempt
  local token=""

  for ((attempt = 1; attempt <= 60; attempt++)); do
    token="$(
      compose logs --no-color napcat 2>/dev/null \
        | sed -n 's/.*WebUi Token:[[:space:]]*\([^[:space:]]*\).*/\1/p' \
        | tail -n 1 || true
    )"
    if [[ -n "$token" ]]; then
      printf '%s' "$token"
      return 0
    fi
    sleep 2
  done

  return 1
}

wait_astrbot_initial_password() {
  local attempt
  local password=""

  for ((attempt = 1; attempt <= 60; attempt++)); do
    password="$(
      compose logs --no-color astrbot 2>/dev/null \
        | sed -E 's/\x1B\[[0-9;]*[[:alpha:]]//g' \
        | sed -n 's/.*Initial password:[[:space:]]*\([[:graph:]][[:graph:]]*\).*/\1/p' \
        | tail -n 1 || true
    )"
    if [[ -n "$password" ]]; then
      printf '%s' "$password"
      return 0
    fi
    sleep 2
  done

  return 1
}

wait_astrbot_config() {
  local attempt

  log "waiting for AstrBot to create cmd_config.json"
  for ((attempt = 1; attempt <= 60; attempt++)); do
    if compose exec -T astrbot sh -c 'test -s /AstrBot/data/cmd_config.json' \
      >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  compose logs --tail=100 astrbot || true
  die "AstrBot did not create data/cmd_config.json within 120 seconds"
}

wait_astrbot_onebot_listener() {
  local attempt

  log "waiting for the AstrBot OneBot v11 listener on port 6199"
  for ((attempt = 1; attempt <= 60; attempt++)); do
    if compose exec -T astrbot python -c \
      'import socket; connection = socket.create_connection(("127.0.0.1", 6199), timeout=3); connection.close()' \
      >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  compose logs --tail=100 astrbot || true
  die "AstrBot OneBot v11 listener did not become ready on port 6199 within 120 seconds"
}

wait_nonebot_ready() {
  local attempt

  log "waiting for the NoneBot OneBot v11 listener on port 8080"
  for ((attempt = 1; attempt <= 60; attempt++)); do
    if compose exec -T nonebot python -c \
      'import socket; connection = socket.create_connection(("127.0.0.1", 8080), timeout=3); connection.close()' \
      >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  compose logs --tail=100 nonebot || true
  die "NoneBot did not become ready on port 8080 within 120 seconds"
}

wait_botshepherd_ready() {
  local attempt

  log "waiting for BotShepherd WebUI and OneBot listener"
  for ((attempt = 1; attempt <= 60; attempt++)); do
    if compose exec -T botshepherd python -c '
from urllib.request import urlopen
import socket

response = urlopen("http://127.0.0.1:5111/login", timeout=3)
assert response.status == 200
connection = socket.create_connection(("127.0.0.1", 2537), timeout=3)
connection.close()
' >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  compose logs --tail=100 botshepherd || true
  die "BotShepherd did not become ready within 120 seconds"
}

wait_botshepherd_initial_password() {
  local attempt
  local password=""

  for ((attempt = 1; attempt <= 60; attempt++)); do
    password="$(
      compose logs --no-color botshepherd 2>/dev/null \
        | sed -n 's/.*BotShepherd generated initial password:[[:space:]]*\([[:graph:]][[:graph:]]*\).*/\1/p' \
        | tail -n 1 || true
    )"
    if [[ -n "$password" ]]; then
      printf '%s' "$password"
      return 0
    fi
    sleep 2
  done

  return 1
}

read_gscore_register_code() {
  compose exec -T gscore /venv/bin/python -c '
import json
from pathlib import Path

config = json.loads(Path("/gsuid_core/data/config.json").read_text(encoding="utf-8-sig"))
print(config.get("REGISTER_CODE", ""), end="")
'
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
if [[ "$FRAMEWORK_KIND" == "nonebot" ]]; then
  compose pull gscore napcat
  if ((USE_BOTSHEPHERD)); then
    compose pull botshepherd
  fi
  log "building the NoneBot image"
  compose build nonebot
else
  compose pull
fi

log "starting GsCore"
compose up -d gscore

log "waiting for the persistent GsCore Python environment"
venv_ready=0
for ((attempt = 1; attempt <= 60; attempt++)); do
  if compose exec -T gscore sh -c \
    'test -x /venv/bin/python && test -f /gsuid_core/data/config.json' >/dev/null 2>&1; then
    venv_ready=1
    break
  fi
  sleep 2
done
if (( ! venv_ready )); then
  compose logs --tail=100 gscore || true
  die "GsCore did not create /venv/bin/python and data/config.json within 120 seconds"
fi

wait_gscore_ready "before configuring the WebSocket token"

log "configuring the GsCore WebSocket token and master accounts"
compose exec -T gscore /venv/bin/python - "$GSCORE_WS_TOKEN" "$NAPCAT_MASTER_QQ" <<'PY'
import json
import sys
from pathlib import Path

config_path = Path("/gsuid_core/data/config.json")
config = json.loads(config_path.read_text(encoding="utf-8-sig"))
config["WS_TOKEN"] = sys.argv[1]
if sys.argv[2]:
    config["masters"] = list(dict.fromkeys(sys.argv[2].split(",")))
config_path.write_text(
    json.dumps(config, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
PY
compose restart gscore
wait_gscore_ready "after configuring the WebSocket token"

case "$ADAPTER_KIND" in
  astrbot)
    log "installing the AstrBot GScore adapter"
    compose --profile init run --rm astrbot-plugin-init
    ;;
  napcat)
    log "installing the NapCat GScore adapter"
    compose --profile init run --rm napcat-gscore-adapter-init
    ;;
  nonebot)
    log "disabling the NapCat GScore adapter to prevent duplicate replies"
    compose --profile init run --rm napcat-gscore-adapter-disable
    ;;
esac

if [[ "$FRAMEWORK_KIND" == "nonebot" ]]; then
  log "configuring the NapCat reverse WebSocket client for NoneBot"
  compose --profile init run --rm nonebot-onebot-init
  log "starting NoneBot"
  compose up -d nonebot
  wait_nonebot_ready
  if ((USE_BOTSHEPHERD)); then
    compose up -d botshepherd
    wait_botshepherd_ready
  fi
  compose up -d napcat
else
  log "starting selected services"
  compose up -d
fi

if [[ "$FRAMEWORK_KIND" == "astrbot" ]]; then
  wait_astrbot_config
  log "configuring the AstrBot OneBot v11 platform and NapCat reverse WebSocket client"
  if ((USE_BOTSHEPHERD)); then
    compose stop napcat botshepherd astrbot
  else
    compose stop napcat astrbot
  fi
  compose --profile init run --rm astrbot-onebot-init
  compose up -d astrbot
  wait_astrbot_onebot_listener
  if ((USE_BOTSHEPHERD)); then
    compose up -d botshepherd
    wait_botshepherd_ready
  fi
  compose up -d napcat
fi

if ((INSTALL_WUWA || INSTALL_WUWA_DEPS)); then
  log "stopping GsCore after the selected base services have started"
  compose stop gscore
fi

if ((INSTALL_WUWA)); then
  log "cloning or updating the Wuthering Waves plugin suite"
  compose --profile init run --rm gscore-plugin-init
fi

if ((INSTALL_WUWA_DEPS)); then
  log "installing Wuthering Waves extra dependencies and Chromium"
  compose --profile init run --rm gscore-xwuid-deps-init
fi

if ((INSTALL_WUWA || INSTALL_WUWA_DEPS)); then
  log "starting GsCore with the completed plugin environment"
  compose up -d gscore
  wait_gscore_ready "after installing plugins and dependencies"
fi

GSCORE_REGISTER_CODE=""
if ! GSCORE_REGISTER_CODE="$(read_gscore_register_code)" || [[ -z "$GSCORE_REGISTER_CODE" ]]; then
  warn "GsCore started, but REGISTER_CODE could not be read from data/config.json"
  GSCORE_REGISTER_CODE=""
fi

NAPCAT_WEBUI_TOKEN=""
log "waiting for the NapCat WebUI token"
if ! NAPCAT_WEBUI_TOKEN="$(wait_napcat_webui_token)"; then
  warn "NapCat started, but its WebUI token was not found in logs within 120 seconds"
fi

ASTRBOT_INITIAL_PASSWORD=""
if [[ "$FRAMEWORK_KIND" == "astrbot" ]]; then
  log "waiting for the AstrBot initial WebUI password"
  if ! ASTRBOT_INITIAL_PASSWORD="$(wait_astrbot_initial_password)"; then
    warn "AstrBot started, but no initial WebUI password was found in its current logs; this is expected when reusing existing AstrBot data"
  fi
fi

BOTSHEPHERD_INITIAL_PASSWORD=""
if ((USE_BOTSHEPHERD)); then
  log "waiting for the BotShepherd initial WebUI password"
  if ! BOTSHEPHERD_INITIAL_PASSWORD="$(wait_botshepherd_initial_password)"; then
    warn "BotShepherd started, but no initial WebUI password was found in its current logs; this is expected when reusing existing BotShepherd data"
  fi
fi
compose ps

cat <<EOF

安装完成。

WebUI：
  GsCore: http://${BIND_IP}:${GSCORE_PORT}/app/
  GsCore 注册码: ${GSCORE_REGISTER_CODE:-未读取到，请查看 $DATA_ROOT/gscore/data/config.json 中的 REGISTER_CODE}
  NapCat: http://${BIND_IP}:${NAPCAT_WEBUI_PORT}
EOF
if [[ -n "$NAPCAT_WEBUI_TOKEN" ]]; then
  printf '  NapCat Token: %s\n' "$NAPCAT_WEBUI_TOKEN"
  printf '  NapCat 登录地址: http://%s:%s/webui?token=%s\n' \
    "$BIND_IP" "$NAPCAT_WEBUI_PORT" "$NAPCAT_WEBUI_TOKEN"
fi
if [[ "$FRAMEWORK_KIND" == "astrbot" ]]; then
  printf '  AstrBot: http://%s:%s\n' "$BIND_IP" "$ASTRBOT_WEBUI_PORT"
  printf '  AstrBot 用户名: astrbot\n'
  if [[ -n "$ASTRBOT_INITIAL_PASSWORD" ]]; then
    printf '  AstrBot 初始密码: %s\n' "$ASTRBOT_INITIAL_PASSWORD"
  else
    printf '  AstrBot 初始密码: 未从本次启动日志中读取到\n'
  fi
fi
if ((USE_BOTSHEPHERD)); then
  printf '  BotShepherd: http://%s:%s\n' "$BIND_IP" "$BOTSHEPHERD_WEBUI_PORT"
  printf '  BotShepherd 用户名: admin\n'
  if [[ -n "$BOTSHEPHERD_INITIAL_PASSWORD" ]]; then
    printf '  BotShepherd 初始密码: %s\n' "$BOTSHEPHERD_INITIAL_PASSWORD"
  else
    printf '  BotShepherd 初始密码: 未从本次启动日志中读取到\n'
  fi
fi

cat <<EOF

接下来仍需手动完成：
  1. 在 NapCat WebUI 修改密码并扫码登录 QQ。
  2. 使用上方注册码在 GsCore WebUI 完成首次注册；主人账号列表和 WS_TOKEN 已自动配置。
EOF
if [[ "$ADAPTER_KIND" == "astrbot" ]]; then
  if ((USE_BOTSHEPHERD)); then
    cat <<'EOF'
  3. AstrBot 的 aiocqhttp/OneBot 平台及 NapCat 反向 WebSocket 已自动配置为 NapCat -> BotShepherd -> AstrBot；扫码登录 QQ 后会自动建立连接。GScore 适配器已预配置为 gscore:8765 和共享 WS_TOKEN。
  4. BotShepherd 已创建默认连接并将主人 QQ 写入超级用户；登录 WebUI 后可配置黑名单、指令过滤和更多下游框架。
  5. 如手动修改 WS_TOKEN，请保持 GsCore 与 AstrBot GScore 适配器中的值一致。
EOF
  else
    cat <<'EOF'
  3. AstrBot 的 aiocqhttp/OneBot 平台及 NapCat 反向 WebSocket 已自动配置；扫码登录 QQ 后会自动建立连接。GScore 适配器已预配置为 gscore:8765 和共享 WS_TOKEN。
  4. 如手动修改 WS_TOKEN，请保持 GsCore 与 AstrBot GScore 适配器中的值一致。
EOF
  fi
elif [[ "$FRAMEWORK_KIND" == "astrbot" ]]; then
  if ((USE_BOTSHEPHERD)); then
    cat <<'EOF'
  3. NapCat GScore 适配器已自动启用，并已配置连接地址、WS_TOKEN 和主人 QQ。
  4. AstrBot 的 aiocqhttp/OneBot 平台及 NapCat 反向 WebSocket 已自动配置为 NapCat -> BotShepherd -> AstrBot；扫码登录 QQ 后会自动建立连接。
  5. BotShepherd 已创建默认连接并将主人 QQ 写入超级用户；请让 AstrBot 的 LLM 忽略 GScore 指令前缀，避免重复回复。
EOF
  else
    cat <<'EOF'
  3. NapCat GScore 适配器已自动启用，并已配置连接地址、WS_TOKEN 和主人 QQ。
  4. AstrBot 的 aiocqhttp/OneBot 平台及 NapCat 反向 WebSocket 已自动配置，扫码登录 QQ 后会自动建立连接；请让 LLM 忽略 GScore 指令前缀，避免重复回复。
EOF
  fi
elif [[ "$FRAMEWORK_KIND" == "nonebot" ]]; then
  if [[ "$ADAPTER_KIND" == "nonebot" ]]; then
    if ((USE_BOTSHEPHERD)); then
      cat <<'EOF'
  3. NapCat 反向 WebSocket 已自动配置为 NapCat -> BotShepherd -> NoneBot；NoneBot GenshinUID 使用共享 WS_TOKEN 连接 gscore:8765。
  4. NapCat GScore 插件已自动关闭，避免和 NoneBot GenshinUID 重复处理指令。
  5. BotShepherd 默认连接目标已更新为 ws://nonebot:8080/onebot/v11/ws。
EOF
    else
      cat <<'EOF'
  3. NapCat 反向 WebSocket 已自动连接 NoneBot；NoneBot GenshinUID 使用共享 WS_TOKEN 连接 gscore:8765。
  4. NapCat GScore 插件已自动关闭，避免和 NoneBot GenshinUID 重复处理指令。
EOF
    fi
  elif ((USE_BOTSHEPHERD)); then
    cat <<'EOF'
  3. NapCat GScore 插件已自动启用并直连 gscore:8765；NoneBot 不加载 GenshinUID，避免重复处理。
  4. 普通 OneBot 消息使用 NapCat -> BotShepherd -> NoneBot，BotShepherd 默认目标已更新为 ws://nonebot:8080/onebot/v11/ws。
EOF
  else
    cat <<'EOF'
  3. NapCat GScore 插件已自动启用并直连 gscore:8765；NoneBot 不加载 GenshinUID，避免重复处理。
  4. 普通 OneBot 消息使用 NapCat -> NoneBot。
EOF
  fi
else
  cat <<'EOF'
  3. NapCat GScore 适配器已自动启用，并已配置连接地址、WS_TOKEN 和主人 QQ。
EOF
fi

if [[ -z "$NAPCAT_ACCOUNT" ]]; then
  cat <<'EOF'
  提示：本次未指定机器人 QQ。首次扫码后再次运行同一模式，脚本会从 NapCat 配置文件识别账号并用于后续快速登录。
EOF
fi

printf '\n管理环境文件：%s\n' "$ENV_FILE"
printf '查看状态命令：'
printf ' %q' "${COMPOSE[@]}" ps
printf '\n'
