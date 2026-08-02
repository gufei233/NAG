#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly STATE_DIR="${NAG_INSTALL_STATE_DIR:-${SCRIPT_DIR}/.installer}"
readonly PREFLIGHT_STATE_FILE="${STATE_DIR}/preflight.env"
readonly DOCKER_BIN="${NAG_DOCKER_BIN:-docker}"
readonly NAPCAT_COMPAT_IMAGE="mlikiowa/napcat-docker:v4.18.5"
readonly NAPCAT_ADAPTER_LEGACY_LATEST_URL="https://github.com/xiowo/napcat-plugin-gscore-adapter/releases/latest/download/napcat-plugin-gscore-adapter.zip"
readonly NAPCAT_ADAPTER_PINNED_URL="https://github.com/xiowo/napcat-plugin-gscore-adapter/releases/download/v1.3.3/napcat-plugin-gscore-adapter.zip"
readonly NAPCAT_ADAPTER_PINNED_SHA256="1776762d0ed8d16ddb8228b98f599c5fa9d166c4a34df5bb0c8f1e2ddd2387ef"
readonly BOTSHEPHERD_IMAGE_DEFAULT="ghcr.io/gufei233/botshepherd:v1.2.1-docker.1"
readonly GSCORE_QQOFFICIAL_COMMIT="2d582f6478a0c0d94aa31d7151c0acabce65ea21"
readonly NAG_MIMO_CONSOLE_COMMIT="${MIMO_CONSOLE_COMMIT:-acd83708b875245ba26617ed6cd7c622b59d1949}"
readonly NAG_MIMO_CONSOLE_REPOSITORY="${MIMO_CONSOLE_REPOSITORY:-gufei233/nonebot-plugin-mimo-console}"
readonly NAG_MIMO_CONSOLE_GIT_URL="${MIMO_CONSOLE_GIT_URL:-https://github.com/gufei233/nonebot-plugin-mimo-console.git}"
readonly DATA_ROOT_MARKER_NAME=".nag-managed-data-root"
readonly DATA_ROOT_MARKER_VALUE="NAG_DATA_ROOT_V1"
readonly INSTALL_LOCK_DIR="${STATE_DIR}/install.lock"

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
NAG_CN_MODE=""
UNINSTALL_TARGET=""
PURGE_DATA=0
PURGE_STATE=0
NONEBOT_PLUGIN_INPUT=""
NONEBOT_PLUGIN_IMPORT=""
NONEBOT_PLUGIN_TARGET=""

log() {
  printf '[NAG] %s\n' "$*"
}

warn() {
  printf '[NAG] 警告：%s\n' "$*" >&2
}

wait_progress() {
  local label="$1"
  local attempt="$2"
  local max_attempts="$3"
  local interval="$4"
  local remaining=$(((max_attempts - attempt + 1) * interval))

  if [[ -t 2 ]]; then
    printf '\r[NAG] %s，剩余最多 %d 秒... ' "$label" "$remaining" >&2
  elif ((attempt == 1 || attempt % 5 == 0)); then
    printf '[NAG] %s，剩余最多 %d 秒...\n' "$label" "$remaining" >&2
  fi
}

clear_wait_progress() {
  if [[ -t 2 ]]; then
    printf '\r\033[K' >&2
  fi
}

die() {
  printf '[NAG] 错误：%s\n' "$*" >&2
  exit 1
}

# set -E 使 ERR trap 传播进函数与子 shell；die 走 exit 不触发本 trap，
# 因此只有未被兜底的命令失败才会打印这段排查提示。
on_error() {
  local exit_code="$1"
  local line="$2"
  local cmd="$3"
  printf '[NAG] 命令执行失败（退出码 %s，install.sh 第 %s 行）：%s\n' \
    "$exit_code" "$line" "$cmd" >&2
  printf '[NAG] 排查提示：可运行 docker compose -p <项目名> logs --tail 100 查看容器日志（项目名通常为 nag、ng 或 nag-qqofficial）\n' >&2
}
trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

release_installer_lock() {
  [[ -d "$INSTALL_LOCK_DIR" && ! -L "$INSTALL_LOCK_DIR" ]] || return 0
  rm -f -- "${INSTALL_LOCK_DIR}/pid" "${INSTALL_LOCK_DIR}/start_ticks"
  rmdir -- "$INSTALL_LOCK_DIR" 2>/dev/null || true
}

process_start_ticks() {
  local pid="$1"

  [[ "$pid" =~ ^[1-9][0-9]*$ && -r "/proc/${pid}/stat" ]] || return 1
  awk '{print $22; exit}' "/proc/${pid}/stat" 2>/dev/null
}

write_installer_lock_identity() {
  local start_ticks

  start_ticks="$(process_start_ticks "$$")" \
    || die "无法读取当前安装进程身份"
  printf '%s\n' "$$" >"${INSTALL_LOCK_DIR}/pid"
  printf '%s\n' "$start_ticks" >"${INSTALL_LOCK_DIR}/start_ticks"
}

installer_lock_owner_is_active() {
  local owner_pid="$1"
  local saved_start_ticks=""
  local current_start_ticks=""
  local command_line=""

  [[ "$owner_pid" =~ ^[1-9][0-9]*$ ]] || return 1
  kill -0 "$owner_pid" 2>/dev/null || return 1
  current_start_ticks="$(process_start_ticks "$owner_pid" || true)"
  [[ -n "$current_start_ticks" ]] || return 1

  if [[ -f "${INSTALL_LOCK_DIR}/start_ticks" \
    && ! -L "${INSTALL_LOCK_DIR}/start_ticks" ]]; then
    read -r saved_start_ticks <"${INSTALL_LOCK_DIR}/start_ticks" || true
    [[ -n "$saved_start_ticks" \
      && "$saved_start_ticks" == "$current_start_ticks" ]]
    return
  fi

  # 兼容旧版只有 PID 的锁；同时避免 PID 被宿主机或其他命名空间复用时误判。
  if [[ -r "/proc/${owner_pid}/cmdline" ]]; then
    command_line="$(tr '\0' ' ' <"/proc/${owner_pid}/cmdline" 2>/dev/null || true)"
  fi
  [[ "$command_line" == *"install.sh"* ]]
}

acquire_installer_lock() {
  local owner_pid=""

  mkdir -p -- "$STATE_DIR"
  if mkdir -- "$INSTALL_LOCK_DIR" 2>/dev/null; then
    write_installer_lock_identity
    trap release_installer_lock EXIT
    return 0
  fi

  [[ -d "$INSTALL_LOCK_DIR" && ! -L "$INSTALL_LOCK_DIR" ]] || \
    die "安装锁路径异常：${INSTALL_LOCK_DIR}"
  if [[ -f "${INSTALL_LOCK_DIR}/pid" && ! -L "${INSTALL_LOCK_DIR}/pid" ]]; then
    read -r owner_pid <"${INSTALL_LOCK_DIR}/pid" || true
  fi
  if installer_lock_owner_is_active "$owner_pid"; then
    die "已有 NAG 安装或维护任务正在运行（PID ${owner_pid}）；请等待其完成后重试"
  fi

  rm -f -- "${INSTALL_LOCK_DIR}/pid" "${INSTALL_LOCK_DIR}/start_ticks"
  if rmdir -- "$INSTALL_LOCK_DIR" 2>/dev/null \
    && mkdir -- "$INSTALL_LOCK_DIR" 2>/dev/null; then
    write_installer_lock_identity
    trap release_installer_lock EXIT
    return 0
  fi
  die "检测到无法安全清理的旧安装锁：${INSTALL_LOCK_DIR}"
}

usage() {
  cat <<'EOF'
用法：bash install.sh [选项]

NAG/NG 交互式部署与维护脚本。

选项：
  --mode MODE   运行模式：
                  guided           组件化交互安装（默认）
                  astrbot          NapCat + AstrBot + GsCore（AstrBot 适配器）
                  hybrid           NapCat + AstrBot + GsCore（NapCat 适配器）
                  napcat           NapCat + GsCore（NapCat 适配器，NG 轻量版）
                  nonebot          NapCat + NoneBot + GsCore（NoneBot 适配器）
                  nonebot-napcat   NapCat + NoneBot + GsCore（NapCat 适配器）
                  qqofficial-nonebot
                                   QQ 官方机器人 + NoneBot QQ 适配器 + GsCore
                  qqofficial-direct
                                   QQ 官方机器人 + gscore-qqofficial + GsCore
                  botshepherd-ports
                                   管理现有 BotShepherd 部署的宿主机端口映射
                  nonebot-plugin   打开官方 Docker NoneBot 的 Mimo Console 插件管理入口
                  status           查看各部署的容器状态与访问地址
                  uninstall        卸载部署（可选删除数据目录与状态文件）
  --botshepherd 在包含 AstrBot/NoneBot 的模式中加入 BotShepherd
  --yes         非交互模式，可选问题按推荐值回答
  --master-qq QQ
                GsCore 与 NapCat GScore 适配器的主人 QQ，多个用英文逗号分隔
  --bot-qq QQ   NapCat 登录的机器人 QQ，持久化后重建容器可快速登录
  --cn          按中国大陆网络环境处理（Docker 用阿里云安装源、配置镜像加速、
                鸣潮插件与 PyPI 使用国内源）
  --no-cn       强制按国际网络环境处理
  --target T    配合 --mode uninstall 使用：nag、ng、nag-qqofficial 或 all
  --plugin SPEC 仅兼容旧版 NAG NoneBot；官方 Docker 项目请在 Mimo Console 中管理
  --plugin-import MODULE
                覆盖自动识别的 Python 导入名（非标准插件仓库可使用）
  --plugin-target CONTAINER|all
                无人值守时指定 NoneBot 容器名；多个实例也可选择 all
  --purge-data  卸载时同时删除数据目录（不可恢复；非交互卸载默认保留）
  --purge-state 卸载时同时删除安装器状态文件（不含 NapCat 身份文件）
  --dry-run     只打印所选计划，不改动主机
  -h, --help    显示本帮助

安装器的私有 Compose 环境保存在 .installer/ 下。
QQ 官方凭据可通过环境变量 QQ_APP_ID、QQ_APP_SECRET、QQ_TOKEN（仅 NoneBot 路线）
提供，以实现无人值守安装。个人 QQ 登录与 GsCore 管理员注册仍需在 WebUI 手动完成。
安装前会自动检测 Docker 环境，缺失时可自动安装（大陆网络自动改用国内镜像源）。
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
    --cn)
      NAG_CN_MODE=1
      shift
      ;;
    --no-cn)
      NAG_CN_MODE=0
      shift
      ;;
    --target)
      (($# >= 2)) || die "--target 需要一个值"
      UNINSTALL_TARGET="$2"
      shift 2
      ;;
    --plugin)
      (($# >= 2)) || die "--plugin 需要一个值"
      NONEBOT_PLUGIN_INPUT="$2"
      shift 2
      ;;
    --plugin-import)
      (($# >= 2)) || die "--plugin-import 需要一个值"
      NONEBOT_PLUGIN_IMPORT="$2"
      shift 2
      ;;
    --plugin-target)
      (($# >= 2)) || die "--plugin-target 需要一个值"
      NONEBOT_PLUGIN_TARGET="$2"
      shift 2
      ;;
    --purge-data)
      PURGE_DATA=1
      shift
      ;;
    --purge-state)
      PURGE_STATE=1
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
      die "未知选项：$1"
      ;;
  esac
done

choose_mode() {
  local menu_choice=""

  if [[ -z "$MODE" ]]; then
    [[ -t 0 ]] || die "当前不是交互式终端；请通过 --mode 指定模式，必要时加 --yes"
    cat <<'EOF'

NAG 安装与维护
  1) 安装、更新或调整机器人部署
  2) 管理 NoneBot 插件（Mimo Console）
  3) 查看部署状态
  4) 管理 BotShepherd 端口
  5) 卸载部署
  6) 退出
EOF
    while true; do
      read -r -p "请选择操作 [1-6]: " menu_choice
      case "$menu_choice" in
        1) MODE="guided"; break ;;
        2) MODE="nonebot-plugin"; break ;;
        3) MODE="status"; break ;;
        4) MODE="botshepherd-ports"; break ;;
        5) MODE="uninstall"; break ;;
        6) log "已退出"; exit 0 ;;
        *) warn "请输入 1 到 6 之间的有效选项" ;;
      esac
    done
  fi

  case "$MODE" in
    guided|botshepherd-ports|status) ;;
    *)
      if (( ! ASSUME_YES )) && [[ ! -t 0 ]]; then
        die "模式 '$MODE' 需要交互输入；无人值守安装请加 --yes（以及必需的选项或环境变量）"
      fi
      ;;
  esac
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

guided_state_valid() {
  local state_file="$1"
  local use_personal
  local use_official
  local personal_adapter
  local official_adapter
  local enable_astrbot
  local enable_nonebot
  local use_botshepherd

  [[ -f "$state_file" && ! -L "$state_file" ]] || return 1
  [[ "$(env_value NAG_GUIDED_STATE_VERSION "$state_file")" == "2" ]] || return 1
  use_personal="$(env_value USE_PERSONAL "$state_file")"
  use_official="$(env_value USE_OFFICIAL "$state_file")"
  personal_adapter="$(env_value PERSONAL_ADAPTER "$state_file")"
  official_adapter="$(env_value OFFICIAL_ADAPTER "$state_file")"
  enable_astrbot="$(env_value ENABLE_ASTRBOT "$state_file")"
  enable_nonebot="$(env_value ENABLE_NONEBOT "$state_file")"
  use_botshepherd="$(env_value BOTSHEPHERD_ENABLED "$state_file")"
  [[ "$use_personal" == "0" || "$use_personal" == "1" ]] || return 1
  [[ "$use_official" == "0" || "$use_official" == "1" ]] || return 1
  [[ "$personal_adapter" == "none" || "$personal_adapter" == "napcat" \
    || "$personal_adapter" == "nonebot" || "$personal_adapter" == "astrbot" ]] \
    || return 1
  [[ "$official_adapter" == "none" || "$official_adapter" == "nonebot" \
    || "$official_adapter" == "direct" ]] || return 1
  [[ "$enable_astrbot" == "0" || "$enable_astrbot" == "1" ]] || return 1
  [[ "$enable_nonebot" == "0" || "$enable_nonebot" == "1" ]] || return 1
  [[ "$use_botshepherd" == "0" || "$use_botshepherd" == "1" ]] || return 1
  guided_validate_topology \
    "$use_personal" "$use_official" "$personal_adapter" "$official_adapter" \
    "$enable_astrbot" "$enable_nonebot" "$use_botshepherd"
}

guided_env_valid() {
  local env_file="$1"
  local data_root

  [[ -f "$env_file" && ! -L "$env_file" ]] || return 1
  [[ "$(env_value NAG_GUIDED_STATE_VERSION "$env_file")" == "2" ]] || return 1
  data_root="$(env_value DATA_ROOT "$env_file")"
  [[ "$data_root" == /* ]] || return 1
}

container_started_at() {
  "$DOCKER_BIN" inspect --format '{{.State.StartedAt}}' "$1" 2>/dev/null || true
}

container_belongs_to_compose_project() {
  local container_name="$1"
  local expected_project="$2"
  local actual_project

  actual_project="$(
    "$DOCKER_BIN" inspect \
      --format '{{index .Config.Labels "com.docker.compose.project"}}' \
      "$container_name" 2>/dev/null || true
  )"
  [[ "$actual_project" == "$expected_project" ]]
}

remove_legacy_compose_container() {
  local container_name="$1"
  local expected_project="$2"
  local expected_service="$3"
  local actual_project=""
  local actual_service=""

  actual_project="$(
    "$DOCKER_BIN" inspect \
      --format '{{index .Config.Labels "com.docker.compose.project"}}' \
      "$container_name" 2>/dev/null || true
  )"
  actual_service="$(
    "$DOCKER_BIN" inspect \
      --format '{{index .Config.Labels "com.docker.compose.service"}}' \
      "$container_name" 2>/dev/null || true
  )"
  [[ "$actual_project" == "$expected_project" \
    && "$actual_service" == "$expected_service" ]] || return 1
  "$DOCKER_BIN" rm --force "$container_name" >/dev/null \
    || die "无法移除旧版 Compose 容器：${container_name}"
}

nag_managed_container_exists() {
  local container_name
  local compose_project

  for container_name in \
    nag-gscore nag-napcat nag-astrbot nag-botshepherd \
    nag-nonebot nag-nonebot-qqofficial nag-gscore-qqofficial; do
    compose_project="$(
      "$DOCKER_BIN" inspect \
        --format '{{index .Config.Labels "com.docker.compose.project"}}' \
        "$container_name" 2>/dev/null || true
    )"
    case "$compose_project" in
      nag|nag-nonebot-personal|nag-nonebot-official|nag-qqofficial)
        return 0
        ;;
    esac
  done
  return 1
}

nag_named_container_exists() {
  local container_name

  for container_name in \
    nag-gscore nag-napcat nag-astrbot nag-botshepherd \
    nag-nonebot nag-nonebot-qqofficial nag-gscore-qqofficial; do
    if [[ -n "$("$DOCKER_BIN" inspect --format '{{.Name}}' \
      "$container_name" 2>/dev/null || true)" ]]; then
      return 0
    fi
  done
  return 1
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
  [[ "$value" =~ ^[0-9]+$ ]] || die "$name 必须是数字"
  ((10#$value >= 1 && 10#$value <= 65535)) || die "$name 必须在 1-65535 之间"
}

validate_single_line() {
  local name="$1"
  local value="$2"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "$name 不能包含换行"
}

normalize_data_root() {
  local data_root="$1"

  command -v realpath >/dev/null 2>&1 \
    || die "安全处理 DATA_ROOT 需要 realpath 命令（通常由 coreutils 提供）"
  realpath -m -- "$data_root"
}

data_root_is_critical() {
  case "$1" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

validated_data_root() {
  local data_root="$1"
  local normalized

  [[ "$data_root" == /* ]] || die "DATA_ROOT 必须是绝对路径"
  normalized="$(normalize_data_root "$data_root")"
  if data_root_is_critical "$normalized"; then
    die "DATA_ROOT ${data_root} 解析为系统关键路径 ${normalized}，请使用专用子目录"
  fi
  printf '%s' "$normalized"
}

mark_data_root() {
  local data_root="$1"
  local normalized
  local marker
  local temporary
  local entry
  local name

  normalized="$(normalize_data_root "$data_root")"
  marker="${normalized}/${DATA_ROOT_MARKER_NAME}"
  if [[ -e "$marker" ]]; then
    if [[ -f "$marker" && ! -L "$marker" ]] \
      && [[ "$(head -n 1 -- "$marker" 2>/dev/null || true)" == "$DATA_ROOT_MARKER_VALUE" ]]; then
      return 0
    fi
    warn "数据目录中存在无效安全标记，拒绝覆盖：${marker}"
    return 0
  fi
  for entry in "$normalized"/* "$normalized"/.[!.]* "$normalized"/..?*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    name="${entry##*/}"
    case "$name" in
      gscore|napcat|astrbot|nonebot|nonebot-qqofficial|gscore-qqofficial|botshepherd)
        ;;
      *)
        warn "数据根目录 ${normalized} 含非 NAG 条目 ${name}，为避免误删不写入安全标记；安装可继续，但 --purge-data 将拒绝删除整个目录"
        return 0
        ;;
    esac
  done
  temporary="$(mktemp)"
  printf '%s\n' "$DATA_ROOT_MARKER_VALUE" >"$temporary"
  if ! as_root install -m 0600 -o "$(id -u)" -g "$(id -g)" \
    "$temporary" "$marker"; then
    rm -f -- "$temporary"
    die "无法写入数据目录安全标记：${marker}"
  fi
  rm -f -- "$temporary"
}

