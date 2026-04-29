# NAG

NapCat + AstrBot + GsCore 的 Docker Compose 部署模板。

本仓库面向个人 QQ 路线：

```text
GsCore <-> AstrBot <-> NapCatQQ <-> QQ
```

如果你使用 QQ 官方机器人，或强依赖 NoneBot2 插件生态，请参考完整教程里的 NoneBot2 路线；本 compose 不包含 NoneBot2。

## 路线选择

本仓库现在提供两套 compose：

```text
NAG: GsCore <-> AstrBot <-> NapCatQQ
NG:  GsCore <-> NapCat 插件 <-> NapCatQQ
```

- 默认使用本页的 NAG 版本：适合需要 AstrBot 的 LLM、WebUI 管理、多平台能力，或希望通过 AstrBot 统一接入 GsCore 的用户。
- 可选使用 [NG 轻量版本](NG/README.md)：适合不需要 AstrBot，只想让 NapCat 通过协议端插件直接连接 GsCore 的用户。

NG 版本文件：

- [NG/docker-compose.yml](NG/docker-compose.yml)
- [NG/README.md](NG/README.md)

## 组件

- **GsCore / GenshinUID Core**：游戏数据查询、面板渲染、签到、插件管理等核心能力。
- **AstrBot**：机器人中控与 WebUI，负责接入 NapCat，并通过插件转发 GsCore 指令。
- **NapCatQQ**：QQ 协议端，负责登录 QQ 并提供 OneBot V11 通信。

## 部署前准备

推荐使用 Linux 服务器。下文以 Ubuntu / Debian 系为例。

如果你已经是 `root`，命令前不需要 `sudo`。如果系统提示：

```text
sudo: command not found
Unable to locate package docker-compose-plugin
```

这通常说明你正在使用最小化系统，或还没有配置 Docker 官方 apt 源。`docker-compose-plugin` 不一定存在于系统默认 apt 源里。

最省事的安装方式是使用 Docker 官方安装脚本：

```bash
apt update
apt install -y git curl ca-certificates

curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh

systemctl enable --now docker || service docker start
docker --version
docker compose version
```

如果你不想使用安装脚本，也可以按 Docker 官方文档配置 Docker apt 源后再安装：

```bash
apt update
apt install -y git curl ca-certificates
install -m 0755 -d /etc/apt/keyrings

. /etc/os-release
case "$ID" in
  ubuntu) DOCKER_REPO="https://download.docker.com/linux/ubuntu" ;;
  debian) DOCKER_REPO="https://download.docker.com/linux/debian" ;;
  *) echo "Unsupported distro: $ID"; exit 1 ;;
esac

curl -fsSL "$DOCKER_REPO/gpg" -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: $DOCKER_REPO
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker || service docker start

docker --version
docker compose version
```

如果你不是 root 用户部署，并且希望免 `sudo` 使用 Docker：

```bash
sudo usermod -aG docker "$USER"
newgrp docker
```

## 目录规划

仓库目录只放 compose、README 和模板文件；运行数据放到仓库外，默认是：

```text
/opt/nag-data
```

这样可以避免 `git pull`、`git status`、`git clean` 影响机器人数据、QQ 登录态和配置文件。

## 快速开始

```bash
git clone https://github.com/gufei233/NAG.git
cd NAG

cp .env.example .env
mkdir -p /opt/nag-data/{astrbot,napcat/config,napcat/qq,gscore/data,gscore/plugins}

docker compose config
docker compose up -d
docker compose ps
```

如果你不是 root 用户部署，建议把 `DATA_ROOT` 交给当前用户：

```bash
sudo chown -R "$(id -u):$(id -g)" /opt/nag-data
sed -i "s/^NAPCAT_UID=.*/NAPCAT_UID=$(id -u)/" .env
sed -i "s/^NAPCAT_GID=.*/NAPCAT_GID=$(id -g)/" .env
```

## 默认端口

默认只绑定到服务器本机 `127.0.0.1`，更适合配合 SSH 隧道或反向代理使用。

