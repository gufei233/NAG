import hashlib
import importlib
import os
import shutil
import subprocess
import sys

PLUGINS_DIR = "/app/plugins"
SITE_DIR = "/app/site-packages"
CONSTRAINTS_FILE = "/app/constraints.txt"
DEPS_MARKER = os.path.join(SITE_DIR, ".nag-deps-hash")

# 追加而非前置：nonebot 的适配器以子包形式合入镜像内的 nonebot/ 包树，
# 持久目录若被 pip 写入基础版 nonebot/ 会遮蔽适配器导致启动失败
sys.path.append(SITE_DIR)

import nonebot
from nonebot.log import logger


def split_accounts(value: str) -> set[str]:
    return {account.strip() for account in value.split(",") if account.strip()}


platform = os.getenv("NONEBOT_PLATFORM", "onebot").lower()
config = {
    "superusers": split_accounts(os.getenv("NAPCAT_MASTER_QQ", "")),
    "gsuid_core_host": os.getenv("GSUID_CORE_HOST", "gscore"),
    "gsuid_core_port": os.getenv("GSUID_CORE_PORT", "8765"),
    "gsuid_core_botid": os.getenv("GSUID_CORE_BOTID", "NoneBot2"),
    "gsuid_core_ws_token": os.getenv("GSUID_CORE_WS_TOKEN", ""),
    "gsuid_core_repeat": (
        os.getenv("GSUID_CORE_REPEAT", "true").lower() in {"1", "true", "yes"}
    ),
}

# 命令前缀：逗号分隔（如 "#" 或 "#,/"，空串元素表示允许无前缀）；未设置时保持
# NoneBot 默认的 "/"
command_start_env = os.getenv("NONEBOT_COMMAND_START")
if command_start_env is not None:
    config["command_start"] = {part.strip() for part in command_start_env.split(",")}