as_root() {
  if ((EUID == 0)); then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    die "需要 root 权限执行：$*（当前非 root 且未安装 sudo）"
  fi
}

detect_pkg_manager() {
  local mgr
  for mgr in apt-get dnf yum zypper apk; do
    if command -v "$mgr" >/dev/null 2>&1; then
      printf '%s' "$mgr"
      return 0
    fi
  done
  return 0
}

pkg_install() {
  local mgr
  mgr="$(detect_pkg_manager)"
  case "$mgr" in
    apt-get)
      as_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
      as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
      ;;
    dnf) as_root dnf install -y "$@" ;;
    yum) as_root yum install -y "$@" ;;
    zypper) as_root zypper --non-interactive install "$@" ;;
    apk) as_root apk add "$@" ;;
    *)
      warn "未识别的包管理器，无法自动安装：$*"
      return 1
      ;;
  esac
}

ensure_host_cmd() {
  local cmd="$1"
  local pkg="$2"

  if command -v "$cmd" >/dev/null 2>&1; then
    return 0
  fi
  warn "缺少命令：${cmd}"
  if prompt_yes_no "通过系统包管理器自动安装 ${pkg}" y; then
    if pkg_install "$pkg" && command -v "$cmd" >/dev/null 2>&1; then
      log "${pkg} 安装完成"
      return 0
    fi
  fi
  die "缺少 ${cmd}；请先手动安装（如：apt-get install -y ${pkg} 或 yum install -y ${pkg}）"
}

probe_cn_network() {
  command -v curl >/dev/null 2>&1 || return 1
  if curl -fsSL -m 4 -o /dev/null https://www.google.com/generate_204 2>/dev/null; then
    return 1
  fi
  return 0
}

resolve_cn_mode() {
  local detected=0
  local saved
  local default_answer

  if [[ -n "$NAG_CN_MODE" ]]; then
    return 0
  fi
  saved="$(env_value NAG_CN "$PREFLIGHT_STATE_FILE" || true)"
  if [[ "$saved" == "0" || "$saved" == "1" ]]; then
    NAG_CN_MODE="$saved"
    return 0
  fi
  # dry-run 不探测网络、不提问、不落盘，保持输出稳定
  if ((DRY_RUN)); then
    NAG_CN_MODE=0
    return 0
  fi
  if probe_cn_network; then
    detected=1
    log "检测到国际网络访问受限，推测服务器位于中国大陆网络环境"
  fi
  if [[ -t 0 ]] && (( ! ASSUME_YES )); then
    default_answer="$([[ "$detected" == 1 ]] && printf y || printf n)"
    if prompt_yes_no "是否按中国大陆网络环境优化（Docker 安装源/镜像加速/国内 PyPI 源）" "$default_answer"; then
      NAG_CN_MODE=1
    else
      NAG_CN_MODE=0
    fi
  else
    NAG_CN_MODE="$detected"
    log "按$([[ "$NAG_CN_MODE" == "1" ]] && printf 大陆 || printf 国际)网络环境处理（可用 --cn / --no-cn 覆盖）"
  fi
  mkdir -p "$STATE_DIR"
  printf '# 由 install.sh 生成的环境预检记录\nNAG_CN=%s\n' "$NAG_CN_MODE" >"$PREFLIGHT_STATE_FILE"
  chmod 600 "$PREFLIGHT_STATE_FILE"
  return 0
}

cn_enabled() {
  resolve_cn_mode
  [[ "$NAG_CN_MODE" == "1" ]]
}

cnb_mirror_default() {
  if cn_enabled; then
    printf 'y'
  else
    printf 'n'
  fi
}

gscore_python_index() {
  if cn_enabled; then
    printf 'https://pypi.tuna.tsinghua.edu.cn/simple/'
  else
    printf 'https://pypi.org/simple/'
  fi
}

ensure_uv_runtime() {
  local installer

  if command -v uv >/dev/null 2>&1; then
    return 0
  fi
  ensure_host_cmd curl curl
  installer="$(mktemp)"
  log "下载 uv 官方安装脚本"
  if ! curl -LsSf --connect-timeout 15 https://astral.sh/uv/install.sh \
    -o "$installer"; then
    rm -f "$installer"
    die "下载 uv 官方安装脚本失败；请先安装 uv 后重试"
  fi
  if ! as_root env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 \
    sh "$installer"; then
    rm -f "$installer"
    die "uv 安装失败；请参考 https://docs.astral.sh/uv/ 手动安装"
  fi
  rm -f "$installer"
  command -v uv >/dev/null 2>&1 || \
    die "uv 安装完成后仍无法从 PATH 找到"
}

json_array_from_csv() {
  local csv="$1"
  python3 - "$csv" <<'PY'
import json
import sys

print(
    json.dumps(
        [item.strip() for item in sys.argv[1].split(",") if item.strip()],
        ensure_ascii=False,
        separators=(",", ":"),
    ),
    end="",
)
PY
}

write_official_nonebot_environment() {
  local kind="$1"
  local output="$2"
  local superusers_csv="$3"
  local bot_id="$4"
  local gscore_token="$5"
  local command_start_csv="$6"
  local instance_id="$7"
  local qq_app_id="${8:-}"
  local qq_app_secret="${9:-}"
  local qq_token="${10:-}"
  local qq_is_sandbox="${11:-false}"
  local superusers_json
  local command_start_json
  local qq_bots_json="[]"
  local temporary="${output}.tmp"

  superusers_json="$(json_array_from_csv "$superusers_csv")"
  command_start_json="$(json_array_from_csv "$command_start_csv")"
  if [[ "$kind" == "official" ]]; then
    qq_bots_json="$(
      python3 - "$qq_app_id" "$qq_app_secret" "$qq_token" <<'PY'
import json
import sys

print(
    json.dumps(
        [
            {
                "id": sys.argv[1],
                "secret": sys.argv[2],
                "token": sys.argv[3],
                "use_websocket": True,
                "intent": {
                    "guilds": False,
                    "guild_members": False,
                    "guild_messages": False,
                    "guild_message_reactions": False,
                    "direct_message": True,
                    "open_forum_event": False,
                    "audio_live_member": False,
                    "c2c_group_at_messages": True,
                    "interaction": False,
                    "message_audit": False,
                    "forum_event": False,
                    "audio_action": False,
                    "at_messages": True,
                },
            }
        ],
        ensure_ascii=False,
        separators=(",", ":"),
    ),
    end="",
)
PY
    )"
  fi

  cat >"$temporary" <<EOF
# Generated by NAG for an official nb-cli Docker project.
ENVIRONMENT=prod
HOST=0.0.0.0
PORT=8080
DRIVER=~fastapi+~httpx+~websockets
SUPERUSERS=$superusers_json
COMMAND_START=$command_start_json
GSUID_CORE_HOST=gscore
GSUID_CORE_PORT=8765
GSUID_CORE_BOTID=$bot_id
GSUID_CORE_WS_TOKEN=$gscore_token
GSUID_CORE_REPEAT=true
MIMO_CONSOLE_DEPLOYMENT_MODE=auto
MIMO_CONSOLE_INSTANCE_ID=$instance_id
MIMO_CONSOLE_AGENT_SOCKET=/run/mimo-agent/agent.sock
MIMO_CONSOLE_AGENT_TOKEN_FILE=/run/secrets/mimo-agent-token
EOF
  if [[ "$kind" == "official" ]]; then
    cat >>"$temporary" <<EOF
QQ_IS_SANDBOX=$qq_is_sandbox
QQ_BOTS=$qq_bots_json
EOF
  fi
  chmod 600 "$temporary"
  mv -f "$temporary" "$output"
}

prepare_official_nonebot_instance() {
  local kind="$1"
  local with_gs="$2"
  local project_dir="$3"
  local environment_file="$4"
  local data_dir="$5"
  local cache_dir="$6"
  local compose_project="$7"
  local container_name="$8"
  local network_alias="$9"
  local network_name="${10}"
  local web_port="${11}"
  local token_file="${12}"
  local image_repository="${13}"

  ensure_uv_runtime
  ensure_host_cmd git git
  ensure_host_cmd python3 python3
  ensure_host_cmd openssl openssl
  validate_port MIMO_CONSOLE_PORT "$web_port"

  as_root env \
    MIMO_CONSOLE_COMMIT="$NAG_MIMO_CONSOLE_COMMIT" \
    MIMO_CONSOLE_REPOSITORY="$NAG_MIMO_CONSOLE_REPOSITORY" \
    bash "${SCRIPT_DIR}/scripts/prepare-nonebot-official-project.sh" \
    --kind "$kind" \
    --with-gs "$with_gs" \
    --project-dir "$project_dir" \
    --environment-file "$environment_file" \
    --data-dir "$data_dir" \
    --cache-dir "$cache_dir" \
    --compose-project "$compose_project" \
    --container-name "$container_name" \
    --network "$network_name" \
    --network-alias "$network_alias" \
    --web-port "$web_port" \
    --token-file "$token_file" \
    --image-repository "$image_repository"

  as_root env \
    MIMO_CONSOLE_COMMIT="$NAG_MIMO_CONSOLE_COMMIT" \
    MIMO_CONSOLE_GIT_URL="$NAG_MIMO_CONSOLE_GIT_URL" \
    bash "${SCRIPT_DIR}/scripts/register-mimo-agent-instance.sh" \
    --instance-id "$kind" \
    --project-dir "$project_dir" \
    --compose-project "$compose_project" \
    --image-repository "$image_repository" \
    --health-port "$web_port" \
    --token-file "$token_file"
}

official_nonebot_cli() {
  local project_dir="$1"
  local compose_project="$2"
  local action
  shift 2
  action="${1:-}"
  as_root env \
    COMPOSE_PROJECT_NAME="$compose_project" \
    COMPOSE_FILE=docker-compose.yml:docker-compose.nag.yml \
    uvx --directory "$project_dir" \
      --from "nb-cli==1.7.4" \
      --with "nb-cli-plugin-docker==0.6.1" \
      nb docker "$@"

  # nb-cli-plugin-docker 0.6.1 may return success even when the nested Compose
  # build failed. Re-run the cached build through Compose so its real exit code
  # reaches the installer, and verify that `up` actually created a live service.
  if [[ "$action" == "build" ]]; then
    as_root "$DOCKER_BIN" compose \
      --project-directory "$project_dir" \
      -p "$compose_project" \
      -f "${project_dir}/docker-compose.yml" \
      -f "${project_dir}/docker-compose.nag.yml" \
      build
  elif [[ "$action" == "up" ]]; then
    [[ -n "$(
      as_root "$DOCKER_BIN" compose \
        --project-directory "$project_dir" \
        -p "$compose_project" \
        -f "${project_dir}/docker-compose.yml" \
        -f "${project_dir}/docker-compose.nag.yml" \
        ps --status running -q nonebot 2>/dev/null || true
    )" ]] || die "官方 NoneBot Compose 服务未成功启动：${compose_project}"
  fi
}

restart_official_nonebot_instance() {
  local project_dir="$1"
  local compose_project="$2"
  local container_name="$3"
  local state=""

  as_root "$DOCKER_BIN" compose \
    --project-directory "$project_dir" \
    -p "$compose_project" \
    -f "${project_dir}/docker-compose.yml" \
    -f "${project_dir}/docker-compose.nag.yml" \
    restart nonebot

  for ((attempt = 1; attempt <= 90; attempt++)); do
    state="$(
      as_root "$DOCKER_BIN" inspect \
        --format '{{.State.Running}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
        "$container_name" 2>/dev/null || true
    )"
    if [[ "$state" == "true|healthy" || "$state" == "true|none" ]]; then
      clear_wait_progress
      return 0
    fi
    wait_progress "等待 ${container_name} 恢复健康" "$attempt" 90 2
    sleep 2
  done
  clear_wait_progress

  as_root "$DOCKER_BIN" logs --tail 120 "$container_name" 2>/dev/null || true
  die "官方 NoneBot Compose 服务重启后未恢复健康：${compose_project}"
}

wait_mimo_setup_token() {
  local container_name="$1"
  local started_at
  local configured
  local token
  local attempt
  local -a log_args=()

  started_at="$(
    "$DOCKER_BIN" inspect --format '{{.State.StartedAt}}' \
      "$container_name" 2>/dev/null || true
  )"
  [[ -z "$started_at" ]] || log_args=(--since "$started_at")
  for ((attempt = 1; attempt <= 20; attempt++)); do
    configured="$(
      "$DOCKER_BIN" exec "$container_name" python -c '
import json
from urllib.request import urlopen
payload = json.load(
    urlopen("http://127.0.0.1:8080/mimo-console/api/auth/status", timeout=3)
)
print("true" if payload.get("configured") else "false", end="")
' 2>/dev/null || true
    )"
    if [[ "$configured" == "true" ]]; then
      clear_wait_progress
      return 1
    fi

    token="$(
      "$DOCKER_BIN" logs "${log_args[@]}" "$container_name" 2>&1 \
        | sed -n \
          's/.*\[Mimo Console\] \([A-Za-z0-9_-]\{24,128\}\).*/\1/p' \
        | tail -n 1
    )"
    if [[ -n "$token" ]]; then
      clear_wait_progress
      printf '%s' "$token"
      return 0
    fi
    wait_progress "等待 ${container_name} 的 Mimo Console 初始化令牌" \
      "$attempt" 20 1
    sleep 1
  done
  clear_wait_progress
  return 1
}

install_docker_engine() {
  local script_file

  ensure_host_cmd curl curl
  script_file="$(mktemp)"
  log "下载 Docker 官方安装脚本（get.docker.com）"
  if ! curl -fsSL --connect-timeout 15 https://get.docker.com -o "$script_file"; then
    rm -f "$script_file"
    die "下载 Docker 安装脚本失败。请手动安装后重跑本脚本：
  国际网络：curl -fsSL https://get.docker.com | sh
  大陆网络：curl -fsSL https://get.docker.com -o get-docker.sh && sh get-docker.sh --mirror Aliyun"
  fi
  if cn_enabled; then
    log "使用阿里云软件源安装 Docker（大陆网络模式）"
    if ! as_root sh "$script_file" --mirror Aliyun; then
      rm -f "$script_file"
      die "Docker 自动安装失败；可尝试手动执行：curl -fsSL https://get.docker.com -o get-docker.sh && sh get-docker.sh --mirror Aliyun"
    fi
  else
    log "使用官方软件源安装 Docker"
    if ! as_root sh "$script_file"; then
      rm -f "$script_file"
      die "Docker 自动安装失败；可尝试手动执行：curl -fsSL https://get.docker.com | sh"
    fi
  fi
  rm -f "$script_file"
  command -v "$DOCKER_BIN" >/dev/null 2>&1 \
    || die "安装流程结束但仍未找到 docker 命令；请检查上方安装日志"
  log "Docker 安装完成：$("$DOCKER_BIN" --version 2>/dev/null || printf '未知版本')"
  return 0
}

ensure_docker_daemon() {
  local attempt

  if "$DOCKER_BIN" info >/dev/null 2>&1; then
    return 0
  fi
  log "Docker 守护进程未运行，尝试启动"
  if command -v systemctl >/dev/null 2>&1; then
    as_root systemctl enable --now docker >/dev/null 2>&1 || true
  elif command -v service >/dev/null 2>&1; then
    as_root service docker start >/dev/null 2>&1 || true
  fi
  for ((attempt = 1; attempt <= 10; attempt++)); do
    if "$DOCKER_BIN" info >/dev/null 2>&1; then
      log "Docker 守护进程已启动"
      return 0
    fi
    sleep 2
  done
  die "无法连接 Docker 守护进程；请手动检查：systemctl status docker（或 service docker status）"
}

ensure_compose_plugin() {
  if "$DOCKER_BIN" compose version >/dev/null 2>&1; then
    return 0
  fi
  warn "检测到 Docker 但缺少 Compose V2 插件"
  if prompt_yes_no "尝试通过系统包管理器安装 docker-compose-plugin" y; then
    if pkg_install docker-compose-plugin \
      && "$DOCKER_BIN" compose version >/dev/null 2>&1; then
      log "Docker Compose V2 安装完成"
      return 0
    fi
    warn "docker-compose-plugin 安装未成功"
  fi
  die "需要 Docker Compose V2。可重跑 Docker 官方安装脚本补齐：curl -fsSL https://get.docker.com | sh（大陆网络加 --mirror Aliyun）"
}