```text
GsCore:  http://127.0.0.1:8765/app/
AstrBot: http://127.0.0.1:6185
NapCat:  http://127.0.0.1:6099
```

从本地电脑访问远程服务器时，可以开一个 SSH 隧道窗口：

```bash
ssh -N \
  -L 8765:127.0.0.1:8765 \
  -L 6185:127.0.0.1:6185 \
  -L 6099:127.0.0.1:6099 \
  root@你的服务器IP
```

保持这个窗口不要关闭，然后在本地浏览器打开上面的三个地址。

如果你确实要公网直接访问 WebUI，可以把 `.env` 里的 `BIND_IP=127.0.0.1` 改成：

```env
BIND_IP=0.0.0.0
```

同时请务必在安全组/防火墙中只放行必要来源，并第一时间修改 WebUI 密码和 Token。

## 可选插件初始化

插件不是必装项。你可以在 WebUI 里手动安装，也可以用 compose 的 `init` profile 一次性拉取常用插件。

```bash
docker compose --profile init run --rm gscore-plugin-init
docker compose --profile init run --rm astrbot-plugin-init
docker restart nag-gscore nag-astrbot
```

默认会安装：

```text
GsCore:
- XutheringWavesUID
- RoverSign
- ScoreEcho

AstrBot:
- astrbot_plugin_gscore_adapter
```