if platform == "qqofficial":
    config.update(
        qq_is_sandbox=(
            os.getenv("QQ_IS_SANDBOX", "false").lower() in {"1", "true", "yes"}
        ),
        qq_bots=[
            {
                "id": os.environ["QQ_APP_ID"],
                "token": os.environ["QQ_TOKEN"],
                "secret": os.environ["QQ_APP_SECRET"],
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
    )

nonebot.init(**config)

driver = nonebot.get_driver()
if platform == "qqofficial":
    from nonebot.adapters.qq import Adapter as QQAdapter

    driver.register_adapter(QQAdapter)
else:
    from nonebot.adapters.onebot.v11 import Adapter as OneBotV11Adapter

    driver.register_adapter(OneBotV11Adapter)

if os.getenv("ENABLE_NONEBOT_GSCORE_ADAPTER", "false").lower() in {
    "1",
    "true",
    "yes",
}:
    nonebot.load_plugin("GenshinUID")


# --- NAG 目录插件层 ---------------------------------------------------------
# /app/plugins 支持三种形态，依赖统一装进挂载的 /app/site-packages：
#   1. plugins.txt：每行一个 pip 规格（PyPI 名或 git+URL），第二列可写导入名，
#      写 "-" 表示只安装依赖不作为插件加载（用于补装插件未声明的依赖）
#   2. 仓库检出：git clone 的插件仓库，自动识别内层 nonebot_plugin_* 包与依赖声明
#   3. 普通包目录（含 __init__.py）或单文件 xxx.py
# 依赖声明汇总后做哈希，与上次一致则跳过 pip，保证日常启动零开销。


def _derive_import_name(spec: str) -> str | None:
    base = spec
    for sep in ("==", ">=", "<=", "~=", "!=", ">", "<", "@", "["):
        base = base.split(sep)[0]
    base = base.strip()
    if base.startswith(("git+", "http://", "https://")):
        return None
    return base.replace("-", "_")


def _read_text(path: str) -> str:
    try:
        with open(path, encoding="utf-8-sig") as fh:
            return fh.read()
    except OSError:
        return ""


def _repo_dependency_texts(repo: str) -> list[str]:
    texts = []
    req = _read_text(os.path.join(repo, "requirements.txt"))
    if req:
        texts.append(req)
    pyproject = os.path.join(repo, "pyproject.toml")
    if os.path.isfile(pyproject):
        try:
            import tomllib

            with open(pyproject, "rb") as fh:
                data = tomllib.load(fh)
            deps = data.get("project", {}).get("dependencies", [])
            if deps:
                texts.append("\n".join(str(dep) for dep in deps))
        except Exception as exc:  # noqa: BLE001 - 插件清单损坏不应阻断启动
            logger.warning(f"解析 {pyproject} 失败，忽略其中的依赖声明：{exc}")
    return texts


def _find_inner_nb_package(repo: str) -> tuple[str, str] | None:
    for base in (repo, os.path.join(repo, "src")):
        if not os.path.isdir(base):
            continue
        for child in sorted(os.listdir(base)):
            if child.startswith("nonebot_plugin_") and os.path.isfile(
                os.path.join(base, child, "__init__.py")
            ):
                return base, child
    return None


def _scan_plugin_sources() -> tuple[list[str], list[str], list[str], str]:
    pip_specs: list[str] = []
    load_names: list[str] = []
    extra_paths: list[str] = []
    manifest_parts: list[str] = ["v1"]

    if not os.path.isdir(PLUGINS_DIR):
        return pip_specs, load_names, extra_paths, "\n".join(manifest_parts)

    plugins_txt = os.path.join(PLUGINS_DIR, "plugins.txt")
    txt_content = _read_text(plugins_txt)
    if txt_content:
        manifest_parts.append("plugins.txt:\n" + txt_content)
        for raw in txt_content.splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            spec = parts[0]
            if len(parts) > 1:
                name = None if parts[1] == "-" else parts[1]
            else:
                name = _derive_import_name(spec)
                if name is None:
                    logger.warning(
                        f"plugins.txt 中 {spec} 未提供导入名（第二列，或写 - 表示只安装），只安装不加载"
                    )
            pip_specs.append(spec)
            if name:
                load_names.append(name)

    for entry in sorted(os.listdir(PLUGINS_DIR)):
        if entry.startswith((".", "_")) or entry == "plugins.txt":
            continue
        path = os.path.join(PLUGINS_DIR, entry)
        if os.path.isfile(path):
            if entry.endswith(".py"):
                load_names.append(entry[:-3])
            continue
        if not os.path.isdir(path):
            continue
        inner = _find_inner_nb_package(path)
        if inner:
            pkg_base, pkg_name = inner
            extra_paths.append(pkg_base)
            load_names.append(pkg_name)
            dep_texts = _repo_dependency_texts(path)
            pip_specs.extend(
                line.strip()
                for text in dep_texts
                for line in text.splitlines()
                if line.strip() and not line.strip().startswith(("#", "-"))
            )
            manifest_parts.append(f"repo:{entry}:{pkg_name}\n" + "\n".join(dep_texts))
        elif os.path.isfile(os.path.join(path, "__init__.py")):
            load_names.append(entry)
        elif os.path.isfile(os.path.join(path, "pyproject.toml")):
            logger.warning(
                f"插件目录 {entry} 未找到 nonebot_plugin_* 包，无法识别入口，已跳过"
            )

    return pip_specs, load_names, extra_paths, "\n".join(manifest_parts)


def _prune_shadowing_packages() -> None:
    """移除 pip --target 带进来的 nonebot 基础包，避免遮蔽镜像内含适配器的完整包树。"""
    target = os.path.join(SITE_DIR, "nonebot")
    if os.path.isdir(target):
        shutil.rmtree(target, ignore_errors=True)
    try:
        entries = os.listdir(SITE_DIR)
    except OSError:
        return
    for entry in entries:
        if entry.endswith(".dist-info") and entry.startswith(
            ("nonebot2-", "nonebot_adapter_")
        ):
            shutil.rmtree(os.path.join(SITE_DIR, entry), ignore_errors=True)


def _ensure_dependencies(pip_specs: list[str], manifest: str) -> None:
    runtime_fingerprint = "\n".join(
        (
            f"python:{sys.version_info.major}.{sys.version_info.minor}",
            "constraints:",
            _read_text(CONSTRAINTS_FILE),
        )
    )
    digest = hashlib.sha256(
        f"{manifest}\n{runtime_fingerprint}".encode("utf-8")
    ).hexdigest()
    if os.path.isfile(DEPS_MARKER) and _read_text(DEPS_MARKER).strip() == digest:
        return
    if pip_specs:
        os.makedirs(SITE_DIR, exist_ok=True)
        command = [
            sys.executable,
            "-m",
            "pip",
            "install",
            "--no-cache-dir",
            "--disable-pip-version-check",
            "--upgrade",
            "--target",
            SITE_DIR,
        ]
        index_url = os.getenv("NONEBOT_PYTHON_INDEX", "").strip()
        if index_url:
            command += ["-i", index_url]
        if os.path.isfile(CONSTRAINTS_FILE):
            command += ["-c", CONSTRAINTS_FILE]
        command += pip_specs
        logger.info(f"安装/更新目录插件依赖：{', '.join(pip_specs)}")
        result = subprocess.run(command, check=False)
        if result.returncode != 0:
            logger.warning(
                "插件依赖安装失败，相关插件本次可能无法加载；"
                "排查网络或依赖冲突后重启容器会自动重试"
            )
            return
        _prune_shadowing_packages()
    try:
        os.makedirs(SITE_DIR, exist_ok=True)
        with open(DEPS_MARKER, "w", encoding="utf-8") as fh:
            fh.write(digest + "\n")
    except OSError as exc:
        logger.warning(f"写入依赖标记失败（不影响本次运行）：{exc}")


def _load_directory_plugins() -> None:
    pip_specs, load_names, extra_paths, manifest = _scan_plugin_sources()
    _ensure_dependencies(pip_specs, manifest)
    for path in extra_paths:
        if path not in sys.path:
            sys.path.insert(0, path)
    if os.path.isdir(PLUGINS_DIR) and PLUGINS_DIR not in sys.path:
        sys.path.insert(0, PLUGINS_DIR)
    importlib.invalidate_caches()
    seen: set[str] = set()
    for name in load_names:
        if name in seen:
            continue
        seen.add(name)
        try:
            nonebot.load_plugin(name)
        except Exception as exc:  # noqa: BLE001 - 单个插件失败不应拖垮整个实例
            logger.warning(f"加载插件 {name} 失败：{exc}")


_load_directory_plugins()

nonebot.run()