restart_docker_daemon() {
  local attempt

  if command -v systemctl >/dev/null 2>&1; then
    as_root systemctl restart docker
  elif command -v service >/dev/null 2>&1; then
    as_root service docker restart
  else
    warn "未找到 systemctl/service，请手动重启 Docker"
    return 1
  fi
  for ((attempt = 1; attempt <= 15; attempt++)); do
    if "$DOCKER_BIN" info >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

nag_containers_running() {
  local proj
  for proj in nag ng nag-qqofficial; do
    if [[ -n "$("$DOCKER_BIN" ps -q --filter "label=com.docker.compose.project=${proj}" 2>/dev/null)" ]]; then
      return 0
    fi
  done
  return 1
}

configure_registry_mirror() {
  local daemon_json="/etc/docker/daemon.json"
  local mirrors_default="https://docker.1ms.run,https://docker.m.daocloud.io"
  local mirrors_csv=""
  local mirrors_json=""
  local mirror
  local merged_tmp
  local -a mirror_list=()

  if "$DOCKER_BIN" info 2>/dev/null | grep -qi 'Registry Mirrors'; then
    log "Docker 已配置镜像加速，跳过"
    return 0
  fi
  if [[ -f "$daemon_json" ]] && grep -q 'registry-mirrors' "$daemon_json" 2>/dev/null; then
    log "检测到 ${daemon_json} 已包含 registry-mirrors，跳过"
    return 0
  fi
  if ! prompt_yes_no "配置 Docker Hub 镜像加速（大陆拉取镜像通常必需；默认使用第三方公共镜像源）" y; then
    log "已跳过镜像加速；如拉取镜像超时，可重跑脚本或手动配置 ${daemon_json}"
    return 0
  fi
  mirrors_csv="$(prompt_value "镜像加速地址（多个用英文逗号分隔，可换成自己的阿里云加速地址）" "$mirrors_default")"
  IFS=',' read -r -a mirror_list <<<"$mirrors_csv"
  for mirror in "${mirror_list[@]}"; do
    mirror="${mirror//[[:space:]]/}"
    if [[ -z "$mirror" ]]; then
      continue
    fi
    [[ "$mirror" =~ ^https?:// ]] || die "镜像加速地址需以 http(s):// 开头：${mirror}"
    mirrors_json+="\"${mirror}\", "
  done
  mirrors_json="[${mirrors_json%, }]"
  if [[ "$mirrors_json" == "[]" ]]; then
    warn "未提供有效的镜像加速地址，跳过"
    return 0
  fi

  if [[ -f "$daemon_json" ]]; then
    if ! command -v python3 >/dev/null 2>&1; then
      warn "${daemon_json} 已存在且缺少 python3，无法自动合并；请手动加入 \"registry-mirrors\": ${mirrors_json} 后重启 Docker"
      return 0
    fi
    merged_tmp="$(mktemp)"
    if ! as_root python3 -c '
import json, sys
path = sys.argv[1]
mirrors = [m.strip() for m in sys.argv[2].split(",") if m.strip()]
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
data["registry-mirrors"] = mirrors
print(json.dumps(data, indent=2, ensure_ascii=False))
' "$daemon_json" "$mirrors_csv" >"$merged_tmp"; then
      rm -f "$merged_tmp"
      warn "解析 ${daemon_json} 失败（可能不是合法 JSON）；请手动加入 registry-mirrors 后重启 Docker"
      return 0
    fi
    as_root cp "$daemon_json" "${daemon_json}.bak-nag"
    as_root cp "$merged_tmp" "$daemon_json"
    rm -f "$merged_tmp"
  else
    as_root mkdir -p /etc/docker
    printf '{\n  "registry-mirrors": %s\n}\n' "$mirrors_json" | as_root tee "$daemon_json" >/dev/null
  fi
  as_root chmod 644 "$daemon_json"

  if nag_containers_running; then
    warn "重启 Docker 会短暂重启现有容器（机器人闪断数秒后自动恢复）"
    if ! prompt_yes_no "现在重启 Docker 使镜像加速生效" y; then
      warn "配置已写入 ${daemon_json}；请稍后手动重启 Docker（systemctl restart docker）"
      return 0
    fi
  fi
  log "重启 Docker 守护进程以应用镜像加速"
  restart_docker_daemon || die "Docker 重启后未就绪；请手动检查 systemctl status docker"
  if "$DOCKER_BIN" info 2>/dev/null | grep -qi 'Registry Mirrors'; then
    log "镜像加速已生效：${mirrors_csv}"
  else
    warn "已写入 ${daemon_json}，但当前守护进程尚未加载该配置；请手动重启 Docker 后生效"
  fi
  return 0
}

check_resources() {
  local mem_kb=""
  local swap_kb=""
  local docker_root
  local avail_kb=""

  if [[ -r /proc/meminfo ]]; then
    mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
    swap_kb="$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)"
    if [[ "$mem_kb" =~ ^[0-9]+$ ]] && ((mem_kb < 1536 * 1024)); then
      warn "内存较小（$((mem_kb / 1024)) MiB）；构建 NoneBot 镜像或多容器同时运行时可能内存不足"
      if [[ ! "$swap_kb" =~ ^[0-9]+$ ]] || ((swap_kb == 0)); then
        warn "未检测到 swap；建议先创建 swap（如 fallocate -l 2G /swapfile）再继续"
      fi
    fi
  fi
  docker_root="$("$DOCKER_BIN" info -f '{{.DockerRootDir}}' 2>/dev/null || true)"
  docker_root="${docker_root:-/var/lib/docker}"
  [[ -d "$docker_root" ]] || docker_root="/"
  avail_kb="$(df -Pk "$docker_root" 2>/dev/null | awk 'NR == 2 {print $4}')"
  if [[ "$avail_kb" =~ ^[0-9]+$ ]] && ((avail_kb < 5 * 1024 * 1024)); then
    warn "磁盘空间偏低：${docker_root} 所在分区仅剩 $((avail_kb / 1024 / 1024)) GiB，拉取镜像与构建可能失败"
  fi
  return 0
}

# 在进入业务问答前完成环境自检；dry-run 保持零依赖、零改动
preflight_environment() {
  if ((DRY_RUN)); then
    return 0
  fi
  if ! command -v "$DOCKER_BIN" >/dev/null 2>&1; then
    warn "未检测到 Docker"
    if prompt_yes_no "自动安装 Docker（官方安装脚本；大陆网络自动使用阿里云软件源）" y; then
      install_docker_engine
    else
      die "缺少 Docker。手动安装：curl -fsSL https://get.docker.com | sh（大陆网络：sh get-docker.sh --mirror Aliyun），完成后重跑本脚本"
    fi
  fi
  ensure_docker_daemon
  ensure_compose_plugin
  if cn_enabled; then
    configure_registry_mirror
  fi
  check_resources
  return 0
}

port_in_use() {
  local ip="$1"
  local port="$2"

  if [[ -z "$ip" || "$ip" == "0.0.0.0" ]]; then
    ip="127.0.0.1"
  fi
  command -v timeout >/dev/null 2>&1 || return 1
  timeout 1 bash -c "exec 3<>/dev/tcp/${ip}/${port}" 2>/dev/null
}

# 端口提问：校验数值并探测占用；与上次配置相同的端口视为本部署
# 自身的容器在监听，跳过探测避免重跑时误报
prompt_port() {
  local label="$1"
  local value="$2"
  local previous="$3"
  local bind_ip="$4"

  if ((ASSUME_YES)); then
    if [[ -z "$previous" || "$value" != "$previous" ]] \
      && port_in_use "$bind_ip" "$value"; then
      warn "端口 ${value} 疑似已被占用，--yes 模式下将继续使用"
    fi
    printf '%s' "$value"
    return 0
  fi
  while true; do
    value="$(prompt_value "$label" "$value")"
    if [[ ! "$value" =~ ^[0-9]+$ ]] || ((10#$value < 1 || 10#$value > 65535)); then
      warn "${label} 需为 1-65535 之间的数字"
      continue
    fi
    if [[ -n "$previous" && "$value" == "$previous" ]]; then
      break
    fi
    if port_in_use "$bind_ip" "$value"; then
      warn "端口 ${value} 已被其他进程占用"
      if prompt_yes_no "仍然使用端口 ${value}" n; then
        break
      fi
      continue
    fi
    break
  done
  printf '%s' "$value"
}

# 敏感凭据输入：不回显，已有值不再以明文默认值形式打印到终端
prompt_secret() {
  local label="$1"
  local current="$2"
  local value=""

  if ((ASSUME_YES)); then
    printf '%s' "$current"
    return 0
  fi
  if [[ -n "$current" ]]; then
    read -r -s -p "${label}（已配置，回车保留当前值）: " value
  else
    read -r -s -p "${label}: " value
  fi
  printf '\n' >&2
  printf '%s' "${value:-$current}"
}

project_label() {
  case "$1" in
    nag) printf '个人 QQ 部署（guided/预设模式）' ;;
    ng) printf 'NG 轻量部署（napcat 模式）' ;;
    nag-qqofficial) printf 'QQ 官方机器人部署' ;;
    *) printf '%s' "$1" ;;
  esac
}

newest_env_file_for_project() {
  local proj="$1"
  local newest=""
  local name
  local -a names=()

  case "$proj" in
    nag)
      names=(guided.env astrbot.env hybrid.env nonebot.env nonebot-napcat.env
        astrbot-botshepherd.env hybrid-botshepherd.env nonebot-botshepherd.env
        nonebot-napcat-botshepherd.env)
      ;;
    ng) names=(napcat.env) ;;
    nag-qqofficial) names=(qqofficial-nonebot.env qqofficial-direct.env) ;;
  esac
  for name in "${names[@]}"; do
    if [[ -f "${STATE_DIR}/${name}" ]] \
      && { [[ -z "$newest" ]] || [[ "${STATE_DIR}/${name}" -nt "$newest" ]]; }; then
      newest="${STATE_DIR}/${name}"
    fi
  done
  printf '%s' "$newest"
}

status_mode() {
  local proj
  local ids
  local env_file
  local data_root
  local bind_ip
  local port
  local services
  local svc
  local printed=0
  local official_project
  local official_label
  local official_container
  local official_port

  command -v "$DOCKER_BIN" >/dev/null 2>&1 || die "未检测到 Docker，无法查询状态"
  "$DOCKER_BIN" compose version >/dev/null 2>&1 || die "需要 Docker Compose V2"
  "$DOCKER_BIN" info >/dev/null 2>&1 || die "无法连接 Docker 守护进程；请检查服务状态与用户权限"

  for proj in nag ng nag-qqofficial; do
    ids="$("$DOCKER_BIN" compose -p "$proj" ps -aq 2>/dev/null || true)"
    env_file="$(newest_env_file_for_project "$proj")"
    if [[ -z "$ids" && -z "$env_file" ]]; then
      continue
    fi
    printed=1
    printf '\n=== %s（compose 项目：%s）===\n' "$(project_label "$proj")" "$proj"
    if [[ -n "$ids" ]]; then
      "$DOCKER_BIN" compose -p "$proj" ps
    else
      log "没有容器（可能已卸载或尚未部署，仅存在配置文件）"
    fi
    if [[ -n "$env_file" ]]; then
      data_root="$(env_value DATA_ROOT "$env_file" || true)"
      bind_ip="$(env_value BIND_IP "$env_file" || true)"
      bind_ip="${bind_ip:-127.0.0.1}"
      [[ -z "$data_root" ]] || printf '数据目录：%s\n' "$data_root"
      printf '配置文件：%s\n' "$env_file"
      services="$("$DOCKER_BIN" compose -p "$proj" ps --format '{{.Service}}' 2>/dev/null || true)"
      for svc in $services; do
        case "$svc" in
          gscore)
            port="$(env_value GSCORE_PORT "$env_file" || true)"
            [[ -z "$port" ]] || printf 'GsCore WebUI：http://%s:%s/app/\n' "$bind_ip" "$port"
            ;;
          napcat)
            port="$(env_value NAPCAT_WEBUI_PORT "$env_file" || true)"
            [[ -z "$port" ]] || printf 'NapCat WebUI：http://%s:%s\n' "$bind_ip" "$port"
            ;;
          astrbot)
            port="$(env_value ASTRBOT_WEBUI_PORT "$env_file" || true)"
            [[ -z "$port" ]] || printf 'AstrBot WebUI：http://%s:%s\n' "$bind_ip" "$port"
            ;;
          botshepherd)
            port="$(env_value BOTSHEPHERD_WEBUI_PORT "$env_file" || true)"
            [[ -z "$port" ]] || printf 'BotShepherd WebUI：http://%s:%s\n' "$bind_ip" "$port"
            ;;
        esac
      done
    fi
    printf '查看日志：docker compose -p %s logs --tail 100 <服务名>\n' "$proj"
  done

  for official_project in nag-nonebot-personal nag-nonebot-official; do
    official_container="$(
      "$DOCKER_BIN" ps -aq \
        --filter "label=com.docker.compose.project=${official_project}" \
        --filter "label=com.docker.compose.service=nonebot" \
        | head -n 1
    )"
    [[ -n "$official_container" ]] || continue
    printed=1
    if [[ "$official_project" == "nag-nonebot-personal" ]]; then
      official_label="个人 QQ NoneBot（官方 Docker 项目）"
      official_port=18081
    else
      official_label="QQ 官方 NoneBot（官方 Docker 项目）"
      official_port=18082
    fi
    port="$(
      "$DOCKER_BIN" port "$official_container" 8080/tcp 2>/dev/null \
        | head -n 1
    )"
    [[ -z "$port" ]] || official_port="${port##*:}"
    printf '\n=== %s（compose 项目：%s）===\n' \
      "$official_label" "$official_project"
    "$DOCKER_BIN" ps -a \
      --filter "label=com.docker.compose.project=${official_project}" \
      --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
    printf 'Mimo Console：http://127.0.0.1:%s/mimo-console/\n' \
      "$official_port"
    printf '项目由 nb docker generate/build/up 管理；Python 插件与依赖由 Mimo Console 管理。\n'
  done

  if (( ! printed )); then
    log "未检测到任何 NAG 部署"
  fi
  return 0
}

uninstall_data_dir() {
  local data_root="$1"
  local normalized
  local marker
  local purge=0
  local confirm

  if ! normalized="$(normalize_data_root "$data_root")"; then
    warn "无法规范化数据目录路径（${data_root}），跳过删除"
    return 0
  fi
  if data_root_is_critical "$normalized"; then
    warn "数据目录 ${data_root} 解析为系统关键路径 ${normalized}，跳过删除"
    return 0
  fi
  if [[ "$normalized" != /* ]]; then
    warn "数据目录路径异常（${data_root}），跳过删除"
    return 0
  fi
  if [[ ! -e "$normalized" ]]; then
    return 0
  fi
  marker="${normalized}/${DATA_ROOT_MARKER_NAME}"
  if [[ ! -f "$marker" || -L "$marker" ]] \
    || [[ "$(head -n 1 -- "$marker" 2>/dev/null || true)" != "$DATA_ROOT_MARKER_VALUE" ]]; then
    warn "数据目录 ${normalized} 缺少有效的 NAG 安全标记，拒绝递归删除；可先重跑安装器生成标记，或确认后手动清理"
    return 0
  fi
  for entry in "$normalized"/* "$normalized"/.[!.]* "$normalized"/..?*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    case "${entry##*/}" in
      "$DATA_ROOT_MARKER_NAME"|gscore|napcat|astrbot|nonebot|nonebot-qqofficial|gscore-qqofficial|botshepherd)
        ;;
      *)
        warn "数据目录 ${normalized} 含非 NAG 条目 ${entry##*/}，拒绝递归删除"
        return 0
        ;;
    esac
  done
  if ((PURGE_DATA)); then
    purge=1
  elif [[ -t 0 ]] && (( ! ASSUME_YES )); then
    if prompt_yes_no "删除数据目录 ${normalized}（含机器人全部数据，不可恢复）" n; then
      confirm="$(prompt_value "请输入 yes 确认删除 ${normalized}" "")"
      if [[ "$confirm" == "yes" ]]; then
        purge=1
      else
        warn "确认失败，保留数据目录"
      fi
    fi
  fi
  if ((purge)); then
    log "删除数据目录 ${normalized}"
    as_root rm -rf -- "$normalized"
  else
    log "保留数据目录 ${normalized}"
  fi
  return 0
}

uninstall_state_files() {
  local proj="$1"
  local purge=0
  local name
  local -a names=()

  case "$proj" in
    nag)
      names=(guided.env guided.state astrbot.env hybrid.env nonebot.env
        nonebot-napcat.env astrbot-botshepherd.env hybrid-botshepherd.env
        nonebot-botshepherd.env nonebot-napcat-botshepherd.env
        botshepherd-ports.list docker-compose.botshepherd-ports.yml)
      ;;
    ng) names=(napcat.env) ;;
    nag-qqofficial) names=(qqofficial-nonebot.env qqofficial-direct.env) ;;
  esac
  if ((PURGE_STATE)); then
    purge=1
  elif [[ -t 0 ]] && (( ! ASSUME_YES )); then
    if prompt_yes_no "删除该部署的安装器状态文件（.installer/ 下的配置记录，不含 NapCat 身份）" y; then
      purge=1
    fi
  fi
  if (( ! purge )); then
    log "保留 ${proj} 的状态文件"
    return 0
  fi
  for name in "${names[@]}"; do
    rm -f -- "${STATE_DIR}/${name}" "${STATE_DIR}/${name}.tmp"
  done
  log "已删除 ${proj} 的状态文件"
  return 0
}

down_official_nonebot_project() {
  local project_dir="$1"
  local compose_project="$2"
  local container_id
  local owner_dir

  [[ -f "${project_dir}/docker-compose.yml" \
    && -f "${project_dir}/docker-compose.nag.yml" ]] || return 0
  container_id="$(
    "$DOCKER_BIN" ps -aq \
      --filter "label=com.docker.compose.project=${compose_project}" \
      --filter "label=com.docker.compose.service=nonebot" \
      | head -n 1
  )"
  if [[ -n "$container_id" ]]; then
    owner_dir="$(
      "$DOCKER_BIN" inspect --format \
        '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' \
        "$container_id" 2>/dev/null || true
    )"
    if [[ -n "$owner_dir" \
      && "$(realpath -m -- "$owner_dir")" != "$(realpath -m -- "$project_dir")" ]]; then
      warn "Compose 项目 ${compose_project} 当前属于 ${owner_dir}；跳过停止旧项目 ${project_dir}"
      return 0
    fi
  fi
  log "停止官方 Docker NoneBot 项目：${compose_project}"
  if ! "$DOCKER_BIN" compose \
    --project-directory "$project_dir" \
    --project-name "$compose_project" \
    --file "${project_dir}/docker-compose.yml" \
    --file "${project_dir}/docker-compose.nag.yml" \
    down --remove-orphans; then
    warn "停止官方 Docker NoneBot 项目 ${compose_project} 失败，继续后续清理"
  fi
}

