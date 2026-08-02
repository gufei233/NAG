# NG

NapCat + GsCore 的轻量 Docker Compose 部署模板。

推荐在仓库根目录运行：

```bash
bash install.sh --mode napcat
```

这个预设就是 NG 轻量方案。安装器会询问主人 QQ，将同一列表写入 GsCore 的 `masters` 和 NapCat 适配器，完成容器、插件和额外依赖初始化，自动配置 `ws://gscore:8765` 与共享 `WS_TOKEN`；结束时还会直接显示 GsCore 的首次注册 `REGISTER_CODE`。

本目录面向不需要 AstrBot / LLM / 多平台管理，只想让 NapCat 直接把 QQ 消息转发给 GsCore 的用户：

```text
GsCore <-> napcat-plugin-gscore-adapter <-> NapCatQQ <-> QQ
```

Sayu 文档把 `napcat-plugin-gscore-adapter` 列在“协议端插件直接链接”方案中。插件本身运行在 NapCat 内，通过 WebSocket 连接 GsCore，因此本 compose 只需要启动 `gscore` 和 `napcat` 两个常驻容器。

> [!IMPORTANT]
> NG 默认将 NapCat 镜像固定为 `mlikiowa/napcat-docker:v4.18.5`。这是 NapCatQQ 在 v4.18.6 引入官方插件白名单和敏感词检测前的最后一个正式版本，用于保证 `napcat-plugin-gscore-adapter` 可以加载。不要把 `NAPCAT_IMAGE` 改回 `latest` 或升级到 v4.18.6 及以上，除非该插件已进入官方白名单或完成兼容适配。

## 和 NAG 版本的区别

```text
NAG: GsCore <-> AstrBot <-> NapCatQQ
NG:  GsCore <-> NapCat 插件 <-> NapCatQQ
```

选择 NG，如果你：

- 不需要 AstrBot 的 LLM、WebUI 机器人管理、多平台接入能力；
- 只需要 QQ 个人号 + GsCore 指令；
- 希望容器更少、链路更短。

继续使用 NAG，如果你：

- 需要 AstrBot 的 AI 对话、多平台、插件生态；
- 希望通过 AstrBot 统一管理多个机器人能力；
- 已经在使用 `astrbot_plugin_gscore_adapter`。

## 手动 Compose 快速开始

如果你不使用根目录的安装器，也可以直接维护本目录的 Compose 配置：

```bash
cd NG
cp .env.example .env
```

如果你是 root 用户部署：

```bash
mkdir -p /opt/ng-data/{napcat/config,napcat/plugins,napcat/qq,gscore/data,gscore/plugins}
```

如果你不是 root 用户部署，先创建目录并把 `DATA_ROOT` 交给当前用户，再启动 compose：

```bash
sudo mkdir -p /opt/ng-data/{napcat/config,napcat/plugins,napcat/qq,gscore/data,gscore/plugins}
sudo chown -R "$(id -u):$(id -g)" /opt/ng-data
sed -i "s/^NAPCAT_UID=.*/NAPCAT_UID=$(id -u)/" .env
sed -i "s/^NAPCAT_GID=.*/NAPCAT_GID=$(id -g)/" .env
```

然后先启动基础容器：

```bash
docker compose config
docker compose up -d
docker compose ps
```

此时只会运行 GsCore 与 NapCat。NapCat GScore 适配器需要再执行本目录的 init profile，或在 NapCat WebUI 中手动安装。

## 默认端口

默认只绑定到服务器本机 `127.0.0.1`：

```text
GsCore:  http://127.0.0.1:8765/app/
NapCat:  http://127.0.0.1:6099
```

远程服务器建议用 SSH 隧道访问：

```bash
ssh -N \
  -L 8765:127.0.0.1:8765 \
  -L 6099:127.0.0.1:6099 \
  root@你的服务器IP
```

保持这个窗口不要关闭，然后在本地浏览器打开上面的两个地址。

如果你确实要公网直接访问 WebUI，可以把 `.env` 里的 `BIND_IP=127.0.0.1` 改成：

```env
BIND_IP=0.0.0.0
```

同时请务必在安全组/防火墙中只放行必要来源，并第一时间修改 GsCore 和 NapCat WebUI 的密码、Token。

## 登录 NapCat

打开：

```text
http://127.0.0.1:6099
```

如果不知道 WebUI token，可以查看日志：

```bash
docker logs --tail=200 ng-napcat
```

日志里通常会出现类似：

```text
http://127.0.0.1:6099/webui?token=xxxxx
```

登录 NapCat WebUI 后，先修改默认密码 / token，再扫码登录 QQ。