如果 GitHub 访问较慢，可以先在 `.env` 中把 GsCore 插件仓库切到 CNB 镜像：

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
docker compose up -d gscore
docker compose --profile init run --rm gscore-xwuid-deps-init
docker restart nag-gscore
```

这会运行：

```bash
uv pip install --python /venv/bin/python playwright opencv-python fonttools pypinyin
uv run --python /venv/bin/python playwright install chromium
```

Python 包会安装到 `gscore-venv` volume，浏览器文件会保存在 `gscore-playwright` volume 中。执行 `docker compose down -v` 会删除这些 volume，之后需要重新运行上面的初始化命令。

插件安装后，建议在 GsCore / AstrBot 重启完成并联通后再做插件初始化：

```text
ww下载全部资源
```

`RoverSign` 依赖 `XutheringWavesUID` 及其数据库，建议先确认 `XutheringWavesUID` 正常工作。总排行 token、评分 OCR token 等插件业务配置，进入 GsCore WebUI 的对应插件配置页填写。

## 首次配置顺序

建议按这个顺序配置：GsCore -> AstrBot -> NapCat -> 联调。

### 1. 配置 GsCore

打开：

```text
http://127.0.0.1:8765/app/
```

如果页面路径有变化，以启动日志为准。首次进入通常需要注册，注册码可在宿主机查看：

```bash
grep -n "REGISTER_CODE" /opt/nag-data/gscore/data/config.json
```

建议优先配置：

```text
管理员 / masters：你的 QQ 号
WS_TOKEN：生成一个随机强 token
命令前缀：core, gs, sr, zzz, ww
```

生成 token 示例：

```bash
openssl rand -hex 24
```

`WS_TOKEN` 设置后，AstrBot 的 GsCore 适配器里必须填写同一个 token。Docker 同机跨容器时，不建议只依赖 `TRUSTED_IPS`。

GsCore 配置文件主要位于：

```text
/opt/nag-data/gscore/data/config.json
/opt/nag-data/gscore/data/configs/
```

通常不需要手动改 `HOST`。如果 WebUI 访问异常，先检查容器状态、日志和 SSH 隧道；只有确认是 GsCore 自身监听地址导致的问题时，再通过 WebUI 或配置文件调整。

### 2. 配置 AstrBot

打开：

```text
http://127.0.0.1:6185
```

首次登录后请修改默认密码。然后配置 NapCat / OneBot V11 平台：

```text
消息平台类别：aiocqhttp / OneBot V11
启用：开启
反向 WebSocket 主机：0.0.0.0
反向 WebSocket 端口：6199
反向 WebSocket Token：留空，除非你在 NapCat 侧也设置了同一个 Token
```

`6199` 不需要映射到宿主机，因为 NapCat 和 AstrBot 在同一个 Docker 网络里通信。

如果已安装 `astrbot_plugin_gscore_adapter`，在插件配置里填写：

```text
链接至 GsCore 的 IP 地址：gscore
链接至 GsCore 的端口：8765
向 GsCore 注册自身的 Bot：AstrBot
连接 Core 的 WsToken：填写 GsCore 里的同一个 WS_TOKEN
仅转发到 GsCore 的触发前缀：core, gs, sr, zzz, ww
```

注意：这里不要填 `localhost`。在 Docker 容器中，`localhost` 指 AstrBot 容器自己，不是 GsCore 容器；同一 compose 网络内应使用服务名 `gscore`。

### 3. 登录 NapCat

打开：

```text
http://127.0.0.1:6099
```

如果不知道 WebUI token，可以查看日志：

```bash
docker logs --tail=200 nag-napcat
```

日志里通常会出现类似：

```text
http://127.0.0.1:6099/webui?token=xxxxx
```

登录 NapCat 后扫码登录 QQ。当前 compose 使用：

```yaml
MODE: astrbot
```

这个模式会按 NapCat-Docker 的 AstrBot 预设自动连接：

```text
ws://astrbot:6199/ws
```

如果自动配置没有生效，可在 NapCat 网络配置中手动新建 WebSocket 客户端 / 反向 WebSocket：

```text
URL：ws://astrbot:6199/ws
消息格式：Array
Token：留空，除非 AstrBot 侧也设置了同一个 Token
```

### 4. 联调

按顺序重启一次：

```bash
docker restart nag-gscore nag-astrbot nag-napcat
```

观察日志：

```bash
docker logs -f nag-gscore
docker logs -f nag-astrbot
docker logs -f nag-napcat
```

向机器人私聊测试：

```text
core帮助
core状态
ww帮助
```

如果 `core帮助` 进入 GsCore 日志但没有被识别成命令，优先检查：

```text
GsCore 管理员 / masters
GsCore 命令前缀
AstrBot GsCore 适配器的拦截前缀
WS_TOKEN 是否一致
```

## 镜像与镜像源

`GSCORE_IMAGE` 默认跟随当前 GsCore Docker 文档：

```env
GSCORE_IMAGE=docker.cnb.cool/gscore-mirror/gsuid_core:latest
```

AstrBot 和 NapCat 默认使用上游镜像：

```env
ASTRBOT_IMAGE=soulter/astrbot:latest
NAPCAT_IMAGE=mlikiowa/napcat-docker:latest
```

国内拉取 AstrBot 镜像较慢时，可以在 `.env` 中改用镜像：

```env
ASTRBOT_IMAGE=m.daocloud.io/docker.io/soulter/astrbot:latest
```

GsCore 插件仓库默认使用 GitHub；如果 GitHub 较慢，可改用 `https://cnb.cool/gscore-mirror` 下的插件镜像。`.env.example` 已给出常用插件变量。

## NapCat MAC

本 compose 默认不设置 `mac_address`。

NapCat-Docker 官方模板会持久化 `/app/.config/QQ` 和 `/app/napcat/config`；这两个目录已经在本 compose 中挂载。如果容器重启、重建后 QQ 登录态仍然丢失，优先检查：

```bash
docker inspect -f '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}' nag-napcat
ls -la /opt/nag-data/napcat/qq
ls -la /opt/nag-data/napcat/config
```

如果目录为空、权限不对，或你不是 root 用户部署，请先修正 `NAPCAT_UID` / `NAPCAT_GID` 和 `/opt/nag-data` 权限。

固定 MAC 可能降低某些单人私有部署里的重复登录摩擦，特别是容器被重新创建时；但不适合作为公开模板默认值，因为所有用户都会从同一个 MAC 开始。

如果你确实需要固定 MAC，请生成一个只属于你自己的值：

```bash
sh scripts/ensure-napcat-mac.sh
docker compose up -d
```