uninstall_mode() {
  local proj
  local choice
  local env_file
  local data_root
  local identity_involved=0
  local index
  local -a candidates=()
  local -a selected=()

  command -v "$DOCKER_BIN" >/dev/null 2>&1 || die "未检测到 Docker，无法卸载"
  "$DOCKER_BIN" compose version >/dev/null 2>&1 || die "需要 Docker Compose V2"
  "$DOCKER_BIN" info >/dev/null 2>&1 || die "无法连接 Docker 守护进程；请检查服务状态与用户权限"

  for proj in nag ng nag-qqofficial; do
    if [[ -n "$("$DOCKER_BIN" compose -p "$proj" ps -aq 2>/dev/null || true)" ]] \
      || [[ -n "$(newest_env_file_for_project "$proj")" ]]; then
      candidates+=("$proj")
    fi
  done
  if ((${#candidates[@]} == 0)); then
    log "未检测到任何 NAG 部署，无需卸载"
    return 0
  fi

  if [[ -n "$UNINSTALL_TARGET" ]]; then
    case "$UNINSTALL_TARGET" in
      all)
        selected=("${candidates[@]}")
        ;;
      nag|ng|nag-qqofficial)
        for proj in "${candidates[@]}"; do
          if [[ "$proj" == "$UNINSTALL_TARGET" ]]; then
            selected+=("$proj")
          fi
        done
        ((${#selected[@]} > 0)) || die "未发现目标部署：${UNINSTALL_TARGET}"
        ;;
      *)
        die "--target 仅支持 nag、ng、nag-qqofficial 或 all"
        ;;
    esac
  elif [[ -t 0 ]] && (( ! ASSUME_YES )); then
    printf '发现以下部署：\n'
    index=1
    for proj in "${candidates[@]}"; do
      printf '  %d) %s（compose 项目：%s）\n' "$index" "$(project_label "$proj")" "$proj"
      index=$((index + 1))
    done
    printf '  %d) 全部卸载\n' "$index"
    while true; do
      read -r -p "请选择要卸载的部署 [1-${index}]: " choice
      if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= index)); then
        break
      fi
      warn "请输入 1 到 ${index} 之间的数字"
    done
    if ((choice == index)); then
      selected=("${candidates[@]}")
    else
      selected=("${candidates[choice - 1]}")
    fi
  else
    die "非交互卸载需要 --target 指定要卸载的部署（nag、ng、nag-qqofficial 或 all）"
  fi

  for proj in "${selected[@]}"; do
    env_file="$(newest_env_file_for_project "$proj")"
    data_root=""
    [[ -z "$env_file" ]] || data_root="$(env_value DATA_ROOT "$env_file" || true)"
    if [[ -n "$data_root" ]]; then
      case "$proj" in
        nag)
          if [[ -f "${data_root}/nonebot/project/docker-compose.nag.yml" ]]; then
            down_official_nonebot_project \
              "${data_root}/nonebot/project" nag-nonebot-personal
            as_root bash \
              "${SCRIPT_DIR}/scripts/unregister-mimo-agent-instance.sh" \
              --project-dir "${data_root}/nonebot/project" personal
          fi
          if [[ -f "${data_root}/nonebot-qqofficial/project/docker-compose.nag.yml" ]]; then
            down_official_nonebot_project \
              "${data_root}/nonebot-qqofficial/project" nag-nonebot-official
            as_root bash \
              "${SCRIPT_DIR}/scripts/unregister-mimo-agent-instance.sh" \
              --project-dir "${data_root}/nonebot-qqofficial/project" official
          fi
          ;;
        nag-qqofficial)
          if [[ -f "${data_root}/nonebot/project/docker-compose.nag.yml" ]]; then
            down_official_nonebot_project \
              "${data_root}/nonebot/project" nag-nonebot-official
            as_root bash \
              "${SCRIPT_DIR}/scripts/unregister-mimo-agent-instance.sh" \
              --project-dir "${data_root}/nonebot/project" official
          fi
          ;;
      esac
    fi
    log "停止并移除容器与网络（compose 项目：${proj}）"
    if ! "$DOCKER_BIN" compose -p "$proj" down --remove-orphans --volumes; then
      warn "docker compose -p ${proj} down 失败，继续后续清理"
    fi
    if [[ -n "$data_root" ]]; then
      uninstall_data_dir "$data_root"
    fi
    uninstall_state_files "$proj"
    if [[ "$proj" != "nag-qqofficial" ]]; then
      identity_involved=1
    fi
  done

  if ((identity_involved)) && [[ -f "${STATE_DIR}/napcat-identity.env" ]]; then
    if [[ -t 0 ]] && (( ! ASSUME_YES )); then
      warn "napcat-identity.env 保存共享的 NapCat MAC 与账号；删除后下次安装会生成新 MAC，可能触发 QQ 设备风控"
      if prompt_yes_no "同时删除 NapCat 身份文件" n; then
        rm -f -- "${STATE_DIR}/napcat-identity.env" "${STATE_DIR}/napcat-identity.env.tmp"
        log "已删除 NapCat 身份文件"
      fi
    else
      log "已保留 NapCat 身份文件（.installer/napcat-identity.env），如需删除请交互运行或手动删除"
    fi
  fi
  rmdir "$STATE_DIR" 2>/dev/null || true
  log "Docker 镜像未删除；如需清理可运行 docker image prune -a，或按需 docker rmi <镜像>"
  log "卸载完成"
  return 0
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
  ((10#$RANGE_START <= 10#$RANGE_END)) || die "端口范围起始值不能大于结束值"
  ((10#$RANGE_END - 10#$RANGE_START < 100)) || \
    die "单个托管端口范围最多包含 100 个端口"
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
    die "未找到 BotShepherd 安装环境；请先安装启用 BotShepherd 的 AstrBot 或 NoneBot 路线"

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
  local bind_ip port_spec

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
  log "仅重建 nag-botshepherd 以应用端口映射"
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
    *) die "绑定地址必须是 127.0.0.1 或 0.0.0.0" ;;
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
      die "$port_spec 与 ${reserved_name} 的宿主机端口 ${reserved_port} 冲突"
    fi
  done

  if [[ -s "$BOTSHEPHERD_PORTS_STATE" ]]; then
    while IFS='|' read -r existing_bind existing_spec; do
      [[ -n "$existing_spec" ]] || continue
      if port_ranges_overlap "$port_spec" "$existing_spec"; then
        die "$port_spec 与已有托管映射重叠：${existing_bind}:${existing_spec}"
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
  log "端口映射已移除"
}

manage_botshepherd_ports() {
  local action

  [[ -t 0 ]] || die "BotShepherd 端口管理需要交互式终端"
  (( ! DRY_RUN )) || die "--dry-run is not supported with botshepherd-ports mode"
  command -v "$DOCKER_BIN" >/dev/null 2>&1 || die "未安装 Docker"
  "$DOCKER_BIN" compose version >/dev/null 2>&1 || die "需要 Docker Compose V2"
  "$DOCKER_BIN" info >/dev/null 2>&1 || die "无法连接 Docker 守护进程"
  "$DOCKER_BIN" inspect nag-botshepherd >/dev/null 2>&1 || \
    die "nag-botshepherd 容器不存在；请先安装启用 BotShepherd 的 AstrBot 或 NoneBot 路线"

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
  local prev_gscore_port
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

  preflight_environment

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
  prev_gscore_port="$(env_value GSCORE_PORT "$env_file" || true)"
  gscore_port="${input_gscore_port:-$prev_gscore_port}"
  gscore_port="${gscore_port:-8765}"
  gscore_port="$(prompt_port "GsCore WebUI 端口" "$gscore_port" "$prev_gscore_port" "$bind_ip")"

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
    qq_app_secret="$(prompt_secret "QQ 官方机器人 AppSecret" "$qq_app_secret")"
    if [[ "$route_kind" == "nonebot" ]]; then
      qq_token="$(prompt_secret "QQ 官方机器人 Token" "$qq_token")"
    fi
  fi

  [[ -n "$qq_app_id" ]] || \
    die "缺少 QQ_APP_ID（--yes 模式请通过环境变量提供）"
  [[ -n "$qq_app_secret" ]] || \
    die "缺少 QQ_APP_SECRET（--yes 模式请通过环境变量提供）"
  if [[ "$route_kind" == "nonebot" ]]; then
    [[ -n "$qq_token" ]] || \
      die "NoneBot QQ 适配器需要 QQ_TOKEN"
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

  data_root="$(validated_data_root "$data_root")"
  case "$bind_ip" in
    127.0.0.1|0.0.0.0) ;;
    *) die "BIND_IP 必须是 127.0.0.1 或 0.0.0.0" ;;
  esac
  validate_port GSCORE_PORT "$gscore_port"
  [[ "$qq_app_id" =~ ^[A-Za-z0-9._~-]+$ ]] || \
    die "QQ_APP_ID 含不支持的字符"
  [[ "$qq_app_secret" =~ ^[A-Za-z0-9._~-]+$ ]] || \
    die "QQ_APP_SECRET 含不支持的字符"
  if [[ -n "$qq_token" && ! "$qq_token" =~ ^[A-Za-z0-9._~-]+$ ]]; then
    die "QQ_TOKEN 含不支持的字符"
  fi
  if [[ -n "$qq_admin_ids" \
    && ! "$qq_admin_ids" =~ ^[A-Za-z0-9._~-]+(,[A-Za-z0-9._~-]+)*$ ]]; then
    die "QQ_ADMIN_IDS 必须是英文逗号分隔的 OpenID"
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
    && prompt_yes_no "使用 CNB 镜像克隆鸣潮插件（适合 GitHub 访问较慢时）" "$(cnb_mirror_default)"; then
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
    command -v od >/dev/null 2>&1 || die "生成 GSCORE_WS_TOKEN 需要 od 命令"
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
    log "dry-run 完成；未写入凭据，也未改动主机"
    return
  fi
  if ! prompt_yes_no "确认开始安装" y; then
    log "已取消安装"
    return
  fi

  mkdir -p "$STATE_DIR"
  tmp_env="${env_file}.tmp"
  cat >"$tmp_env" <<EOF
# Generated by install.sh for mode: qqofficial-${route_kind}
DATA_ROOT=$data_root
BIND_IP=$bind_ip
TZ=Asia/Shanghai
GSCORE_PORT=$gscore_port
MIMO_OFFICIAL_PORT=${MIMO_OFFICIAL_PORT:-18082}
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
GSCORE_PYTHON_INDEX=$(gscore_python_index)
NONEBOT_PYTHON_INDEX=$(gscore_python_index)
NONEBOT_COMMAND_START=$(v="$(env_value NONEBOT_COMMAND_START "$env_file")"; printf '%s' "${v:-/}")
UV_NO_CONFIG=0
PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
GSCORE_XWUID_PYTHON_PACKAGES=playwright opencv-python fonttools pypinyin
EOF
  chmod 600 "$tmp_env"

  local data_dirs=(
    "$data_root/gscore/data"
    "$data_root/gscore/plugins"
  )
  if [[ "$route_kind" == "nonebot" ]]; then
    data_dirs+=(
      "$data_root/nonebot/data"
      "$data_root/nonebot/cache"
      "$data_root/nonebot/project"
    )
  else
    data_dirs+=("$data_root/gscore-qqofficial")
  fi
  if ! mkdir -p "${data_dirs[@]}" 2>/dev/null; then
    command -v sudo >/dev/null 2>&1 || die "无法创建 $data_root 且系统无 sudo"
    sudo install -d -m 0755 -o "$(id -u)" -g "$(id -g)" "${data_dirs[@]}"
  fi
  mark_data_root "$data_root"
  local official_project="${data_root}/nonebot/project"
  local official_mimo_port="${MIMO_OFFICIAL_PORT:-18082}"
  if [[ "$route_kind" == "nonebot" ]]; then
    local command_start
    command_start="$(env_value NONEBOT_COMMAND_START "$tmp_env")"
    command_start="${command_start:-/}"
    write_official_nonebot_environment \
      official "${official_project}/.env.prod" "$qq_admin_ids" \
      NoneBot2 "$gscore_ws_token" "$command_start" official \
      "$qq_app_id" "$qq_app_secret" "$qq_token" "$qq_is_sandbox"
    log "按 NoneBot 官方 CLI 流程生成 QQ 官方项目"
    prepare_official_nonebot_instance \
      official true "$official_project" "${official_project}/.env.prod" \
      "$data_root/nonebot/data" "$data_root/nonebot/cache" \
      nag-nonebot-official nag-qqofficial-nonebot nonebot \
      nag-qqofficial-net "$official_mimo_port" \
      /etc/mimo-console-agent/official.token local/nag-nonebot-official
  fi
  if [[ "$route_kind" == "direct" ]]; then
    if ! chown 10001:10001 "$data_root/gscore-qqofficial" 2>/dev/null; then
      command -v sudo >/dev/null 2>&1 || \
        die "无法把 gscore-qqofficial 数据目录归属到容器 UID 10001"
      sudo chown 10001:10001 "$data_root/gscore-qqofficial"
    fi
    chmod 0700 "$data_root/gscore-qqofficial"
  fi

  local official_compose_cmd=(
    "$DOCKER_BIN" compose
    --project-directory "$SCRIPT_DIR"
    --env-file "$tmp_env"
    -p nag-qqofficial
    -f "${SCRIPT_DIR}/docker-compose.qqofficial.yml"
  )
  official_compose() {
    "${official_compose_cmd[@]}" "$@"
  }
  official_finalize_gscore_plugins() {
    local finalize_attempt

    if ((INSTALL_WUWA || INSTALL_WUWA_DEPS)); then
      log "基础服务启动完成，先停止 GsCore 以初始化插件"
      official_compose stop gscore
    fi
    if ((INSTALL_WUWA)); then
      log "克隆或更新鸣潮插件套件"
      official_compose --profile init run --rm gscore-plugin-init
    fi
    if ((INSTALL_WUWA_DEPS)); then
      log "安装鸣潮插件依赖与 Chromium"
      official_compose --profile init run --rm gscore-xwuid-deps-init
    fi
    if ((INSTALL_WUWA || INSTALL_WUWA_DEPS)); then
      log "以完成初始化的插件环境启动 GsCore"
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
      die "插件初始化后 GsCore WebUI 未就绪"
    fi
  }

  official_compose config --quiet
  log "拉取 GsCore 镜像"
  official_compose pull gscore
  if [[ "$route_kind" != "nonebot" ]]; then
    log "从固定的上游 commit 构建 gscore-qqofficial"
    official_compose build gscore-qqofficial
  fi

  log "启动 GsCore"
  official_compose up -d gscore
  for ((attempt = 1; attempt <= 60; attempt++)); do
    if official_compose exec -T gscore sh -c \
      'test -x /venv/bin/python && test -f /gsuid_core/data/config.json' \
      >/dev/null 2>&1; then
      venv_ready=1
      break
    fi
    wait_progress "等待 GsCore 完成初始化" "$attempt" 60 2
    sleep 2
  done
  clear_wait_progress
  if (( ! venv_ready )); then
    official_compose logs --tail=100 gscore || true
    die "GsCore 120 秒内未完成初始化"
  fi

  log "配置 GsCore WebSocket token 与管理员 OpenID"
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
  log "等待基础 GsCore WebUI 就绪"
  for ((attempt = 1; attempt <= 90; attempt++)); do
    if official_compose exec -T gscore /venv/bin/python -c \
      'from urllib.request import urlopen; r=urlopen("http://127.0.0.1:8765/app/",timeout=3); assert r.status == 200' \
      >/dev/null 2>&1; then
      break
    fi
    wait_progress "等待基础 GsCore WebUI 就绪" "$attempt" 90 2
    sleep 2
  done
  clear_wait_progress
  if ((attempt > 90)); then
    official_compose logs --tail=120 gscore || true
    die "基础配置后 GsCore WebUI 未就绪"
  fi

  if [[ "$route_kind" == "nonebot" ]]; then
    official_compose stop gscore-qqofficial >/dev/null 2>&1 || true
    if [[ -n "$(official_compose ps -aq nonebot 2>/dev/null || true)" ]]; then
      log "移除旧版 NAG 自定义 NoneBot 服务"
      official_compose rm --stop --force nonebot >/dev/null
    fi
    log "通过 nb docker build/up 启动 QQ 官方 NoneBot"
    connection_check_since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    official_nonebot_cli "$official_project" nag-nonebot-official build
    official_nonebot_cli "$official_project" nag-nonebot-official up -d
    for ((attempt = 1; attempt <= 60; attempt++)); do
      if "$DOCKER_BIN" exec nag-qqofficial-nonebot python -c \
        'import socket; s=socket.create_connection(("127.0.0.1",8080),3); s.close()' \
        >/dev/null 2>&1; then
        nonebot_ready=1
        break
      fi
      wait_progress "等待 AstrBot 创建 cmd_config.json" "$attempt" 60 2
      sleep 2
    done
    clear_wait_progress
    if (( ! nonebot_ready )); then
      "$DOCKER_BIN" logs --tail=120 nag-qqofficial-nonebot || true
      die "NoneBot QQ 官方适配器 120 秒内未达到健康状态"
    fi
    official_finalize_gscore_plugins
    for ((attempt = 1; attempt <= 60; attempt++)); do
      local nonebot_logs
      nonebot_logs="$(
        "$DOCKER_BIN" logs --since "$connection_check_since" \
          nag-qqofficial-nonebot 2>/dev/null || true
      )"
      if [[ "$nonebot_logs" == *"EventType.READY"* ]]; then
        qq_gateway_ready=1
      fi
      if [[ "$nonebot_logs" == *"[SUCCESS] GenshinUID"*"Bot_ID:"* ]]; then
        gscore_adapter_ready=1
      fi
      if ((qq_gateway_ready && gscore_adapter_ready)); then
        break
      fi
      if [[ "$nonebot_logs" == *"code=11298"* \
        || "$nonebot_logs" == *"接口访问源IP不在白名单"* ]]; then
        die "QQ 拒绝了服务器 IP（11298）。请把本机公网 IP 加入机器人 IP 白名单后重跑安装器。"
      fi
      sleep 2
    done
    if (( ! qq_gateway_ready )); then
      "$DOCKER_BIN" logs --tail=120 nag-qqofficial-nonebot || true
      die "NoneBot 已启动，但 120 秒内未连上 QQ 官方 Gateway"
    fi
    if (( ! gscore_adapter_ready )); then
      "$DOCKER_BIN" logs --tail=120 nag-qqofficial-nonebot || true
      die "NoneBot 已连上 QQ，但 GenshinUID 120 秒内未连上 GsCore"
    fi
  else
    official_compose stop nonebot >/dev/null 2>&1 || true
    if [[ -f "${official_project}/docker-compose.yml" ]]; then
      official_nonebot_cli "$official_project" nag-nonebot-official down
    fi
    log "启动 gscore-qqofficial"
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
        die "QQ 拒绝了服务器 IP（11298）。请把本机公网 IP 加入机器人 IP 白名单后重跑安装器。"
      fi
      sleep 2
    done
    if ((attempt > 60)); then
      official_compose logs --tail=100 gscore-qqofficial || true
      die "gscore-qqofficial 120 秒内未同时连上 QQ Gateway 与 GsCore"
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
  if [[ "$route_kind" == "nonebot" ]]; then
    official_nonebot_cli "$official_project" nag-nonebot-official ps
  fi
  local official_mimo_setup_token=""
  if [[ "$route_kind" == "nonebot" ]]; then
    official_mimo_setup_token="$(
      wait_mimo_setup_token nag-qqofficial-nonebot || true
    )"
  fi
  # Deployment succeeded; only now replace the previous private environment.
  mv -f "$tmp_env" "$env_file"
  chmod 600 "$env_file"

  cat <<EOF