NG 版不使用 AstrBot，也不需要配置 `ws://astrbot:6199/ws` 这类 OneBot 反向 WebSocket。这里真正需要启用的是 NapCat 的插件能力：安装并启用 `napcat-plugin-gscore-adapter`，再让插件直接连接 GsCore。

## 安装 NapCat GsCore 适配器

`napcat-plugin-gscore-adapter` 官方 README 建议把插件放到 NapCat 的 `plugins` 目录，并在 NapCat WebUI 插件管理中启用。本 compose 已经持久化：

```text
/app/napcat/plugins -> /opt/ng-data/napcat/plugins
/app/napcat/config  -> /opt/ng-data/napcat/config
```

使用 `bash install.sh --mode napcat` 时，这一步由安装器自动完成。

直接使用本目录 Compose 时，推荐运行固定版本的初始化任务：

```bash
docker compose --profile init run --rm napcat-gscore-adapter-init
docker restart ng-napcat
```

初始化任务会下载 `.env` 中固定的 release zip，校验 SHA-256，在插件卷内原子替换旧目录，并写入连接地址、`WS_TOKEN` 和主人 QQ。

如果你不想使用初始化任务，也可以在 NapCat WebUI 手动安装：

```text
NapCat WebUI -> 插件管理 -> 上传/安装/启用 napcat-plugin-gscore-adapter
```

也可以从插件 release 下载 zip 后解压到宿主机：

```bash
mkdir -p /opt/ng-data/napcat/plugins/napcat-plugin-gscore-adapter
unzip /path/to/napcat-plugin-gscore-adapter.zip \
  -d /opt/ng-data/napcat/plugins/napcat-plugin-gscore-adapter
docker restart ng-napcat
```

如果你要改用其他 release，请同时写入 `.env`：

```env
NAPCAT_GSCORE_ADAPTER_ZIP_URL=https://github.com/xiowo/napcat-plugin-gscore-adapter/releases/download/<tag>/<asset>.zip
NAPCAT_GSCORE_ADAPTER_SHA256=<对应 release zip 的 64 位 SHA-256>
```

仓库当前默认固定 v1.3.3 及其 GitHub 发布资产摘要。升级到其他 release 时必须同时修改下载地址和摘要。

## 配置插件连接 GsCore

通过仓库根目录的 `install.sh` 安装时，下列四项会自动写入，无需再到 WebUI 手动设置。直接使用 Compose 初始化任务时，请先在 `.env` 中设置 `GSCORE_WS_TOKEN` 和 `NAPCAT_MASTER_QQ`，并确保 GsCore 配置使用相同的 `WS_TOKEN`；也可以在安装后按下列说明手动配置。

在 NapCat WebUI 的插件配置页面中，配置 `napcat-plugin-gscore-adapter`：

```text
启用 GScore 适配器：开启
连接地址：ws://gscore:8765
连接 Token：填写 GsCore 里的同一个 WS_TOKEN；如果 GsCore 没设置就留空
命令前缀：按需设置，例如 #早柚 或 core
主人QQ：你的 QQ 号，多个用英文逗号分隔
```

注意：Docker 环境里不要填 `localhost` 或 `127.0.0.1`。在 NapCat 容器内，`localhost` 指 NapCat 自己；同一 compose 网络内应使用服务名：

```text
ws://gscore:8765
```

## NapCat 登录态持久化

本 compose 已经持久化 NapCat 的关键目录：

```text
/opt/ng-data/napcat/qq     -> /app/.config/QQ
/opt/ng-data/napcat/config -> /app/napcat/config
/opt/ng-data/napcat/plugins -> /app/napcat/plugins
```

如果容器重启、重建后 QQ 需要重新扫码，先检查挂载和权限：

```bash
docker inspect -f '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}' ng-napcat
ls -la /opt/ng-data/napcat/qq
ls -la /opt/ng-data/napcat/config
```

如果挂载和权限都正常，但仍频繁丢登录，可以启用唯一固定 MAC：

```bash
sh ../scripts/ensure-napcat-mac.sh
docker compose up -d
```

这个脚本需要在 `docker compose up -d` 之前执行，因为 Docker 创建容器网络接口时就要读取 `mac_address`。脚本只会在 `.env` 没有 `NAPCAT_MAC` 时生成一次；后续再次运行会复用已有值，不会覆盖。它还会把 `docker-compose.mac.example.yml` 复制成 `docker-compose.override.yml`。

`docker-compose.mac.example.yml` 会强制要求你在 `.env` 里设置 `NAPCAT_MAC`，避免所有部署误用同一个公共 MAC。多实例部署时，每个实例必须使用不同 MAC。

## 配置 GsCore