这个脚本需要在 `docker compose up -d` 之前执行，因为 Docker 创建容器网络接口时就要读取 `mac_address`。脚本只会在 `.env` 没有 `NAPCAT_MAC` 时生成一次；后续再次运行会复用已有值，不会覆盖。它还会把 `docker-compose.mac.example.yml` 复制成 `docker-compose.override.yml`。

`docker-compose.mac.example.yml` 会强制要求你在 `.env` 里设置 `NAPCAT_MAC`，避免误用公共示例值。最终等价于在私有 override 里添加：

```yaml
services:
  napcat:
    mac_address: "${NAPCAT_MAC}"
```

多实例部署时，每个实例必须使用不同 MAC。

## 常用运维命令

查看状态：

```bash
docker compose ps
```

查看日志：

```bash
docker logs -f nag-gscore
docker logs -f nag-astrbot
docker logs -f nag-napcat
```

重启：

```bash
docker restart nag-gscore nag-astrbot nag-napcat
```

更新镜像：

```bash
docker compose pull
docker compose up -d
```

更新可选插件：

```bash
docker compose --profile init run --rm gscore-plugin-init
docker compose --profile init run --rm astrbot-plugin-init
docker restart nag-gscore nag-astrbot
```

备份运行数据：

```bash
tar -czf nag-data-backup.tar.gz -C /opt nag-data
```

停止服务：

```bash
docker compose down
```

停止服务并删除匿名/命名 volume 前请确认备份，`gscore-venv` 会被删除：

```bash
docker compose down -v
```

## 常见问题

### WebUI 打不开

先在服务器上测试：

```bash
curl -I http://127.0.0.1:8765/app/
curl -I http://127.0.0.1:6185
curl -I http://127.0.0.1:6099
```

服务器上能访问、本地不能访问时，多半是 SSH 隧道断开或端口没转发。

### NapCat 重启后 QQ 需要重新登录

先确认你不是只把配置存在容器内部：

```bash
docker inspect -f '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}' nag-napcat
ls -la /opt/nag-data/napcat/qq
ls -la /opt/nag-data/napcat/config
```

本 compose 应该至少挂载：

```text
/opt/nag-data/napcat/qq     -> /app/.config/QQ
/opt/nag-data/napcat/config -> /app/napcat/config
```

如果挂载和权限都正常，但容器重建后仍频繁丢登录，可以按上面的 **NapCat MAC** 小节启用唯一固定 MAC。

### NapCat 日志里出现 ECONNREFUSED astrbot:6199

说明 NapCat 能解析到 AstrBot 容器，但 AstrBot 还没有监听 6199。检查 AstrBot 的 aiocqhttp / OneBot V11 平台是否启用，端口是否为 `6199`，保存后重启：

```bash
docker restart nag-astrbot nag-napcat
```

### AstrBot 连接不上 GsCore

检查 GsCore 适配器里的地址是否为：

```text
IP：gscore
PORT：8765
```

不要填 `localhost`。

### GsCore 收到消息但命令不触发

优先检查：

```text
管理员 / masters 是否包含你的 QQ
命令前缀是否包含 core / ww
AstrBot 适配器拦截前缀是否一致
WS_TOKEN 是否一致
```

### 插件 clone 很慢或失败

可以在 `.env` 中启用代理，或把 GsCore 插件仓库切到 CNB 镜像。

```env
GSCORE_HTTP_PROXY=http://host.docker.internal:7890
GSCORE_HTTPS_PROXY=http://host.docker.internal:7890
```

## 参考

- [GsCore 文档](https://docs.sayu-bot.com/)
- [GsCore Docker 镜像](https://cnb.cool/gscore-mirror/gscore-docker)
- [AstrBot 文档](https://astrbot.app/)
- [NapCat 文档](https://napneko.github.io/)
- [NapCat-Docker](https://github.com/NapNeko/NapCat-Docker)
- [astrbot_plugin_gscore_adapter](https://github.com/KimigaiiWuyi/astrbot_plugin_gscore_adapter)
- [XutheringWavesUID](https://github.com/Loping151/XutheringWavesUID)
- [RoverSign](https://github.com/Loping151/RoverSign)
- [ScoreEcho](https://github.com/Loping151/ScoreEcho)