安装完成。

GsCore WebUI：http://${bind_ip}:${gscore_port}/app/
GsCore 注册码：${register_code:-未读取到，请查看 $data_root/gscore/data/config.json}
QQ 官方凭据：已保存到 $env_file（权限 600，未写入仓库）
EOF
  if [[ "$route_kind" == "nonebot" ]]; then
    printf 'Mimo Console：http://127.0.0.1:%s/mimo-console/\n' \
      "$official_mimo_port"
    if [[ -n "$official_mimo_setup_token" ]]; then
      printf 'Mimo Console 初始化令牌：%s\n' \
        "$official_mimo_setup_token"
    fi
  fi
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
    die "guided 模式需要交互选择；无人值守安装请使用传统 --mode 预设"
  [[ -t 0 ]] || die "guided 模式需要交互式终端"

  preflight_environment

  local env_file="${STATE_DIR}/guided.env"
  local state_file="${STATE_DIR}/guided.state"
  local identity_file="${STATE_DIR}/napcat-identity.env"
  local topology_file="$env_file"
  local existing_env_file="$env_file"
  local existing_identity_file="$identity_file"
  local existing_state=0
  local repair_mode=0
  local full_reconfigure=0
  local old_use_personal=0
  local old_use_official=0
  local old_personal_adapter="none"
  local old_official_adapter="none"
  local old_enable_astrbot=0
  local old_enable_nonebot=0
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
  local old_napcat_image=""
  local deployment_state="new"

  if guided_state_valid "$state_file" && guided_env_valid "$env_file"; then
    deployment_state="complete"
    topology_file="$state_file"
    existing_state=1
  elif [[ -f "$env_file" || -f "$state_file" ]]; then
    deployment_state="degraded"
    existing_state=1
    [[ -f "$state_file" ]] && topology_file="$state_file"
    warn "检测到现有部署状态，但状态文件不完整或版本不匹配；将按可修复部署处理"
  elif guided_state_valid "${state_file}.tmp" \
    && guided_env_valid "${env_file}.tmp"; then
    deployment_state="interrupted"
    existing_state=1
    topology_file="${state_file}.tmp"
    existing_env_file="${env_file}.tmp"
    [[ ! -f "${identity_file}.tmp" ]] \
      || existing_identity_file="${identity_file}.tmp"
    warn "检测到上次中断后留下的完整临时状态；将按可恢复部署继续"
  elif [[ -f "${env_file}.tmp" || -f "${state_file}.tmp" ]]; then
    die "检测到上次未完成且内容不完整的部署状态（${STATE_DIR}/*.tmp）；为避免覆盖，请先检查或移走这些临时文件"
  elif command -v "$DOCKER_BIN" >/dev/null 2>&1 \
    && nag_managed_container_exists; then
    deployment_state="orphaned"
    die "检测到 NAG 管理的容器，但正式安装状态缺失；为避免误认领，请先恢复 ${env_file} 和 ${state_file}，或卸载残留容器后重试"
  elif command -v "$DOCKER_BIN" >/dev/null 2>&1 \
    && nag_named_container_exists; then
    deployment_state="conflict"
    die "检测到与 NAG 同名但不属于已知 NAG Compose 项目的容器；为避免覆盖外部部署，请先处理容器命名冲突"
  fi

  if ((existing_state)); then
    old_data_root="$(env_value DATA_ROOT "$existing_env_file" || true)"
    old_bind_ip="$(env_value BIND_IP "$existing_env_file" || true)"
    old_gscore_port="$(env_value GSCORE_PORT "$existing_env_file" || true)"
    old_napcat_port="$(env_value NAPCAT_WEBUI_PORT "$existing_env_file" || true)"
    old_astrbot_port="$(env_value ASTRBOT_WEBUI_PORT "$existing_env_file" || true)"
    old_botshepherd_port="$(env_value BOTSHEPHERD_WEBUI_PORT "$existing_env_file" || true)"
    old_personal_masters="$(env_value NAPCAT_MASTER_QQ "$existing_env_file" || true)"
    old_napcat_account="$(env_value NAPCAT_ACCOUNT "$existing_identity_file" || true)"
    old_napcat_mac="$(env_value NAPCAT_MAC "$existing_identity_file" || true)"
    old_qq_app_id="$(env_value QQ_APP_ID "$existing_env_file" || true)"
    old_qq_app_secret="$(env_value QQ_APP_SECRET "$existing_env_file" || true)"
    old_qq_token="$(env_value QQ_TOKEN "$existing_env_file" || true)"
    old_qq_admin_ids="$(env_value QQ_ADMIN_IDS "$existing_env_file" || true)"
    old_qq_is_sandbox="$(env_value QQ_IS_SANDBOX "$existing_env_file" || true)"
    old_qq_is_sandbox="${old_qq_is_sandbox:-false}"
    old_napcat_image="$(env_value NAPCAT_IMAGE "$existing_env_file" || true)"

    if [[ "$deployment_state" == "complete" && -n "$old_data_root" ]]; then
      local data_root_marker="${old_data_root}/${DATA_ROOT_MARKER_NAME}"
      if [[ ! -f "$data_root_marker" || -L "$data_root_marker" \
        || "$(head -n 1 -- "$data_root_marker" 2>/dev/null || true)" \
          != "$DATA_ROOT_MARKER_VALUE" ]]; then
        deployment_state="degraded"
        warn "状态文件有效，但数据目录缺少有效的 NAG 管理标记；将按可修复部署处理"
      fi
    fi

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
      if [[ "$(env_value ENABLE_NONEBOT_GSCORE_ADAPTER "$existing_env_file" || true)" == "true" ]]; then
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

    if [[ "$deployment_state" == "complete" ]] \
      && command -v "$DOCKER_BIN" >/dev/null 2>&1; then
      local runtime_ownership_valid=1
      container_belongs_to_compose_project nag-gscore nag \
        || runtime_ownership_valid=0
      if [[ "$old_use_personal" == "1" ]]; then
        container_belongs_to_compose_project nag-napcat nag \
          || runtime_ownership_valid=0
      fi
      if [[ "$old_enable_astrbot" == "1" ]]; then
        container_belongs_to_compose_project nag-astrbot nag \
          || runtime_ownership_valid=0
      fi
      if [[ "$old_enable_nonebot" == "1" ]]; then
        container_belongs_to_compose_project \
          nag-nonebot nag-nonebot-personal || runtime_ownership_valid=0
      fi
      if [[ "$old_use_botshepherd" == "1" ]]; then
        container_belongs_to_compose_project nag-botshepherd nag \
          || runtime_ownership_valid=0
      fi
      if [[ "$old_use_official" == "1" \
        && "$old_official_adapter" == "nonebot" ]]; then
        container_belongs_to_compose_project \
          nag-nonebot-qqofficial nag-nonebot-official \
          || runtime_ownership_valid=0
      elif [[ "$old_use_official" == "1" \
        && "$old_official_adapter" == "direct" ]]; then
        container_belongs_to_compose_project nag-gscore-qqofficial nag \
          || runtime_ownership_valid=0
      fi
      if ((! runtime_ownership_valid)); then
        deployment_state="degraded"
        warn "状态文件有效，但部分容器缺失或不属于预期的 NAG Compose 项目；将按可修复部署处理"
      fi
    fi
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
    if [[ "$deployment_state" == "complete" ]]; then
      printf '\n检测到完整的现有部署状态。\n'
    else
      printf '\n检测到可修复的现有部署状态。\n'
    fi
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

  napcat_port="$(env_value NAPCAT_WEBUI_PORT "$existing_env_file" || true)"
  napcat_port="${napcat_port:-6099}"
  astrbot_port="$(env_value ASTRBOT_WEBUI_PORT "$existing_env_file" || true)"
  astrbot_port="${astrbot_port:-6185}"
  botshepherd_port="$(env_value BOTSHEPHERD_WEBUI_PORT "$existing_env_file" || true)"
  botshepherd_port="${botshepherd_port:-5111}"
  personal_masters="$(env_value NAPCAT_MASTER_QQ "$existing_env_file" || true)"
  napcat_account="$(env_value NAPCAT_ACCOUNT "$existing_identity_file" || true)"
  napcat_mac="$(env_value NAPCAT_MAC "$existing_identity_file" || true)"
  qq_app_id="$(env_value QQ_APP_ID "$existing_env_file" || true)"
  qq_app_secret="$(env_value QQ_APP_SECRET "$existing_env_file" || true)"
  qq_token="$(env_value QQ_TOKEN "$existing_env_file" || true)"
  qq_admin_ids="$(env_value QQ_ADMIN_IDS "$existing_env_file" || true)"
  qq_is_sandbox="$(env_value QQ_IS_SANDBOX "$existing_env_file" || true)"
  qq_is_sandbox="${qq_is_sandbox:-false}"
  qq_api_base="$(env_value QQ_API_BASE "$existing_env_file" || true)"
  qq_api_base="${qq_api_base:-https://api.sgroup.qq.com}"

  data_root="$(env_value DATA_ROOT "$existing_env_file" || true)"
  data_root="${data_root:-/opt/nag-data}"
  bind_ip="$(env_value BIND_IP "$existing_env_file" || true)"
  bind_ip="${bind_ip:-127.0.0.1}"
  gscore_port="$(env_value GSCORE_PORT "$existing_env_file" || true)"
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
    gscore_port="$(prompt_port "GsCore WebUI 端口" "$gscore_port" "$old_gscore_port" "$bind_ip")"
  fi

  local personal_added=0
  local official_added=0
  local astrbot_added=0
  local botshepherd_added=0
  ((use_personal && ! old_use_personal)) && personal_added=1
  ((use_official && ! old_use_official)) && official_added=1
  ((enable_astrbot && ! old_enable_astrbot)) && astrbot_added=1
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
      napcat_port="$(prompt_port "NapCat WebUI 端口" "$napcat_port" "$old_napcat_port" "$bind_ip")"
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
      astrbot_port="$(prompt_port "AstrBot WebUI 端口" "$astrbot_port" "$old_astrbot_port" "$bind_ip")"
    fi
    astrbot_port="${astrbot_port:-6185}"
  fi
  if ((use_botshepherd)); then
    if ((! existing_state || botshepherd_added || edit_shared_settings)); then
      botshepherd_port="$(prompt_port "BotShepherd WebUI 端口" "$botshepherd_port" "$old_botshepherd_port" "$bind_ip")"
    fi
    botshepherd_port="${botshepherd_port:-5111}"
  fi

  if ((use_official)); then
    if ((! existing_state || official_added || edit_shared_settings)) \
      || [[ "$official_adapter" != "$old_official_adapter" ]]; then
      qq_app_id="$(prompt_value "QQ 官方机器人 AppID" "$qq_app_id")"
      qq_app_secret="$(prompt_secret "QQ 官方机器人 AppSecret" "$qq_app_secret")"
      if [[ "$official_adapter" == "nonebot" ]]; then
        qq_token="$(prompt_secret "QQ 官方机器人 Token" "$qq_token")"
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

  data_root="$(validated_data_root "$data_root")"
  case "$bind_ip" in
    127.0.0.1|0.0.0.0) ;;
    *) die "BIND_IP 必须是 127.0.0.1 或 0.0.0.0" ;;
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
    && prompt_yes_no "使用 CNB 镜像克隆鸣潮插件" "$(cnb_mirror_default)"; then
    XUTHERINGWAVESUID_REPO="https://cnb.cool/gscore-mirror/XutheringWavesUID"
    ROVERSIGN_REPO="https://cnb.cool/gscore-mirror/RoverSign"
    SCOREECHO_REPO="https://cnb.cool/gscore-mirror/ScoreEcho"
  else
    XUTHERINGWAVESUID_REPO="https://github.com/Loping151/XutheringWavesUID.git"
    ROVERSIGN_REPO="https://github.com/Loping151/RoverSign.git"
    SCOREECHO_REPO="https://github.com/Loping151/ScoreEcho.git"
  fi

  gscore_ws_token="$(env_value GSCORE_WS_TOKEN "$existing_env_file" || true)"
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
    log "guided dry-run 完成；未写入任何凭据或文件"
    return
  fi
  prompt_yes_no "确认开始安装" y || {
    log "已取消安装"
    return
  }

  if ((use_personal)); then
    case "$(uname -m)" in
      x86_64|amd64|aarch64|arm64) ;;
      *) warn "NapCat Docker 镜像未声明支持当前架构（$(uname -m)）" ;;
    esac
  fi
  if ((use_botshepherd)); then
    case "$(uname -m)" in
      x86_64|amd64) ;;
      *) die "BotShepherd 官方镜像目前仅支持 linux/amd64" ;;
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
MIMO_PERSONAL_PORT=${MIMO_PERSONAL_PORT:-18081}
MIMO_OFFICIAL_PORT=${MIMO_OFFICIAL_PORT:-18082}
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
NAPCAT_GSCORE_ADAPTER_ZIP_URL=$NAPCAT_ADAPTER_PINNED_URL
NAPCAT_GSCORE_ADAPTER_SHA256=$NAPCAT_ADAPTER_PINNED_SHA256
ASTRBOT_GSCORE_ADAPTER_REPO=https://github.com/KimigaiiWuyi/astrbot_plugin_gscore_adapter.git
XUTHERINGWAVESUID_REPO=$XUTHERINGWAVESUID_REPO
ROVERSIGN_REPO=$ROVERSIGN_REPO
SCOREECHO_REPO=$SCOREECHO_REPO
GSCORE_PYTHON_INDEX=$(gscore_python_index)
NONEBOT_PYTHON_INDEX=$(gscore_python_index)
NONEBOT_COMMAND_START=$(v="$(env_value NONEBOT_COMMAND_START "$existing_env_file")"; printf '%s' "${v:-/}")
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
      "$data_root/astrbot"
    )
    # guided 的 napcat 无条件以只读挂载 nonebot/cache（用于共享 NoneBot 发送的
    # 本地媒体路径）；即便本次没启用 NoneBot 也先建好，避免 Docker 留下 root 属主目录。
    data_dirs+=("$data_root/nonebot/cache")
  fi
  ((enable_nonebot)) && \
    data_dirs+=(
      "$data_root/nonebot/data"
      "$data_root/nonebot/cache"
      "$data_root/nonebot/project"
    )
  ((enable_official_nonebot)) && \
    data_dirs+=(
      "$data_root/nonebot-qqofficial/data"
      "$data_root/nonebot-qqofficial/cache"
      "$data_root/nonebot-qqofficial/project"
    )
  ((enable_official_direct)) && data_dirs+=("$data_root/gscore-qqofficial")
  if ((use_botshepherd)); then
    data_dirs+=(
      "$data_root/botshepherd/config"
      "$data_root/botshepherd/data"
      "$data_root/botshepherd/logs"
    )
  elif ((use_personal)); then
    # guided-onebot-init always bind-mounts this path; pre-create it so Docker
    # does not leave a root-owned directory behind.
    data_dirs+=("$data_root/botshepherd/config")
  fi
  if ! mkdir -p "${data_dirs[@]}" 2>/dev/null; then
    command -v sudo >/dev/null 2>&1 || die "无法创建 $data_root"
    sudo install -d -m 0755 -o "$(id -u)" -g "$(id -g)" "${data_dirs[@]}"
  fi
  mark_data_root "$data_root"

  local personal_project="${data_root}/nonebot/project"
  local official_project="${data_root}/nonebot-qqofficial/project"
  local personal_mimo_port="${MIMO_PERSONAL_PORT:-18081}"
  local official_mimo_port="${MIMO_OFFICIAL_PORT:-18082}"
  local command_start
  command_start="$(env_value NONEBOT_COMMAND_START "$env_tmp")"
  command_start="${command_start:-/}"
  if ((enable_nonebot)); then
    write_official_nonebot_environment \
      personal "${personal_project}/.env.prod" "$personal_masters" \
      NoneBot2 "$gscore_ws_token" "$command_start" personal
    log "按 NoneBot 官方 CLI 流程生成个人 QQ 项目"
    prepare_official_nonebot_instance \
      personal \
      "$([[ "$personal_adapter" == "nonebot" ]] && printf true || printf false)" \
      "$personal_project" "${personal_project}/.env.prod" \
      "$data_root/nonebot/data" "$data_root/nonebot/cache" \
      nag-nonebot-personal nag-nonebot nonebot nag-net "$personal_mimo_port" \
      /etc/mimo-console-agent/personal.token local/nag-nonebot-personal
  fi
  if ((enable_official_nonebot)); then
    write_official_nonebot_environment \
      official "${official_project}/.env.prod" "$qq_admin_ids" \
      NoneBot2-QQOfficial "$gscore_ws_token" "$command_start" official \
      "$qq_app_id" "$qq_app_secret" "$qq_token" "$qq_is_sandbox"
    log "按 NoneBot 官方 CLI 流程生成 QQ 官方项目"
    prepare_official_nonebot_instance \
      official true "$official_project" "${official_project}/.env.prod" \
      "$data_root/nonebot-qqofficial/data" \
      "$data_root/nonebot-qqofficial/cache" \
      nag-nonebot-official nag-nonebot-qqofficial nonebot-qqofficial \
      nag-net "$official_mimo_port" /etc/mimo-console-agent/official.token \
      local/nag-nonebot-official
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
  if ((use_botshepherd)) \
    && [[ -f "${STATE_DIR}/docker-compose.botshepherd-ports.yml" ]]; then
    guided_compose_cmd+=(-f "${STATE_DIR}/docker-compose.botshepherd-ports.yml")
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
  ((enable_official_direct)) || stop_services+=(gscore-qqofficial)
  ((use_botshepherd)) || stop_services+=(botshepherd)
  if ((${#stop_services[@]})); then
    log "停止不属于所选拓扑的组件"
    guided_compose stop "${stop_services[@]}" >/dev/null 2>&1 || true
  fi
  if remove_legacy_compose_container nag-nonebot nag nonebot; then
    log "移除旧版 NAG 自定义 NoneBot 服务"
  fi
  if remove_legacy_compose_container \
    nag-nonebot-qqofficial nag nonebot-qqofficial; then
    log "移除旧版 NAG 自定义 QQ 官方 NoneBot 服务"
  fi

  if ((force_reconcile)) || ! guided_service_exists gscore; then
    log "拉取共享 GsCore 镜像"
    guided_compose pull gscore
  fi
  if ((use_personal)) \
    && { ((force_reconcile || personal_added || napcat_image_changed)) \
      || ! guided_service_exists napcat; }; then
    log "拉取所选 NapCat 镜像"
    guided_compose pull napcat
  fi
  if ((enable_astrbot)) \
    && { ((force_reconcile || astrbot_added)) \
      || ! guided_service_exists astrbot; }; then
    log "拉取 AstrBot 镜像"
    guided_compose pull astrbot
  fi
  if ((use_botshepherd)) \
    && { ((force_reconcile || botshepherd_added)) \
      || ! guided_service_exists botshepherd; }; then
    log "拉取 BotShepherd 镜像"
    guided_compose pull botshepherd
  fi
  if ((enable_official_direct)) \
    && { ((force_reconcile || official_changed)) \
      || ! guided_service_exists gscore-qqofficial; }; then
    log "从固定的上游 commit 构建 gscore-qqofficial"
    guided_compose build gscore-qqofficial
  fi

  local apply_started_at
  apply_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local napcat_started_before=""
  local astrbot_started_before=""
  local botshepherd_started_before=""
  local napcat_started_after=""
  local astrbot_started_after=""
  local botshepherd_started_after=""
  napcat_started_before="$(container_started_at nag-napcat)"
  astrbot_started_before="$(container_started_at nag-astrbot)"
  botshepherd_started_before="$(container_started_at nag-botshepherd)"
  local gscore_restarted=0
  log "确保共享 GsCore 正在运行"
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
    wait_progress "等待 GsCore 完成初始化" "$attempt" 60 2
    sleep 2
  done
  clear_wait_progress
  ((venv_ready)) || die "GsCore 120 秒内未完成初始化"

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
    log "重启 GsCore 以应用配置"
    guided_compose restart gscore
    gscore_restarted=1
  else
    log "GsCore 配置无变化；保持当前进程"
  fi
  log "等待基础 GsCore WebUI 就绪"
  for ((attempt = 1; attempt <= 90; attempt++)); do
    if guided_compose exec -T gscore /venv/bin/python -c \
      'from urllib.request import urlopen; r=urlopen("http://127.0.0.1:8765/app/",timeout=3); assert r.status == 200' \
      >/dev/null 2>&1; then
      break
    fi
    wait_progress "等待基础 GsCore WebUI 就绪" "$attempt" 90 2
    sleep 2
  done
  clear_wait_progress
  ((attempt <= 90)) || die "GsCore WebUI 未就绪"

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
      log "启用并配置 NapCat GScore 适配器"
      guided_compose --profile init run --rm napcat-gscore-adapter-init
    else
      log "停用 NapCat GScore 适配器以避免重复回复"
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
      wait_progress "等待 AstrBot 创建 cmd_config.json" "$attempt" 60 2
      sleep 2
    done
    clear_wait_progress
    ((attempt <= 60)) || die "AstrBot 未创建 cmd_config.json"
    guided_compose stop astrbot
    guided_compose --profile init run --rm astrbot-onebot-init
  fi

  if ((use_personal && napcat_reconfigure)); then
    guided_compose --profile init run --rm guided-onebot-init
  fi

  local start_services=(gscore)
  ((enable_astrbot)) && start_services+=(astrbot)
  ((use_botshepherd)) && start_services+=(botshepherd)
  guided_compose up -d "${start_services[@]}"
  if ((enable_nonebot)); then
    log "通过 nb docker build/up 启动个人 QQ NoneBot"
    official_nonebot_cli "$personal_project" nag-nonebot-personal build
    official_nonebot_cli "$personal_project" nag-nonebot-personal up -d
  elif [[ -f "${personal_project}/docker-compose.yml" ]]; then
    official_nonebot_cli "$personal_project" nag-nonebot-personal down
  fi
  local official_reconfigure=0
  ((force_reconcile || official_changed || official_settings_changed \
    || shared_settings_changed)) && official_reconfigure=1
  local personal_check_since="$apply_started_at"
  local official_check_since="$apply_started_at"
  if ((enable_official_nonebot)); then
    log "通过 nb docker build/up 启动 QQ 官方 NoneBot"
    official_nonebot_cli "$official_project" nag-nonebot-official build
    official_nonebot_cli "$official_project" nag-nonebot-official up -d
    official_reconfigure=1
  elif ((enable_official_direct)); then
    if [[ -f "${official_project}/docker-compose.yml" ]]; then
      official_nonebot_cli "$official_project" nag-nonebot-official down
    fi
    if ((official_reconfigure)) || ! guided_service_exists gscore-qqofficial; then
      guided_compose up -d \
        --no-deps --force-recreate gscore-qqofficial
      official_reconfigure=1
    else
      guided_compose up -d --no-deps gscore-qqofficial
    fi
  elif [[ -f "${official_project}/docker-compose.yml" ]]; then
    official_nonebot_cli "$official_project" nag-nonebot-official down
  fi
  if ((use_personal)); then
    guided_compose up -d napcat
    if ((napcat_reconfigure && old_use_personal && ! napcat_runtime_changed)); then
      log "重启一次 NapCat 以加载更新后的 OneBot 配置"
      guided_compose restart napcat
    fi
  fi
  napcat_started_after="$(container_started_at nag-napcat)"
  astrbot_started_after="$(container_started_at nag-astrbot)"
  botshepherd_started_after="$(container_started_at nag-botshepherd)"

  if ((INSTALL_WUWA || INSTALL_WUWA_DEPS)); then
    log "所选基础服务启动完成，先停止 GsCore 以初始化插件"
    guided_compose stop gscore
  fi
  if ((INSTALL_WUWA)); then
    log "克隆或更新鸣潮插件套件"
    guided_compose --profile init run --rm gscore-plugin-init
  fi
  if ((INSTALL_WUWA_DEPS)); then
    log "安装鸣潮插件依赖与 Chromium"
    guided_compose --profile init run --rm gscore-xwuid-deps-init
  fi
  if ((INSTALL_WUWA || INSTALL_WUWA_DEPS)); then
    log "以完成初始化的插件环境启动 GsCore"
    guided_compose up -d gscore
    gscore_restarted=1
    for ((attempt = 1; attempt <= 90; attempt++)); do
      if guided_compose exec -T gscore /venv/bin/python -c \
        'from urllib.request import urlopen; r=urlopen("http://127.0.0.1:8765/app/",timeout=3); assert r.status == 200' \
        >/dev/null 2>&1; then
        break
      fi
      wait_progress "等待插件初始化后的 GsCore WebUI" "$attempt" 90 2
      sleep 2
    done
    clear_wait_progress
    if ((attempt > 90)); then
      guided_compose logs --tail=120 gscore || true
      die "插件初始化后 GsCore WebUI 未就绪"
    fi
  fi

  # GenshinUID can leave its scheduled reconnect coroutine waiting indefinitely
  # when GsCore is stopped while game plugins or Chromium are initialized.
  # Restart only the selected NoneBot GsCore adapters after the final GsCore
  # process is healthy, then validate connections from this fresh log window.
  if ((gscore_restarted)); then
    if ((enable_nonebot)) && [[ "$personal_adapter" == "nonebot" ]]; then
      log "GsCore 已完成重启；重启个人 QQ NoneBot 以恢复 GenshinUID 连接"
      personal_check_since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      restart_official_nonebot_instance \
        "$personal_project" nag-nonebot-personal nag-nonebot
    fi
    if ((enable_official_nonebot)); then
      log "GsCore 已完成重启；重启 QQ 官方 NoneBot 以恢复 GenshinUID 连接"
      official_check_since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      restart_official_nonebot_instance \
        "$official_project" nag-nonebot-official nag-nonebot-qqofficial
    elif ((enable_official_direct)); then
      official_check_since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      guided_compose restart gscore-qqofficial
    fi
  fi

  local napcat_webui_token=""
  local astrbot_initial_password=""
  local botshepherd_initial_password=""
  if ((use_personal)) \
    && [[ -z "$napcat_started_before" \
      || "$napcat_started_before" != "$napcat_started_after" ]]; then
    log "等待 NapCat WebUI Token"
    for ((attempt = 1; attempt <= 60; attempt++)); do
      napcat_webui_token="$(
        guided_compose logs --no-color napcat 2>/dev/null \
          | sed -n 's/.*WebUi Token:[[:space:]]*\([^[:space:]]*\).*/\1/p' \
          | tail -n 1 || true
      )"
      [[ -z "$napcat_webui_token" ]] || break
      wait_progress "等待 NapCat WebUI Token" "$attempt" 60 2
      sleep 2
    done
    clear_wait_progress
    [[ -n "$napcat_webui_token" ]] || \
      warn "NapCat 已启动，但 120 秒内没有从日志读取到 WebUI Token"
  elif ((use_personal)); then
    log "NapCat 为未重建的现有实例；跳过一次性 WebUI Token 日志提取"
  fi
  if ((enable_astrbot)) \
    && [[ -z "$astrbot_started_before" \
      || "$astrbot_started_before" != "$astrbot_started_after" ]]; then
    log "等待 AstrBot 初始 WebUI 密码"
    local astrbot_password_attempts=60
    for ((attempt = 1; attempt <= astrbot_password_attempts; attempt++)); do
      astrbot_initial_password="$(
        guided_compose logs --no-color astrbot 2>/dev/null \
          | sed -E 's/\x1B\[[0-9;]*[[:alpha:]]//g' \
          | sed -n 's/.*Initial password:[[:space:]]*\([[:graph:]][[:graph:]]*\).*/\1/p' \
          | tail -n 1 || true
      )"
      [[ -z "$astrbot_initial_password" ]] || break
      wait_progress "等待 AstrBot 初始 WebUI 密码" \
        "$attempt" "$astrbot_password_attempts" 2
      sleep 2
    done
    clear_wait_progress
    [[ -n "$astrbot_initial_password" ]] || \
      warn "未从当前容器日志读取到 AstrBot 初始密码；复用已有数据时配置文件只保存密码哈希，无法恢复明文，请使用此前设置的密码或在 WebUI 外重置"
  elif ((enable_astrbot)); then
    log "AstrBot 为未重建的现有实例；跳过一次性初始密码日志提取"
  fi
  if ((use_botshepherd)) \
    && [[ -z "$botshepherd_started_before" \
      || "$botshepherd_started_before" != "$botshepherd_started_after" ]]; then
    log "等待 BotShepherd 初始 WebUI 密码"
    for ((attempt = 1; attempt <= 30; attempt++)); do
      botshepherd_initial_password="$(
        guided_compose logs --no-color botshepherd 2>/dev/null \
          | sed -n 's/.*BotShepherd generated initial password:[[:space:]]*\([[:graph:]][[:graph:]]*\).*/\1/p' \
          | tail -n 1 || true
      )"
      [[ -z "$botshepherd_initial_password" ]] || break
      wait_progress "等待 BotShepherd 初始 WebUI 密码" "$attempt" 30 2
      sleep 2
    done
    clear_wait_progress
    [[ -n "$botshepherd_initial_password" ]] || \
      warn "未从日志读取到 BotShepherd 初始密码；复用已有数据时请使用此前设置的密码"
  elif ((use_botshepherd)); then
    log "BotShepherd 为未重建的现有实例；跳过一次性初始密码日志提取"
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
        clear_wait_progress
        die "QQ 拒绝了服务器 IP（11298）；请将其加入机器人 IP 白名单"
      fi
      wait_progress "等待 QQ 官方直连完成 Gateway 与 GsCore 连接" \
        "$attempt" 60 2
      sleep 2
    done
    clear_wait_progress
    ((attempt <= 60)) || die "gscore-qqofficial 未完成两条连接"
  elif ((enable_official_direct)); then
    guided_service_running gscore-qqofficial \
      || die "gscore-qqofficial 未在运行"
  fi
  if ((enable_nonebot)) && [[ "$personal_adapter" == "nonebot" ]] \
    && ((personal_adapter_reconfigure || gscore_restarted)); then
    for ((attempt = 1; attempt <= 60; attempt++)); do
      local personal_nb_logs
      personal_nb_logs="$(
        "$DOCKER_BIN" logs --since "$personal_check_since" \
          nag-nonebot 2>/dev/null || true
      )"
      if [[ "$personal_nb_logs" == *"[SUCCESS] GenshinUID"*"Bot_ID: NoneBot2"* ]]; then
        break
      fi
      wait_progress "等待个人 QQ NoneBot 连接 GsCore" "$attempt" 60 2
      sleep 2
    done
    clear_wait_progress
    ((attempt <= 60)) || die "个人 QQ NoneBot 的 GenshinUID 未连接 GsCore"
  fi
  if ((enable_official_nonebot && (official_reconfigure || gscore_restarted))); then
    for ((attempt = 1; attempt <= 60; attempt++)); do
      local official_nb_logs
      official_nb_logs="$(
        "$DOCKER_BIN" logs --since "$official_check_since" \
          nag-nonebot-qqofficial 2>/dev/null || true
      )"
      if [[ "$official_nb_logs" == *"EventType.READY"* \
        && "$official_nb_logs" == *"[SUCCESS] GenshinUID"*"Bot_ID: NoneBot2-QQOfficial"* ]]; then
        break
      fi
      if [[ "$official_nb_logs" == *"code=11298"* ]]; then
        clear_wait_progress
        die "QQ 拒绝了服务器 IP（11298）；请将其加入机器人 IP 白名单"
      fi
      wait_progress "等待 QQ 官方 NoneBot 完成两条连接" "$attempt" 60 2
      sleep 2
    done
    clear_wait_progress
    ((attempt <= 60)) || die "QQ 官方 NoneBot 未完成两条连接"
  elif ((enable_official_nonebot)); then
    [[ "$("$DOCKER_BIN" inspect --format '{{.State.Running}}' \
      nag-nonebot-qqofficial 2>/dev/null || true)" == "true" ]] \
      || die "QQ 官方 NoneBot 未在运行"
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
  if ((enable_nonebot)); then
    official_nonebot_cli "$personal_project" nag-nonebot-personal ps
  fi
  if ((enable_official_nonebot)); then
    official_nonebot_cli "$official_project" nag-nonebot-official ps
  fi
  local personal_mimo_setup_token=""
  local official_mimo_setup_token=""
  if ((enable_nonebot)); then
    personal_mimo_setup_token="$(
      wait_mimo_setup_token nag-nonebot || true
    )"
  fi
  if ((enable_official_nonebot)); then
    official_mimo_setup_token="$(
      wait_mimo_setup_token nag-nonebot-qqofficial || true
    )"
  fi
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
  if ((enable_nonebot)); then
    printf '个人 QQ Mimo Console：http://127.0.0.1:%s/mimo-console/\n' \
      "$personal_mimo_port"
    if [[ -n "$personal_mimo_setup_token" ]]; then
      printf '个人 QQ Mimo Console 初始化令牌：%s\n' \
        "$personal_mimo_setup_token"
    fi
  fi
  if ((enable_official_nonebot)); then
    printf 'QQ 官方 Mimo Console：http://127.0.0.1:%s/mimo-console/\n' \
      "$official_mimo_port"
    if [[ -n "$official_mimo_setup_token" ]]; then
      printf 'QQ 官方 Mimo Console 初始化令牌：%s\n' \
        "$official_mimo_setup_token"
    fi
  fi
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