打开：

```text
http://127.0.0.1:8765/app/
```

首次进入通常需要注册，注册码可在宿主机查看：

```bash
grep -n "REGISTER_CODE" /opt/ng-data/gscore/data/config.json
```

建议优先配置：

```text
管理员 / masters：你的 QQ 号
WS_TOKEN：生成一个随机强 token，并同步填入 NapCat 插件
命令前缀：和 NapCat 插件转发前缀保持一致
```

生成 token 示例：

```bash
openssl rand -hex 24
```

## 可选 GsCore 插件

如果需要鸣潮相关能力，可以安装常用 GsCore 插件：

```bash
docker compose --profile init run --rm gscore-plugin-init
docker restart ng-gscore
```

默认会安装：

```text
XutheringWavesUID
RoverSign
ScoreEcho
```

GitHub 较慢时，可在 `.env` 中切到 CNB 镜像：

```env
XUTHERINGWAVESUID_REPO=https://cnb.cool/gscore-mirror/XutheringWavesUID
ROVERSIGN_REPO=https://cnb.cool/gscore-mirror/RoverSign
SCOREECHO_REPO=https://cnb.cool/gscore-mirror/ScoreEcho
```

### XutheringWavesUID 额外依赖

XutheringWavesUID 的部分功能需要额外依赖。由于插件仓库没有把这些写进 `pyproject.toml` / `requirements.txt` 的依赖清单里，GsCore 安装插件时不会自动安装。

建议额外安装：

```text
playwright：HTML 渲染调用
Playwright Chromium：HTML 渲染所需浏览器二进制
opencv-python：面板图重复判断、提取面板图、相似度识别等
fonttools：多语言字体 fallback
pypinyin：部分中文拼音/别名处理能力
```

缺少 Playwright 浏览器时，会看到类似错误：

```text
BrowserType.launch: Executable doesn't exist at /ms-playwright/...
Looks like Playwright was just installed or updated.
Please run the following command to download new browsers:
    playwright install
```

本 compose 已经把 `/ms-playwright` 挂到 `gscore-playwright` volume。首次使用 XutheringWavesUID 渲染功能前，建议执行一次：

```bash
docker compose up -d --force-recreate gscore
docker compose --profile init run --rm gscore-xwuid-deps-init
docker compose up -d --force-recreate gscore
```

这会运行：

```bash
uv pip install --python /venv/bin/python playwright opencv-python fonttools pypinyin
uv run --python /venv/bin/python playwright install chromium
```

Python 包会安装到 `gscore-venv` volume，浏览器文件会保存在 `gscore-playwright` volume 中。执行 `docker compose down -v` 会删除这些 volume，之后需要重新运行上面的初始化命令。

如果你是从旧版 compose 更新而来，务必使用上面的 `--force-recreate` 重建 `gscore` 服务。`docker restart ng-gscore` 只会重启旧容器，不会应用后来新增的 `/ms-playwright` volume 和 `PLAYWRIGHT_BROWSERS_PATH` 环境变量，容易出现依赖初始化成功但 GsCore 仍找不到浏览器的情况。

插件安装后，建议在联通后执行：

```text
ww下载全部资源
```

`RoverSign` 依赖 `XutheringWavesUID` 及其数据库，请先确认 `XutheringWavesUID` 正常。

## 联调

重启：

```bash
docker restart ng-gscore ng-napcat
```

看日志：

```bash
docker logs -f ng-gscore
docker logs -f ng-napcat
```

测试：

```text
#早柚status
#早柚群开启
core帮助
ww帮助
```

具体触发词取决于你在 NapCat 插件和 GsCore 中配置的前缀。

## 常见问题

### NapCat 插件显示 Connection Refused

检查：

```text
连接地址是否为 ws://gscore:8765
GsCore 容器是否 Up
GsCore 是否设置了 WS_TOKEN，且插件 token 是否一致
```

服务器内测试：

```bash
docker compose ps
curl -I http://127.0.0.1:8765/app/
```

### 发消息没有反应

检查：

```text
NapCat 插件是否启用
群是否执行过 #早柚群开启
命令前缀是否一致
主人QQ/群主/管理员权限是否满足
GsCore 管理员 / masters 是否包含你的 QQ
```

## 参考

- [Sayu 适配 Bot 列表](https://docs.sayu-bot.com/LinkBots/AdapterList.html)
- [napcat-plugin-gscore-adapter](https://github.com/xiowo/napcat-plugin-gscore-adapter)
- [GsCore Docker 文档](https://docs.sayu-bot.com/Started/DockerCore)
- [NapCat-Docker](https://github.com/NapNeko/NapCat-Docker)
