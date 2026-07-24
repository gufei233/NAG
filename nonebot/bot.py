import os

import nonebot


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

nonebot.load_plugins("/app/plugins")
nonebot.run()