canonical_nonebot_plugin_name() {
  local value="${1,,}"
  value="${value//_/-}"
  value="${value//./-}"
  printf '%s' "$value"
}

nonebot_plugins_txt_has_package() {
  local plugins_file="$1"
  local package_name="$2"

  [[ -f "$plugins_file" ]] || return 1
  awk -v target="$package_name" '
    function canonical(value) {
      sub(/\[[^]]*\]/, "", value)
      sub(/[<>=!~].*$/, "", value)
      gsub(/[_.-]+/, "-", value)
      return tolower(value)
    }
    BEGIN {
      target = canonical(target)
      found = 0
    }
    /^[[:space:]]*(#|$)/ {
      next
    }
    canonical($1) == target {
      found = 1
      exit
    }
    END {
      exit(found ? 0 : 1)
    }
  ' "$plugins_file"
}

upsert_nonebot_plugin_spec() {
  local plugins_dir="$1"
  local package_name="$2"
  local plugin_line="$3"
  local plugins_file="${plugins_dir}/plugins.txt"
  local temporary

  [[ ! -L "$plugins_file" ]] || die "拒绝写入符号链接：${plugins_file}"
  temporary="$(mktemp)"
  if [[ -f "$plugins_file" ]]; then
    awk -v target="$package_name" -v replacement="$plugin_line" '
      function canonical(value) {
        sub(/\[[^]]*\]/, "", value)
        sub(/[<>=!~].*$/, "", value)
        gsub(/[_.-]+/, "-", value)
        return tolower(value)
      }
      BEGIN {
        target = canonical(target)
        written = 0
      }
      /^[[:space:]]*(#|$)/ {
        print
        next
      }
      {
        if (canonical($1) == target) {
          if (!written) {
            print replacement
            written = 1
          }
          next
        }
        print
      }
      END {
        if (!written) {
          print replacement
        }
      }
    ' "$plugins_file" >"$temporary"
  else
    printf '%s\n' "$plugin_line" >"$temporary"
  fi

  if [[ -f "$plugins_file" ]] && cmp -s -- "$plugins_file" "$temporary"; then
    NONEBOT_PLUGIN_CONTENT_CHANGED=0
  else
    NONEBOT_PLUGIN_CONTENT_CHANGED=1
  fi
  as_root install -d -m 0755 -o "$(id -u)" -g "$(id -g)" "$plugins_dir"
  as_root install -m 0644 -o "$(id -u)" -g "$(id -g)" \
    "$temporary" "$plugins_file"
  rm -f -- "$temporary"
}

install_nonebot_github_repo() {
  local plugins_dir="$1"
  local repo_url="$2"
  local repo_name="$3"
  local import_override="$4"
  local target="${plugins_dir}/${repo_name}"
  local output

  [[ ! -L "$target" ]] || die "拒绝更新符号链接插件目录：${target}"
  as_root install -d -m 0755 -o "$(id -u)" -g "$(id -g)" "$plugins_dir"
  output="$(
    "$DOCKER_BIN" run --rm \
      --entrypoint /bin/sh \
      -v "${plugins_dir}:/plugins" \
      alpine/git:latest \
      -s -- "$repo_url" "$repo_name" "$import_override" \
      <"${SCRIPT_DIR}/scripts/install-nonebot-github-plugin.sh"
  )"
  printf '%s\n' "$output"
  NONEBOT_PLUGIN_RESOLVED_IMPORT="$(
    printf '%s\n' "$output" | sed -n 's/^NAG_PLUGIN_MODULE=//p' | tail -n 1
  )"
  NONEBOT_PLUGIN_CONTENT_CHANGED="$(
    printf '%s\n' "$output" | sed -n 's/^NAG_PLUGIN_CHANGED=//p' | tail -n 1
  )"
  [[ -n "$NONEBOT_PLUGIN_RESOLVED_IMPORT" ]] || \
    die "GitHub 插件仓库未返回可加载的模块名"
  [[ "$NONEBOT_PLUGIN_CONTENT_CHANGED" == "0" \
    || "$NONEBOT_PLUGIN_CONTENT_CHANGED" == "1" ]] || \
    die "GitHub 插件仓库未返回有效的变更状态"
}

wait_nonebot_plugin_ready() {
  local container_name="$1"
  local import_name="$2"
  local old_marker="$3"
  local require_marker_change="$4"
  local started_at="$5"
  # 依赖同步跑在 nonebot.run() 之前，带 extras 的重插件（如 htmlrender→playwright）
  # 在慢镜像源上可能耗时数分钟；上限放宽到约 15 分钟，避免误判超时。
  local max_attempts=450
  local attempt
  local state
  local health
  local marker
  local recent_logs
  local since_logs

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    state="$(
      "$DOCKER_BIN" inspect --format '{{.State.Status}}' \
        "$container_name" 2>/dev/null || true
    )"
    health="$(
      "$DOCKER_BIN" inspect --format \
        '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
        "$container_name" 2>/dev/null || true
    )"
    marker="$(
      "$DOCKER_BIN" exec "$container_name" sh -c \
        'cat /app/site-packages/.nag-deps-hash 2>/dev/null || true' \
        2>/dev/null || true
    )"
    if [[ "$state" == "running" \
      && "$health" != "starting" \
      && "$health" != "unhealthy" \
      && -n "$marker" ]]; then
      if [[ "$require_marker_change" == "0" || "$marker" != "$old_marker" ]]; then
        break
      fi
    fi
    if [[ "$state" == "exited" || "$state" == "dead" ]]; then
      "$DOCKER_BIN" logs --tail 100 "$container_name" || true
      die "NoneBot 实例 ${container_name} 在安装插件时退出"
    fi
    # 依赖安装失败时 bot.py 会打印告警并跳过写标记，随后照常启动服务；
    # 这种情况标记不会变化，若不主动检测就会一直等到超时。此处快速失败。
    since_logs="$(
      "$DOCKER_BIN" logs --since "$started_at" "$container_name" 2>&1 || true
    )"
    if printf '%s\n' "$since_logs" \
      | grep -F "插件依赖安装失败" >/dev/null; then
      printf '%s\n' "$since_logs" | tail -n 100 >&2
      die "NoneBot 实例 ${container_name} 安装插件依赖失败；请排查上方日志中的网络或依赖冲突"
    fi
    sleep 2
  done
  ((attempt <= max_attempts)) || {
    "$DOCKER_BIN" logs --tail 100 "$container_name" || true
    die "等待 ${container_name} 完成插件依赖安装超时"
  }

  recent_logs="$(
    "$DOCKER_BIN" logs --since "$started_at" "$container_name" 2>&1 || true
  )"
  if printf '%s\n' "$recent_logs" \
    | grep -F "加载插件 ${import_name} 失败" >/dev/null; then
    printf '%s\n' "$recent_logs" | tail -n 100 >&2
    die "插件依赖已安装，但 NoneBot 加载 ${import_name} 失败"
  fi
}

nonebot_plugin_mode() {
  local plugin_input="$NONEBOT_PLUGIN_INPUT"
  local plugin_import="$NONEBOT_PLUGIN_IMPORT"
  local plugin_target="$NONEBOT_PLUGIN_TARGET"
  local source_kind="pypi"
  local package_name=""
  local plugin_line=""
  local github_candidate=""
  local github_owner=""
  local github_repo=""
  local github_url=""
  local container_id
  local container_name
  local service_name
  local project_name
  local plugins_dir
  local platform
  local state
  local label
  local choice
  local index
  local selected_index
  local old_marker
  local started_at
  local resolved_import
  local changed
  local repo_candidate
  local repo_candidate_name
  local path_component
  local -a container_ids=()
  local -a instance_names=()
  local -a instance_plugins=()
  local -a instance_platforms=()
  local -a instance_states=()
  local -a selected=()
  local -A seen_plugin_dirs=()
  local official_project
  local official_label
  local official_port
  local official_container
  local official_state
  local official_runtime_port
  local official_count=0
  local official_env_file

  command -v "$DOCKER_BIN" >/dev/null 2>&1 || \
    die "未检测到 Docker，无法发现 NoneBot 实例"
  "$DOCKER_BIN" info >/dev/null 2>&1 || \
    die "无法连接 Docker 守护进程"

  for official_project in nag-nonebot-personal nag-nonebot-official; do
    official_container="$(
      "$DOCKER_BIN" ps -aq \
        --filter "label=com.docker.compose.project=${official_project}" \
        --filter "label=com.docker.compose.service=nonebot" \
        | head -n 1
    )"
    [[ -n "$official_container" ]] || continue
    official_count=$((official_count + 1))
    official_env_file=""
    if [[ "$official_project" == "nag-nonebot-personal" ]]; then
      official_label="个人 QQ / OneBot V11"
      official_port=18081
      official_env_file="$(newest_env_file_for_project nag)"
      if [[ -n "$official_env_file" ]]; then
        official_port="$(
          env_value MIMO_PERSONAL_PORT "$official_env_file" || true
        )"
        official_port="${official_port:-18081}"
      fi
    else
      official_label="QQ 官方机器人"
      official_port=18082
      official_env_file="$(newest_env_file_for_project nag-qqofficial)"
      [[ -n "$official_env_file" ]] || \
        official_env_file="$(newest_env_file_for_project nag)"
      if [[ -n "$official_env_file" ]]; then
        official_port="$(
          env_value MIMO_OFFICIAL_PORT "$official_env_file" || true
        )"
        official_port="${official_port:-18082}"
      fi
    fi
    official_runtime_port="$(
      "$DOCKER_BIN" port "$official_container" 8080/tcp 2>/dev/null \
        | head -n 1
    )"
    [[ -z "$official_runtime_port" ]] || \
      official_port="${official_runtime_port##*:}"
    official_state="$(
      "$DOCKER_BIN" inspect --format '{{.State.Status}}' "$official_container"
    )"
    printf '  - %s（%s）：http://127.0.0.1:%s/mimo-console/\n' \
      "$official_label" "$official_state" "$official_port"
  done

  if ((official_count > 0)); then
    if [[ -n "$plugin_input" || -n "$plugin_import" ]]; then
      warn "检测到官方 Docker NoneBot 项目；--plugin/--plugin-import 不再直接改容器，请在上面的 Mimo Console 中安装、更新、卸载和配置插件"
    else
      log "检测到官方 Docker NoneBot 项目；插件与依赖统一由 Mimo Console 管理"
    fi
    printf '远程服务器默认仅监听本机；可用 SSH 端口转发后在浏览器访问，例如：\n'
    printf '  ssh -L 18081:127.0.0.1:18081 -L 18082:127.0.0.1:18082 <服务器>\n'
    return 0
  fi

  warn "未检测到官方 Docker NoneBot 项目，将进入旧版 /app/plugins 兼容流程"
  mapfile -t container_ids < <("$DOCKER_BIN" ps -aq)
  for container_id in "${container_ids[@]}"; do
    service_name="$(
      "$DOCKER_BIN" inspect --format \
        '{{index .Config.Labels "com.docker.compose.service"}}' \
        "$container_id" 2>/dev/null || true
    )"
    [[ "$service_name" == "nonebot" \
      || "$service_name" == "nonebot-qqofficial" ]] || continue
    project_name="$(
      "$DOCKER_BIN" inspect --format \
        '{{index .Config.Labels "com.docker.compose.project"}}' \
        "$container_id" 2>/dev/null || true
    )"
    [[ "$project_name" == "nag" \
      || "$project_name" == "nag-qqofficial" ]] || continue
    plugins_dir="$(
      "$DOCKER_BIN" inspect --format \
        '{{range .Mounts}}{{if eq .Destination "/app/plugins"}}{{println .Source}}{{end}}{{end}}' \
        "$container_id" 2>/dev/null | head -n 1
    )"
    [[ -n "$plugins_dir" ]] || continue
    [[ -z "${seen_plugin_dirs["$plugins_dir"]+x}" ]] || continue
    seen_plugin_dirs["$plugins_dir"]=1
    container_name="$(
      "$DOCKER_BIN" inspect --format '{{.Name}}' "$container_id"
    )"
    container_name="${container_name#/}"
    platform="$(
      "$DOCKER_BIN" inspect --format \
        '{{range .Config.Env}}{{println .}}{{end}}' "$container_id" \
        | awk -F= '$1 == "NONEBOT_PLATFORM" {print $2; exit}'
    )"
    [[ "$service_name" != "nonebot-qqofficial" ]] || platform="qqofficial"
    platform="${platform:-onebot}"
    state="$(
      "$DOCKER_BIN" inspect --format '{{.State.Status}}' "$container_id"
    )"
    instance_names+=("$container_name")
    instance_plugins+=("$plugins_dir")
    instance_platforms+=("$platform")
    instance_states+=("$state")
  done

  ((${#instance_names[@]} > 0)) || \
    die "未发现带 /app/plugins 持久化挂载的 NAG NoneBot 实例"

  printf '检测到以下 NoneBot 实例：\n'
  for index in "${!instance_names[@]}"; do
    if [[ "${instance_platforms[index]}" == "qqofficial" ]]; then
      label="QQ 官方机器人"
    else
      label="个人 QQ / OneBot V11"
    fi
    printf '  %d) %s｜%s｜%s｜%s\n' \
      "$((index + 1))" "${instance_names[index]}" "$label" \
      "${instance_states[index]}" "${instance_plugins[index]}"
  done

  if [[ -n "$plugin_target" ]]; then
    if [[ "$plugin_target" == "all" ]]; then
      for index in "${!instance_names[@]}"; do
        selected+=("$index")
      done
    else
      for index in "${!instance_names[@]}"; do
        if [[ "${instance_names[index]}" == "$plugin_target" ]]; then
          selected+=("$index")
          break
        fi
      done
      ((${#selected[@]} == 1)) || \
        die "未找到 --plugin-target 指定的容器：${plugin_target}"
    fi
  elif ((${#instance_names[@]} == 1)); then
    selected=(0)
    log "自动选择唯一的 NoneBot 实例：${instance_names[0]}"
  else
    (( ! ASSUME_YES )) || \
      die "检测到多个 NoneBot 实例；请使用 --plugin-target <容器名|all>"
    [[ -t 0 ]] || \
      die "检测到多个 NoneBot 实例但当前不是交互终端；请使用 --plugin-target"
    printf '  %d) 全部实例\n' "$((${#instance_names[@]} + 1))"
    while true; do
      read -r -p "请选择插件安装目标 [1-$((${#instance_names[@]} + 1))]: " choice
      if [[ "$choice" =~ ^[0-9]+$ \
        && "$choice" -ge 1 \
        && "$choice" -le "$((${#instance_names[@]} + 1))" ]]; then
        break
      fi
      warn "请输入有效的实例编号"
    done
    if [[ "$choice" -eq "$((${#instance_names[@]} + 1))" ]]; then
      for index in "${!instance_names[@]}"; do
        selected+=("$index")
      done
    else
      selected=("$((choice - 1))")
    fi
  fi

  if [[ -z "$plugin_input" ]]; then
    (( ! ASSUME_YES )) || die "--mode nonebot-plugin --yes 需要 --plugin"
    while [[ -z "$plugin_input" ]]; do
      plugin_input="$(
        prompt_value \
          "PyPI 插件规格或 GitHub 仓库（例如 nonebot-plugin-parser 或 https://github.com/owner/repo）" \
          ""
      )"
    done
  fi
  validate_single_line plugin "$plugin_input"
  [[ "$plugin_input" != *[[:space:]]* ]] || \
    die "插件规格不能包含空白；导入名请使用 --plugin-import"
  github_candidate="${plugin_input#git+}"
  github_candidate="${github_candidate%/}"
  if [[ "$github_candidate" =~ ^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$ ]]; then
    github_owner="${BASH_REMATCH[1]}"
    github_repo="${BASH_REMATCH[2]%.git}"
    source_kind="github"
  elif [[ "$github_candidate" =~ ^git@github\.com:([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$ ]]; then
    github_owner="${BASH_REMATCH[1]}"
    github_repo="${BASH_REMATCH[2]%.git}"
    source_kind="github"
  elif [[ "$github_candidate" =~ ^github:([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$ \
    || "$github_candidate" =~ ^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$ ]]; then
    github_owner="${BASH_REMATCH[1]}"
    github_repo="${BASH_REMATCH[2]%.git}"
    source_kind="github"
  fi

  if [[ "$source_kind" == "github" ]]; then
    for path_component in "$github_owner" "$github_repo"; do
      case "$path_component" in
        ""|"."|"..")
          die "无效的 GitHub 仓库路径：${plugin_input}"
          ;;
      esac
    done
  fi

  if [[ -n "$plugin_import" \
    && ! "$plugin_import" =~ ^[A-Za-z_][A-Za-z0-9_.]*$ ]]; then
    die "--plugin-import 必须是有效的 Python 模块名"
  fi

  if [[ "$source_kind" == "github" ]]; then
    github_url="https://github.com/${github_owner}/${github_repo}.git"
    resolved_import="${plugin_import:-${github_repo//-/_}}"
    resolved_import="${resolved_import//./_}"
    log "GitHub 仓库：${github_url}"
  else
    [[ "$plugin_input" != -* \
      && "$plugin_input" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*(\[[A-Za-z0-9._,-]+\])?([\<\>\=\!\~]{1,2}[A-Za-z0-9*+._!-]+(,[\<\>\=\!\~]{1,2}[A-Za-z0-9*+._!-]+)*)?$ ]] || \
      die "无效的 PyPI 插件规格：${plugin_input}"
    package_name="$(
      printf '%s' "$plugin_input" \
        | sed -E 's/(\[[^]]*\])?([<>=!~].*)?$//'
    )"
    resolved_import="${plugin_import:-${package_name//-/_}}"
    resolved_import="${resolved_import//./_}"
    plugin_line="${plugin_input} ${resolved_import}"
    log "PyPI 插件：${plugin_input}（导入名：${resolved_import}）"
  fi

  for selected_index in "${selected[@]}"; do
    container_name="${instance_names[selected_index]}"
    plugins_dir="${instance_plugins[selected_index]}"
    if [[ "$source_kind" == "github" ]]; then
      if nonebot_plugins_txt_has_package \
        "${plugins_dir}/plugins.txt" "$github_repo"; then
        die "${container_name} 的 plugins.txt 已包含 ${github_repo}；请先移除 PyPI 条目再改用 GitHub 仓库"
      fi
    else
      for repo_candidate in "$plugins_dir"/*; do
        [[ -d "${repo_candidate}/.git" ]] || continue
        repo_candidate_name="$(
          canonical_nonebot_plugin_name "${repo_candidate##*/}"
        )"
        if [[ "$repo_candidate_name" == \
          "$(canonical_nonebot_plugin_name "$package_name")" ]]; then
          die "${container_name} 已存在同名 GitHub 源码目录 ${repo_candidate##*/}；请先移除源码目录再改用 PyPI"
        fi
      done
    fi
    old_marker="$(
      "$DOCKER_BIN" exec "$container_name" sh -c \
        'cat /app/site-packages/.nag-deps-hash 2>/dev/null || true' \
        2>/dev/null || true
    )"
    if ((DRY_RUN)); then
      if [[ "$source_kind" == "github" ]]; then
        printf '[dry-run] 将克隆/更新 %s 到 %s/%s\n' \
          "$github_url" "${instance_plugins[selected_index]}" "$github_repo"
      else
        printf '[dry-run] 将写入 %s/plugins.txt：%s\n' \
          "${instance_plugins[selected_index]}" "$plugin_line"
      fi
      printf '[dry-run] 将重启并验证容器：%s\n' "$container_name"
      continue
    fi

    if [[ "$source_kind" == "github" ]]; then
      install_nonebot_github_repo \
        "${instance_plugins[selected_index]}" "$github_url" \
        "$github_repo" "$plugin_import"
      resolved_import="$NONEBOT_PLUGIN_RESOLVED_IMPORT"
      changed="$NONEBOT_PLUGIN_CONTENT_CHANGED"
    else
      upsert_nonebot_plugin_spec \
        "${instance_plugins[selected_index]}" "$package_name" "$plugin_line"
      changed="$NONEBOT_PLUGIN_CONTENT_CHANGED"
    fi

    started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    log "重启 ${container_name}，由 NoneBot 自动解析并安装插件依赖"
    "$DOCKER_BIN" restart "$container_name" >/dev/null
    wait_nonebot_plugin_ready \
      "$container_name" "$resolved_import" "$old_marker" \
      "$changed" "$started_at"
    log "插件 ${resolved_import} 已在 ${container_name} 中安装并通过启动检查"
  done

  if ((DRY_RUN)); then
    log "dry-run 完成；未修改插件目录或容器"
  fi
}

choose_mode

if [[ "$MODE" != "status" ]]; then
  acquire_installer_lock
fi

if [[ "$MODE" == "status" ]]; then
  status_mode
  exit 0
fi

if [[ "$MODE" == "uninstall" ]]; then
  uninstall_mode
  exit 0
fi

if [[ "$MODE" == "botshepherd-ports" ]]; then
  manage_botshepherd_ports
  exit 0
fi

if [[ "$MODE" == "nonebot-plugin" ]]; then
  nonebot_plugin_mode
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
    die "不支持的模式：$MODE（可用：astrbot、hybrid、napcat、nonebot、nonebot-napcat）"
    ;;
esac

preflight_environment

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
GSCORE_PORT="$(prompt_port "GsCore WebUI 端口" "$(env_default GSCORE_PORT "8765")" "$(env_value GSCORE_PORT "$ENV_FILE" || true)" "$BIND_IP")"
NAPCAT_WEBUI_PORT="$(prompt_port "NapCat WebUI 端口" "$(env_default NAPCAT_WEBUI_PORT "6099")" "$(env_value NAPCAT_WEBUI_PORT "$ENV_FILE" || true)" "$BIND_IP")"
ASTRBOT_WEBUI_PORT="$(env_default ASTRBOT_WEBUI_PORT "6185")"
BOTSHEPHERD_WEBUI_PORT="$(env_default BOTSHEPHERD_WEBUI_PORT "5111")"
if [[ "$FRAMEWORK_KIND" == "astrbot" ]]; then
  ASTRBOT_WEBUI_PORT="$(prompt_port "AstrBot WebUI 端口" "$ASTRBOT_WEBUI_PORT" "$(env_value ASTRBOT_WEBUI_PORT "$ENV_FILE" || true)" "$BIND_IP")"
fi
if ((USE_BOTSHEPHERD)); then
  BOTSHEPHERD_WEBUI_PORT="$(prompt_port "BotShepherd WebUI 端口" "$BOTSHEPHERD_WEBUI_PORT" "$(env_value BOTSHEPHERD_WEBUI_PORT "$ENV_FILE" || true)" "$BIND_IP")"
fi

DATA_ROOT="$(validated_data_root "$DATA_ROOT")"
case "$BIND_IP" in
  127.0.0.1|0.0.0.0) ;;
  *) die "BIND_IP 必须是 127.0.0.1 或 0.0.0.0" ;;
esac
validate_port GSCORE_PORT "$GSCORE_PORT"
validate_port NAPCAT_WEBUI_PORT "$NAPCAT_WEBUI_PORT"
if [[ "$FRAMEWORK_KIND" == "astrbot" ]]; then
  validate_port ASTRBOT_WEBUI_PORT "$ASTRBOT_WEBUI_PORT"
fi
if ((USE_BOTSHEPHERD)); then
  validate_port BOTSHEPHERD_WEBUI_PORT "$BOTSHEPHERD_WEBUI_PORT"
fi
[[ "$GSCORE_PORT" != "$NAPCAT_WEBUI_PORT" ]] || die "GsCore 与 NapCat 端口不能相同"
if [[ "$FRAMEWORK_KIND" == "astrbot" ]]; then
  [[ "$GSCORE_PORT" != "$ASTRBOT_WEBUI_PORT" && "$NAPCAT_WEBUI_PORT" != "$ASTRBOT_WEBUI_PORT" ]] || \
    die "所有 WebUI 端口必须互不相同"
fi
if ((USE_BOTSHEPHERD)); then
  [[ "$BOTSHEPHERD_WEBUI_PORT" != "$GSCORE_PORT" \
    && "$BOTSHEPHERD_WEBUI_PORT" != "$NAPCAT_WEBUI_PORT" ]] || \
    die "所有 WebUI 端口必须互不相同"
  if [[ "$FRAMEWORK_KIND" == "astrbot" ]]; then
    [[ "$BOTSHEPHERD_WEBUI_PORT" != "$ASTRBOT_WEBUI_PORT" ]] || \
      die "所有 WebUI 端口必须互不相同"
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

if ((INSTALL_WUWA)) && prompt_yes_no "使用 CNB 镜像克隆鸣潮插件（适合 GitHub 访问较慢时）" "$(cnb_mirror_default)"; then
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

NAPCAT_ADAPTER_URL="$(env_default NAPCAT_GSCORE_ADAPTER_ZIP_URL "$NAPCAT_ADAPTER_PINNED_URL")"
NAPCAT_ADAPTER_SHA256="$(env_default NAPCAT_GSCORE_ADAPTER_SHA256 "")"
if [[ "$NAPCAT_ADAPTER_URL" == "$NAPCAT_ADAPTER_LEGACY_LATEST_URL" \
  && -z "$NAPCAT_ADAPTER_SHA256" ]]; then
  NAPCAT_ADAPTER_URL="$NAPCAT_ADAPTER_PINNED_URL"
  NAPCAT_ADAPTER_SHA256="$NAPCAT_ADAPTER_PINNED_SHA256"
  log "将旧版 NapCat 适配器 latest 地址迁移为已校验的 v1.3.3 固定版本"
fi
if [[ "$NAPCAT_ADAPTER_URL" == "$NAPCAT_ADAPTER_PINNED_URL" \
  && -z "$NAPCAT_ADAPTER_SHA256" ]]; then
  NAPCAT_ADAPTER_SHA256="$NAPCAT_ADAPTER_PINNED_SHA256"
fi
if [[ "$ADAPTER_KIND" == "napcat" ]] && (( ! ASSUME_YES )); then
  NAPCAT_ADAPTER_URL="$(prompt_value "NapCat GScore 适配器 ZIP 地址" "$NAPCAT_ADAPTER_URL")"
  if [[ "$NAPCAT_ADAPTER_URL" == "$NAPCAT_ADAPTER_PINNED_URL" ]]; then
    NAPCAT_ADAPTER_SHA256="$NAPCAT_ADAPTER_PINNED_SHA256"
  else
    NAPCAT_ADAPTER_SHA256="$(
      prompt_value "NapCat GScore 适配器 ZIP 的 SHA-256" "$NAPCAT_ADAPTER_SHA256"
    )"
  fi
fi
if [[ "$ADAPTER_KIND" == "napcat" ]]; then
  [[ "$NAPCAT_ADAPTER_SHA256" =~ ^[A-Fa-f0-9]{64}$ ]] || \
    die "NapCat GScore 适配器需要有效的 64 位 SHA-256"
  NAPCAT_ADAPTER_SHA256="${NAPCAT_ADAPTER_SHA256,,}"
fi

GSCORE_WS_TOKEN="$(env_default GSCORE_WS_TOKEN "")"
if [[ -z "$GSCORE_WS_TOKEN" ]]; then
  command -v od >/dev/null 2>&1 || die "生成 GSCORE_WS_TOKEN 需要 od 命令"
  GSCORE_WS_TOKEN="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
fi
[[ "$GSCORE_WS_TOKEN" =~ ^[A-Za-z0-9._~-]+$ ]] || \
  die "GSCORE_WS_TOKEN 只能包含字母、数字、点、下划线、波浪线和连字符"

for pair in \
  "DATA_ROOT=$DATA_ROOT" "BIND_IP=$BIND_IP" \
  "GSCORE_PORT=$GSCORE_PORT" "ASTRBOT_WEBUI_PORT=$ASTRBOT_WEBUI_PORT" \
  "BOTSHEPHERD_WEBUI_PORT=$BOTSHEPHERD_WEBUI_PORT" \
  "NAPCAT_WEBUI_PORT=$NAPCAT_WEBUI_PORT" "NAPCAT_ADAPTER_URL=$NAPCAT_ADAPTER_URL" \
  "NAPCAT_ADAPTER_SHA256=$NAPCAT_ADAPTER_SHA256" \
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
  log "dry-run 完成；未改动任何文件、容器或目录"
  exit 0
fi

if ! prompt_yes_no "确认开始安装" y; then
  log "已取消安装"
  exit 0
fi

case "$(uname -m)" in
  x86_64|amd64|aarch64|arm64) ;;
  *) warn "NapCat Docker 镜像未声明支持当前架构（$(uname -m)）" ;;
esac
if ((USE_BOTSHEPHERD)); then
  case "$(uname -m)" in
    x86_64|amd64) ;;
    *) die "BotShepherd 官方镜像目前仅支持 linux/amd64" ;;
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
chmod 600 "$tmp_identity"

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
MIMO_PERSONAL_PORT=${MIMO_PERSONAL_PORT:-18081}
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
NAPCAT_GSCORE_ADAPTER_SHA256=$NAPCAT_ADAPTER_SHA256
ASTRBOT_GSCORE_ADAPTER_REPO=https://github.com/KimigaiiWuyi/astrbot_plugin_gscore_adapter.git
XUTHERINGWAVESUID_REPO=$XUTHERINGWAVESUID_REPO
ROVERSIGN_REPO=$ROVERSIGN_REPO
SCOREECHO_REPO=$SCOREECHO_REPO
GSCORE_PYTHON_INDEX=$(gscore_python_index)
NONEBOT_PYTHON_INDEX=$(gscore_python_index)
NONEBOT_COMMAND_START=$(env_default NONEBOT_COMMAND_START "/")
GSCORE_WS_TOKEN=$GSCORE_WS_TOKEN
UV_NO_CONFIG=0
PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
GSCORE_XWUID_PYTHON_PACKAGES=playwright opencv-python fonttools pypinyin
EOF
chmod 600 "$tmp_env"

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
    "$DATA_ROOT/nonebot/cache"
    "$DATA_ROOT/nonebot/project"
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
  command -v sudo >/dev/null 2>&1 || die "无法创建 $DATA_ROOT 且系统无 sudo"
  log "需要 sudo 创建数据目录"
  sudo install -d -m 0755 -o "$NAPCAT_UID" -g "$NAPCAT_GID" "${DATA_DIRS[@]}"
fi
mark_data_root "$DATA_ROOT"

PERSONAL_NONEBOT_PROJECT="$DATA_ROOT/nonebot/project"
PERSONAL_MIMO_PORT="${MIMO_PERSONAL_PORT:-18081}"
if [[ "$FRAMEWORK_KIND" == "nonebot" ]]; then
  write_official_nonebot_environment \
    personal "${PERSONAL_NONEBOT_PROJECT}/.env.prod" "$NAPCAT_MASTER_QQ" \
    NoneBot2 "$GSCORE_WS_TOKEN" \
    "$(env_value NONEBOT_COMMAND_START "$tmp_env")" personal
  log "按 NoneBot 官方 CLI 流程生成个人 QQ 项目"
  prepare_official_nonebot_instance \
    personal \
    "$([[ "$ADAPTER_KIND" == "nonebot" ]] && printf true || printf false)" \
    "$PERSONAL_NONEBOT_PROJECT" "${PERSONAL_NONEBOT_PROJECT}/.env.prod" \
    "$DATA_ROOT/nonebot/data" "$DATA_ROOT/nonebot/cache" \
    nag-nonebot-personal nag-nonebot nonebot nag_nag-net \
    "$PERSONAL_MIMO_PORT" /etc/mimo-console-agent/personal.token \
    local/nag-nonebot-personal
fi

for data_dir in "${DATA_DIRS[@]}"; do
  [[ -w "$data_dir" ]] || die "$data_dir 对 UID $NAPCAT_UID 不可写；请修正属主或权限"
done

if [[ "$ADAPTER_KIND" == "napcat" && "$FRAMEWORK_KIND" == "astrbot" \
  && -e "$DATA_ROOT/astrbot/plugins/astrbot_plugin_gscore_adapter" ]]; then
  warn "持久化数据中已存在 AstrBot GScore 适配器；使用 NapCat 适配器前请先停用它，避免重复处理"
fi

COMPOSE=("$DOCKER_BIN" compose --project-directory "$PROJECT_DIR" --env-file "$tmp_env" -p "$PROJECT_NAME")
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

  log "等待 GsCore WebUI 就绪（${stage}）"
  for ((attempt = 1; attempt <= 90; attempt++)); do
    if compose exec -T gscore /venv/bin/python -c \
      'from urllib.request import urlopen; response = urlopen("http://127.0.0.1:8765/app/", timeout=3); assert response.status == 200' \
      >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  compose logs --tail=100 gscore || true
  die "GsCore WebUI 180 秒内未就绪（${stage}）"
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

  log "等待 AstrBot 创建 cmd_config.json"
  for ((attempt = 1; attempt <= 60; attempt++)); do
    if compose exec -T astrbot sh -c 'test -s /AstrBot/data/cmd_config.json' \
      >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  compose logs --tail=100 astrbot || true
  die "AstrBot 120 秒内未创建 data/cmd_config.json"
}

wait_astrbot_onebot_listener() {
  local attempt

  log "等待 AstrBot OneBot v11 监听（端口 6199）"
  for ((attempt = 1; attempt <= 60; attempt++)); do
    if compose exec -T astrbot python -c \
      'import socket; connection = socket.create_connection(("127.0.0.1", 6199), timeout=3); connection.close()' \
      >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  compose logs --tail=100 astrbot || true
  die "AstrBot OneBot v11 监听 120 秒内未在端口 6199 就绪"
}

wait_nonebot_ready() {
  local attempt

  log "等待 NoneBot OneBot v11 监听（端口 8080）"
  for ((attempt = 1; attempt <= 60; attempt++)); do
    if "$DOCKER_BIN" exec nag-nonebot python -c \
      'import socket; connection = socket.create_connection(("127.0.0.1", 8080), timeout=3); connection.close()' \
      >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  "$DOCKER_BIN" logs --tail=100 nag-nonebot || true
  die "NoneBot 120 秒内未在端口 8080 就绪"
}

wait_botshepherd_ready() {
  local attempt

  log "等待 BotShepherd WebUI 与 OneBot 监听"
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
  die "BotShepherd 120 秒内未就绪"
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
    die "NapCat 适配器模式解析到不安全的镜像：${resolved_napcat_image:-unknown}"
fi

log "拉取运行时镜像"
if [[ "$FRAMEWORK_KIND" == "nonebot" ]]; then
  compose pull gscore napcat
  if ((USE_BOTSHEPHERD)); then
    compose pull botshepherd
  fi
else
  compose pull
fi

log "启动 GsCore"
compose up -d gscore

log "等待 GsCore 持久化 Python 环境"
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
  die "GsCore 120 秒内未创建 /venv/bin/python 与 data/config.json"
fi

wait_gscore_ready "before configuring the WebSocket token"

log "配置 GsCore WebSocket token 与主人账号"
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
    log "安装 AstrBot GScore 适配器"
    compose --profile init run --rm astrbot-plugin-init
    ;;
  napcat)
    log "安装 NapCat GScore 适配器"
    compose --profile init run --rm napcat-gscore-adapter-init
    ;;
  nonebot)
    log "停用 NapCat GScore 适配器以避免重复回复"
    compose --profile init run --rm napcat-gscore-adapter-disable
    ;;
esac

if [[ "$FRAMEWORK_KIND" == "nonebot" ]]; then
  log "配置 NapCat 反向 WebSocket 客户端（连接 NoneBot）"
  compose --profile init run --rm nonebot-onebot-init
  if [[ -n "$(compose ps -aq nonebot 2>/dev/null || true)" ]]; then
    log "移除旧版 NAG 自定义 NoneBot 服务"
    compose rm --stop --force nonebot >/dev/null
  fi
  log "通过 nb docker build/up 启动个人 QQ NoneBot"
  official_nonebot_cli "$PERSONAL_NONEBOT_PROJECT" nag-nonebot-personal build
  official_nonebot_cli "$PERSONAL_NONEBOT_PROJECT" nag-nonebot-personal up -d
  wait_nonebot_ready
  if ((USE_BOTSHEPHERD)); then
    compose up -d botshepherd
    wait_botshepherd_ready
  fi
  compose up -d napcat
else
  log "启动所选服务"
  compose up -d
fi

if [[ "$FRAMEWORK_KIND" == "astrbot" ]]; then
  wait_astrbot_config
  log "配置 AstrBot OneBot v11 平台与 NapCat 反向 WebSocket 客户端"
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
  log "所选基础服务启动完成，先停止 GsCore 以初始化插件"
  compose stop gscore
fi

if ((INSTALL_WUWA)); then
  log "克隆或更新鸣潮插件套件"
  compose --profile init run --rm gscore-plugin-init
fi

if ((INSTALL_WUWA_DEPS)); then
  log "安装鸣潮插件额外依赖与 Chromium"
  compose --profile init run --rm gscore-xwuid-deps-init
fi

if ((INSTALL_WUWA || INSTALL_WUWA_DEPS)); then
  log "以完成初始化的插件环境启动 GsCore"
  compose up -d gscore
  wait_gscore_ready "after installing plugins and dependencies"
fi

GSCORE_REGISTER_CODE=""
if ! GSCORE_REGISTER_CODE="$(read_gscore_register_code)" || [[ -z "$GSCORE_REGISTER_CODE" ]]; then
  warn "GsCore 已启动，但无法从 data/config.json 读取 REGISTER_CODE"
  GSCORE_REGISTER_CODE=""
fi

NAPCAT_WEBUI_TOKEN=""
log "等待 NapCat WebUI Token"
if ! NAPCAT_WEBUI_TOKEN="$(wait_napcat_webui_token)"; then
  warn "NapCat 已启动，但 120 秒内未在日志中找到 WebUI Token"
fi

ASTRBOT_INITIAL_PASSWORD=""
if [[ "$FRAMEWORK_KIND" == "astrbot" ]]; then
  log "等待 AstrBot 初始 WebUI 密码"
  if ! ASTRBOT_INITIAL_PASSWORD="$(wait_astrbot_initial_password)"; then
    warn "AstrBot 已启动，但当前日志中没有初始 WebUI 密码；复用已有 AstrBot 数据时属正常现象"
  fi
fi

BOTSHEPHERD_INITIAL_PASSWORD=""
if ((USE_BOTSHEPHERD)); then
  log "等待 BotShepherd 初始 WebUI 密码"
  if ! BOTSHEPHERD_INITIAL_PASSWORD="$(wait_botshepherd_initial_password)"; then
    warn "BotShepherd 已启动，但当前日志中没有初始 WebUI 密码；复用已有 BotShepherd 数据时属正常现象"
  fi
fi
MIMO_SETUP_TOKEN=""
if [[ "$FRAMEWORK_KIND" == "nonebot" ]]; then
  MIMO_SETUP_TOKEN="$(
    wait_mimo_setup_token nag-nonebot || true
  )"
fi
compose ps
if [[ "$FRAMEWORK_KIND" == "nonebot" ]]; then
  official_nonebot_cli "$PERSONAL_NONEBOT_PROJECT" nag-nonebot-personal ps
fi

# Deployment succeeded; only now replace the previous private environment and
# shared NapCat identity, then point the printed status command at them.
mv -f "$tmp_env" "$ENV_FILE"
chmod 600 "$ENV_FILE"
mv -f "$tmp_identity" "$NAPCAT_IDENTITY_FILE"
chmod 600 "$NAPCAT_IDENTITY_FILE"
for compose_index in "${!COMPOSE[@]}"; do
  if [[ "${COMPOSE[compose_index]}" == "$tmp_env" ]]; then
    COMPOSE[compose_index]="$ENV_FILE"
  fi
done

cat <<EOF

安装完成。

WebUI：
  GsCore: http://${BIND_IP}:${GSCORE_PORT}/app/
  GsCore 注册码: ${GSCORE_REGISTER_CODE:-未读取到，请查看 $DATA_ROOT/gscore/data/config.json 中的 REGISTER_CODE}
  NapCat: http://${BIND_IP}:${NAPCAT_WEBUI_PORT}
EOF
if [[ "$FRAMEWORK_KIND" == "nonebot" ]]; then
  printf '  Mimo Console: http://127.0.0.1:%s/mimo-console/\n' \
    "$PERSONAL_MIMO_PORT"
  if [[ -n "$MIMO_SETUP_TOKEN" ]]; then
    printf '  Mimo Console 初始化令牌: %s\n' "$MIMO_SETUP_TOKEN"
  fi
fi
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
