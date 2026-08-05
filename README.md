# NAG

个人 QQ / QQ 官方机器人 + AstrBot / NoneBot / GsCore 的 Docker Compose 部署模板。

## 快速导航

- [部署选择](#部署选择)：先确定个人 QQ、QQ 官方机器人或双通道方案
- [安装 Docker](#安装-docker)：准备 Ubuntu / Debian 服务器环境
- [交互式一键脚本](#方式一交互式一键脚本推荐)：推荐的新装、增量调整和修复方式
- [传统手动 Docker Compose 部署](#方式二传统手动-docker-compose-部署)：七条固定路线
- [首次配置顺序](#首次配置顺序)：登录 WebUI 并完成联调
- [常用运维命令](#常用运维命令)：更新、备份和停止
- [常见问题](#常见问题)：WebUI、密码和连接故障

## 部署选择

一键脚本将部署归纳为三套大方案，并使用终端流程图标出固定项、可自定义项和可选组件：

| 大方案 | 固定入口 | GScore 处理方（单选） | 可选组件 | 适合场景 |
| --- | --- | --- | --- | --- |
| 个人 QQ | NapCatQQ | NapCat、NoneBot 或 AstrBot | AstrBot、NoneBot、BotShepherd | 功能最完整，适合个人 QQ |
| QQ 官方机器人 | QQ Gateway，不安装 NapCat | gscore-qqofficial 或 NoneBot | — | 使用 QQ 开放平台机器人 |
| 双通道 | 同时启用以上两个入口 | 两条链路分别选择 | 继承个人 QQ 可选组件 | 同时服务个人 QQ 和官方机器人 |

```text
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
```

个人 QQ 的 GScore 处理方只能选择一个：

- **NapCat GScore 插件（推荐）**：可再选择是否安装 AstrBot、NoneBot，二者也可以同时安装。此时 AstrBot/NoneBot 只处理各自的普通插件消息。
- **NoneBot GenshinUID**：NoneBot 必装，可再加装 AstrBot。
- **AstrBot GScore 适配器**：AstrBot 必装，可再加装 NoneBot。该适配器完成度相对较低，建议仅在确有需要时选择。

QQ 官方机器人的 GScore 处理方也只能选择一个：

- **gscore-qqofficial 轻量直连（推荐）**：组件最少，只需要 AppID 和 AppSecret。
- **NoneBot + nonebot-adapter-qq**：适合还需要 NoneBot 插件生态的用户，需要 AppID、Token 和 AppSecret。

当个人 QQ 安装 AstrBot 或 NoneBot 时，还可选择加入 **BotShepherd**。启用后，OneBot 链路会变为 `NapCatQQ <-> BotShepherd <-> AstrBot/NoneBot`；AstrBot 与 NoneBot 同时安装时，BotShepherd 会把消息转发给两者。它用于统一连接管理、黑名单、指令过滤、别名和消息统计，不会代替下游框架或 GsCore。

只要个人 QQ 选择 NapCat GScore 插件，脚本就会固定使用 `mlikiowa/napcat-docker:v4.18.5`，避免 NapCat v4.18.6 起的官方插件白名单影响第三方插件。其他个人 QQ 组合可使用当前 NapCat 镜像。

QQ 官方机器人的管理员标识是 OpenID，不是数字 QQ 号。脚本不会从日志自动收集或填入 OpenID；首次可留空，取得自己的 OpenID 后再手动填写。两种官方接入启动前都要把服务器公网 IP 加入 QQ 开放平台的机器人 IP 白名单，否则脚本会报告 `11298`。

> [!IMPORTANT]
> 个人 QQ 使用 NapCat GScore 插件时，NapCat 会自动固定为 `v4.18.5`。AstrBot GScore 适配器完成度相对较低；没有明确需求时，优先选择 NapCat 或 NoneBot 处理 GScore。

原来的七条固定路线仍作为 `--mode` 预设和手动 Compose 示例保留，便于自动化部署和已有用户继续使用。

## 组件

- **GsCore / GenshinUID Core**：游戏数据查询、面板渲染、签到、插件管理等核心能力。
- **AstrBot**：机器人中控与 WebUI，负责接入 NapCat，并通过插件转发 GsCore 指令。
- **NoneBot2**：可选机器人框架，通过 OneBot V11 接入 NapCat，并按路线选择是否加载 GenshinUID。
- **NapCatQQ**：QQ 协议端，负责登录 QQ 并提供 OneBot V11 通信。
- **BotShepherd（可选）**：位于 NapCat 与 AstrBot/NoneBot 之间的 OneBot V11 代理和管理层。
- **nonebot-adapter-qq / gscore-qqofficial**：两种不依赖 NapCat 的 QQ 官方机器人接入方式。

## 安装 Docker

推荐使用 Linux 服务器。下文以 Ubuntu / Debian 系为例。

> 使用方式一的一键脚本时可跳过本节：脚本进入问答前会自动检测 Docker / Compose V2，缺失时询问并调用 Docker 官方安装脚本自动安装（支持主流发行版；判定为中国大陆网络时自动改用阿里云安装源），守护进程未运行会尝试自动启动。

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

## 两种使用方式

所有组合都可以通过交互式一键脚本安装。原来的七条固定路线仍可通过 `--mode` 或 Docker Compose 手动部署；一键脚本适合首次使用，手动部署适合希望自行维护 `.env`、Compose 参数和初始化顺序的用户。

### 方式一：交互式一键脚本（推荐）

首次安装：

```bash
git clone https://github.com/gufei233/NAG.git
cd NAG
bash install.sh
```

直接运行脚本会先显示“安装与维护”主菜单。选择“安装、更新或调整机器人部署”后，脚本显示三套大方案的流程图，再选择唯一的 GScore 处理方和可选框架；也可以从主菜单直接进入 NoneBot 的 Mimo Console、状态查看、BotShepherd 端口管理或卸载。AstrBot 与 NoneBot 可以同时安装，两种 QQ 接入也会自动共用一套 GsCore。脚本会自动：

- 创建持久化目录并生成私有配置；
- 配置 GsCore 主人、框架管理员和共享 `WS_TOKEN`；
- 创建 NapCat、AstrBot、NoneBot、BotShepherd 之间的连接；
- 对每个 NoneBot 实例调用官方 `nb adapter install`、`nb plugin install`、`nb docker generate`、`nb docker build` 和 `nb docker up` 流程；个人 QQ 使用 `nonebot-adapter-onebot`，QQ 官方机器人使用 `nonebot-adapter-qq`；
- 在官方 NoneBot 项目中内置 Mimo Console，并注册受限的宿主机 Agent，使 WebUI 可以安装、更新、卸载插件以及重建、健康检查和回滚对应实例；
- 复用 NapCat MAC 与快速登录账号，降低容器重建后重新登录的概率；
- 按需克隆鸣潮插件套件，安装 Playwright、OpenCV、字体、拼音和 Chromium 等依赖。

问答开始前，脚本还会完成一轮环境自检：

- 检测 Docker / Compose V2 / 守护进程：未安装可自动安装（官方 get.docker.com 脚本，覆盖主流发行版），守护进程未运行会尝试启动；内存偏小或磁盘剩余不足时提前预警；
- 自动判断中国大陆网络环境（也可用 `--cn` / `--no-cn` 强制指定，结果记录在 `.installer/preflight.env`）：大陆模式下 Docker 用阿里云安装源，可选写入 `/etc/docker/daemon.json` 配置 Docker Hub 镜像加速，鸣潮插件默认改用 CNB 镜像，GsCore 的 pip 源改用清华镜像；
- 端口提问时会探测宿主机占用（与上次配置相同的端口视为本部署自身，不会误报），避免部署到一半才发现冲突；
- QQ 官方 AppSecret / Token 改为隐藏输入，重跑脚本时也不再把已保存的旧值明文显示在提示符里。

> 注意：镜像加速默认地址为第三方公共服务（`dockerproxy.net`、`docker.m.daocloud.io`），可用性随时间变化，也可在提问时换成自己的加速地址（如阿里云个人加速）。写入前会备份已有 `daemon.json`，重启 Docker 生效时现有容器会闪断数秒后自动恢复。

更新仓库或调整现有部署：

```bash
cd NAG
git pull --ff-only
bash install.sh
```

再次进入“安装、更新或调整机器人部署”时，脚本读取 `.installer/guided.state` 并提供三种操作：

1. **在当前大方案内自定义组件**：增删 AstrBot、NoneBot、BotShepherd，或切换 GScore 处理方；
2. **修复或更新当前方案**：重新校验镜像、配置和连接；
3. **更换大方案**：在个人 QQ、QQ 官方机器人和双通道之间切换。

执行前会列出新增、停止、切换、重建、重启和保持不变的项目。未列出的组件不会重建；退出当前拓扑的容器只会停止，持久化数据、私有凭据和 NapCat 身份默认保留。切换离开 AstrBot GScore 适配器时，脚本会把插件目录移到 `plugins-disabled` 保存，避免它与新的 GScore 处理方重复回复。

#### 安装状态和凭据

| 内容 | 获取方式 | 说明 |
| --- | --- | --- |
| GsCore `REGISTER_CODE` | 安装结束时打印；也可查看 `gscore/data/config.json` | 用于 GsCore WebUI 首次注册 |
| NapCat WebUI Token | 脚本循环读取启动日志 | 扫码登录后 Token 可能刷新，以最新日志为准 |
| AstrBot 初始密码 | 新安装时等待启动日志，最长 120 秒 | 明文只存在于当前容器首次启动日志 |
| BotShepherd 初始密码 | 脚本循环读取启动日志 | 复用已有数据时继续使用之前设置的密码 |
| Mimo Console 初始化令牌 | 安装 NoneBot 后自动从本次启动日志读取并打印 | 仅在管理员尚未创建时生成，并且只在本次启动有效 |
| QQ 官方机器人凭据 | 用户输入后写入私有环境文件 | 不写入 README、示例文件或安装摘要 |

AstrBot 的 `cmd_config.json` 只保存 MD5/PBKDF2 密码哈希，不能从配置文件恢复明文。若复用旧数据且当前容器日志中已没有初始密码，请使用之前设置的密码或按 AstrBot 官方方式重置，而不是删除整个数据目录。

脚本使用以下状态文件：

| 文件 | 用途 |
| --- | --- |
| `.installer/guided.state` | 当前大方案、处理方和可选组件，不含凭据 |
| `.installer/guided.env` | Compose 私有参数和凭据，权限为 `600` |
| `.installer/napcat-identity.env` | NapCat QQ 账号和固定 MAC，权限为 `600` |

这些文件均被 Git 忽略。脚本只有在 Compose 校验、部署和状态检查全部成功后才替换正式状态文件；中途失败会保留上一次可用配置。

BotShepherd 安装完成后，可运行下面的命令快捷查看、新增、删除或重新应用宿主机端口映射。该操作只重建 `nag-botshepherd`，不会重建其他服务。

```bash
bash install.sh --mode botshepherd-ports
```

随时查看各部署的容器状态、数据目录与 WebUI 地址：

```bash
bash install.sh --mode status
```

卸载部署（交互模式会列出已发现的部署供选择；数据目录默认保留，删除需要输入 `yes` 二次确认）：

```bash
bash install.sh --mode uninstall
# 无人值守示例：
bash install.sh --mode uninstall --target all --yes                      # 仅移除容器，保留数据与状态
bash install.sh --mode uninstall --target nag --yes --purge-data --purge-state
```

`--target` 可选 `nag`（个人 QQ 的 guided/预设部署）、`ng`（NG 轻量部署）、`nag-qqofficial`（QQ 官方部署）或 `all`。卸载不会删除 Docker 镜像；`.installer/napcat-identity.env` 也默认保留——它保存固定 MAC，删除后重装会生成新 MAC，可能触发 QQ 设备风控，确要删除请在交互模式确认。安装器会在仅含 NAG 数据的专用根目录写入 `.nag-managed-data-root` 安全标记；`--purge-data` 只会删除经过规范化、避开系统关键目录、带有效标记且删除时仍仅含 NAG 顶层条目的路径。如果根目录已有其他顶层文件，安装可继续但不会获得删除标记；写入标记后再加入其他条目，卸载也会拒绝递归删除。旧版本部署缺少标记时，先重跑一次安装器再卸载，或自行核对后手动清理。

固定路线预设仍支持无人值守安装或仅查看执行计划：

```bash
bash install.sh --mode astrbot --yes --master-qq 123456789
bash install.sh --mode hybrid --yes --master-qq 123456789 --dry-run
bash install.sh --mode hybrid --botshepherd --yes --master-qq 123456789 --dry-run
bash install.sh --mode napcat --yes --master-qq 123456789 --dry-run
bash install.sh --mode nonebot --yes --master-qq 123456789 --bot-qq 987654321 --dry-run
bash install.sh --mode nonebot-napcat --botshepherd --yes --master-qq 123456789 --bot-qq 987654321 --dry-run
QQ_APP_ID=xxx QQ_APP_SECRET=xxx QQ_TOKEN=xxx bash install.sh --mode qqofficial-nonebot --yes --dry-run
QQ_APP_ID=xxx QQ_APP_SECRET=xxx bash install.sh --mode qqofficial-direct --yes --dry-run
```

### 方式二：传统手动 Docker Compose 部署

先克隆仓库并选择路线。手动部署前请编辑对应的 `.env`：路线 4/5/6/7 的 Compose 文件要求 `GSCORE_WS_TOKEN` 非空，否则 `config`、`build`、`up` 都会直接中止；需要适配器自动初始化时，还应填写 `NAPCAT_MASTER_QQ`，并确保 GsCore 使用相同的 WebSocket Token。

| 路线 | 组合 | GScore 处理方 | NapCat 版本 |
| --- | --- | --- | --- |
| 1 | NapCat + AstrBot + GsCore | AstrBot | 当前镜像 |
| 2 | NapCat + AstrBot + GsCore | NapCat | 固定 v4.18.5 |
| 3 | NapCat + GsCore 轻量版（NG） | NapCat | 固定 v4.18.5 |
| 4 | NapCat + NoneBot + GsCore | NoneBot | 当前镜像 |
| 5 | NapCat + NoneBot + GsCore | NapCat | 固定 v4.18.5 |
| 6 | QQ 官方机器人 + NoneBot + GsCore | NoneBot | 不使用 NapCat |
| 7 | QQ 官方机器人 + GsCore | gscore-qqofficial | 不使用 NapCat |

七条路线默认使用相同的容器名和部分宿主机端口，不应以默认配置在同一台服务器上同时启动。

#### 路线 1：AstrBot GScore 适配器

```bash
git clone https://github.com/gufei233/NAG.git
cd NAG
cp .env.example .env

mkdir -p /opt/nag-data/{astrbot,napcat/config,napcat/plugins,napcat/qq,gscore/data,gscore/plugins}
docker compose config
docker compose up -d
docker compose --profile init run --rm astrbot-plugin-init
docker restart nag-astrbot
docker compose ps
```

#### 路线 2：NapCat GScore 适配器 + AstrBot

```bash
git clone https://github.com/gufei233/NAG.git
cd NAG
cp .env.example .env

mkdir -p /opt/nag-data/{astrbot,napcat/config,napcat/plugins,napcat/qq,gscore/data,gscore/plugins}
docker compose -f docker-compose.yml -f docker-compose.napcat-adapter.yml config
docker compose -f docker-compose.yml -f docker-compose.napcat-adapter.yml up -d
docker compose -f docker-compose.yml -f docker-compose.napcat-adapter.yml --profile init run --rm napcat-gscore-adapter-init
docker restart nag-napcat
docker compose -f docker-compose.yml -f docker-compose.napcat-adapter.yml ps
```

该叠加 Compose 会强制固定 NapCat v4.18.5。AstrBot 的 OneBot 平台、管理员 ID，以及 GsCore 主人列表仍需按下文的首次配置说明手动设置。

#### 路线 1/2/4/5 可选加入 BotShepherd

AstrBot 路线追加 `docker-compose.botshepherd.yml`；NoneBot 路线追加 `docker-compose.botshepherd-nonebot.yml`：

```bash
# 路线 1 + BotShepherd
docker compose \
  -f docker-compose.yml \
  -f docker-compose.botshepherd.yml \
  config

# 路线 2 + BotShepherd
docker compose \
  -f docker-compose.yml \
  -f docker-compose.napcat-adapter.yml \
  -f docker-compose.botshepherd.yml \
  config

# 路线 4 + BotShepherd
docker compose \
  -f docker-compose.nonebot.yml \
  -f docker-compose.botshepherd-nonebot.yml \
  config

# 路线 5 + BotShepherd
docker compose \
  -f docker-compose.nonebot.yml \
  -f docker-compose.napcat-adapter.yml \
  -f docker-compose.botshepherd-nonebot.yml \
  config
```

随后使用同一组 `-f` 参数执行 `up -d`。需要手动配置时，连接方向为：

```text
NapCat WebSocket 客户端：ws://botshepherd:2537/OneBotv11
BotShepherd 客户端监听：ws://0.0.0.0:2537/OneBotv11
AstrBot 目标端点：ws://astrbot:6199/ws
NoneBot 目标端点：ws://nonebot:8080/onebot/v11/ws
```

`2537` 和 `6199` 都只用于 `nag-net` 容器网络，不需要映射到宿主机。

#### 路线 3：NapCat GScore 适配器轻量版（NG）

```bash
git clone https://github.com/gufei233/NAG.git
cd NAG/NG
cp .env.example .env

mkdir -p /opt/ng-data/{napcat/config,napcat/plugins,napcat/qq,gscore/data,gscore/plugins}
docker compose config
docker compose up -d
docker compose --profile init run --rm napcat-gscore-adapter-init
docker restart ng-napcat
docker compose ps
```

`NG/.env.example` 已固定 `napcat-plugin-gscore-adapter` v1.3.3 的 release 地址与 SHA-256。初始化任务会先校验下载内容，在同一文件系统的临时目录解压，再原子替换旧插件；如需改用其他 release，必须同时更新 `NAPCAT_GSCORE_ADAPTER_ZIP_URL` 和 `NAPCAT_GSCORE_ADAPTER_SHA256`。也可以跳过该任务，改在 NapCat WebUI 手动安装，详见 `NG/README.md`。

#### 路线 4：NoneBot GScore 适配器

```bash
cp .env.example .env
mkdir -p /opt/nag-data/{nonebot/data,nonebot/plugins,napcat/config,napcat/plugins,napcat/qq,gscore/data,gscore/plugins}

docker compose -f docker-compose.nonebot.yml build nonebot
docker compose -f docker-compose.nonebot.yml --profile init run --rm napcat-gscore-adapter-disable
docker compose -f docker-compose.nonebot.yml --profile init run --rm nonebot-onebot-init
docker compose -f docker-compose.nonebot.yml up -d
```

该路线加载 NoneBot 的 `GenshinUID`，并自动关闭持久化数据中可能残留的 NapCat GScore 插件。

#### 路线 5：NapCat GScore 适配器 + NoneBot

```bash
cp .env.example .env
sed -i 's/^ENABLE_NONEBOT_GSCORE_ADAPTER=.*/ENABLE_NONEBOT_GSCORE_ADAPTER=false/' .env
mkdir -p /opt/nag-data/{nonebot/data,nonebot/plugins,napcat/config,napcat/plugins,napcat/qq,gscore/data,gscore/plugins}

docker compose -f docker-compose.nonebot.yml build nonebot
docker compose -f docker-compose.nonebot.yml -f docker-compose.napcat-adapter.yml --profile init run --rm napcat-gscore-adapter-init
docker compose -f docker-compose.nonebot.yml -f docker-compose.napcat-adapter.yml --profile init run --rm nonebot-onebot-init
docker compose -f docker-compose.nonebot.yml -f docker-compose.napcat-adapter.yml up -d
```

该路线必须在启动前将 `ENABLE_NONEBOT_GSCORE_ADAPTER` 设置为 `false`；上面的命令已经完成该设置。此时由 NapCat 插件处理 GScore，NoneBot 只处理普通插件消息，并固定使用 NapCat v4.18.5。

#### 路线 6：QQ 官方机器人 + NoneBot

在私有 `.env` 中填写 `QQ_APP_ID`、`QQ_APP_SECRET`、`QQ_TOKEN` 和可选的 `QQ_ADMIN_IDS`，其中管理员必须填写 QQ 开放平台提供的 OpenID。路线 6/7 使用独立数据目录，请同时把 `.env` 中的 `DATA_ROOT` 改为 `/opt/nag-qqofficial-data`（下面的 `sed` 已包含该步骤；删除该行则使用同名默认值）：

```bash
sed -i 's|^DATA_ROOT=.*|DATA_ROOT=/opt/nag-qqofficial-data|' .env
mkdir -p /opt/nag-qqofficial-data/{nonebot/data,nonebot/plugins,gscore/data,gscore/plugins}

docker compose --env-file .env -f docker-compose.qqofficial.yml build nonebot
docker compose --env-file .env -f docker-compose.qqofficial.yml up -d gscore nonebot
```

NoneBot 使用 WebSocket 连接 QQ 官方 Gateway，无需把 8080 端口映射到宿主机。`GenshinUID` 使用共享 `GSCORE_WS_TOKEN` 连接 `gscore:8765`。

#### 路线 7：QQ 官方机器人轻量直连

该路线只使用 `QQ_APP_ID` 和 `QQ_APP_SECRET`，`QQ_TOKEN` 不参与连接。与路线 6 相同，`.env` 需要 `DATA_ROOT=/opt/nag-qqofficial-data` 和非空的 `GSCORE_WS_TOKEN`。上游 `gscore-qqofficial` 当前没有预构建镜像，Compose 会从核对过的固定提交构建：

```bash
sed -i 's|^DATA_ROOT=.*|DATA_ROOT=/opt/nag-qqofficial-data|' .env
mkdir -p /opt/nag-qqofficial-data/{gscore/data,gscore/plugins,gscore-qqofficial}
chown 10001:10001 /opt/nag-qqofficial-data/gscore-qqofficial

docker compose --env-file .env -f docker-compose.qqofficial.yml build gscore-qqofficial
docker compose --env-file .env -f docker-compose.qqofficial.yml up -d gscore gscore-qqofficial
docker compose --env-file .env -f docker-compose.qqofficial.yml logs -f gscore-qqofficial
```

日志同时出现 `已连接 QQ Gateway` 和 `已连接 gsuid_core` 才表示链路完整。群聊和单聊采用 QQ 官方被动回复机制，通常需要在收到消息后的约 5 分钟内回复；管理员命令使用 OpenID 鉴权。

非 root 用户需要用 `sudo` 创建数据目录、将目录所有权交给当前用户，并把 `.env` 中的 `NAPCAT_UID`、`NAPCAT_GID` 改为 `id -u`、`id -g` 的结果。

## 目录规划

仓库目录只放 Compose、README 和模板文件；运行数据放到仓库外：

```text
路线 1/2/4/5: /opt/nag-data
路线 3:       /opt/ng-data
路线 6/7:     /opt/nag-qqofficial-data
```

这样可以避免 `git pull`、`git status`、`git clean` 影响机器人数据、QQ 登录态和配置文件。

## 默认端口

默认只绑定到服务器本机 `127.0.0.1`，更适合配合 SSH 隧道或反向代理使用。

| 端口 | 用途 | 默认映射到宿主机 |
| --- | --- | --- |
| `8765` | GsCore WebUI 与框架 WebSocket | `127.0.0.1:8765` |
| `6185` | AstrBot WebUI | `127.0.0.1:6185` |
| `6099` | NapCat WebUI | `127.0.0.1:6099` |
| `5111` | BotShepherd WebUI | 启用时映射到 `127.0.0.1:5111` |
| `6199` | AstrBot OneBot 反向 WebSocket | 仅 Compose 内部网络 |
| `8080` | NoneBot 驱动监听 | 仅 Compose 内部网络 |
| `2537` | BotShepherd 默认 OneBot 客户端端点 | 仅 Compose 内部网络 |

从本地电脑访问远程服务器时，可以开一个 SSH 隧道窗口：

```bash
ssh -N \
  -L 8765:127.0.0.1:8765 \
  -L 6185:127.0.0.1:6185 \
  -L 6099:127.0.0.1:6099 \
  -L 5111:127.0.0.1:5111 \
  root@你的服务器IP
```

保持这个窗口不要关闭，然后在本地浏览器打开上面的对应地址。

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

如果你是从旧版 compose 更新而来，务必使用上面的 `--force-recreate` 重建 `gscore` 服务。`docker restart nag-gscore` 只会重启旧容器，不会应用后来新增的 `/ms-playwright` volume 和 `PLAYWRIGHT_BROWSERS_PATH` 环境变量，容易出现依赖初始化成功但 GsCore 仍找不到浏览器的情况。

插件安装后，建议在 GsCore / AstrBot 重启完成并联通后再做插件初始化：

```text
ww下载全部资源
```

`RoverSign` 依赖 `XutheringWavesUID` 及其数据库，建议先确认 `XutheringWavesUID` 正常工作。总排行 token、评分 OCR token 等插件业务配置，进入 GsCore WebUI 的对应插件配置页填写。

## NoneBot 插件

NAG 中的每个 NoneBot 都是独立的官方 `nb-cli-plugin-docker` 项目。个人 QQ 项目默认位于 `${DATA_ROOT}/nonebot/project`，双通道中的 QQ 官方项目位于 `${DATA_ROOT}/nonebot-qqofficial/project`。每个项目都有自己的 `pyproject.toml`、`uv.lock`、官方 `Dockerfile` 和官方 `docker-compose.yml`，因此插件和依赖不会在两个机器人之间互相污染。

NAG 不修改官方生成的两个核心文件，而是额外生成 `Dockerfile.nag` 与 `docker-compose.nag.yml`，只补充媒体系统库、按需安装 Playwright Chromium、数据/缓存共享、NAG 网络和 Mimo Agent。后续重跑脚本时仍会调用官方命令重新生成项目。包含 QQ 凭据的 `.env.prod`、Agent 令牌、临时虚拟环境和部署元数据均会被排除在镜像构建上下文之外；运行时只读挂载所需文件，避免凭据进入不可变镜像层。

日常插件管理统一使用内置的 **Mimo Console**：

- 个人 QQ：`http://127.0.0.1:18081/mimo-console/`
- QQ 官方机器人：`http://127.0.0.1:18082/mimo-console/`

直接运行 `bash install.sh`，在顶层菜单选择“管理 NoneBot 插件（Mimo Console）”，脚本会列出实际存在的官方 Docker 实例和入口。WebUI 中对插件执行安装、更新或卸载时，受限的宿主机 Agent 会更新该实例自己的 `pyproject.toml` 与 `uv.lock`，构建新镜像，切换容器并做健康检查；失败则恢复旧锁文件和旧镜像。这样不会在运行中的容器里临时 `pip install`，容器重建后依赖也不会丢失。

首次安装且尚未创建管理员时，安装脚本会从当前 NoneBot 容器的本次启动日志中提取 Mimo Console 初始化令牌，并紧跟在对应 WebUI 地址后打印。管理员已经初始化时不会再次显示旧令牌；删除认证数据重新初始化后，重跑安装器可获取本次启动生成的新令牌。

个人 QQ 路线会把 `${DATA_ROOT}/nonebot/cache` 同时挂载到 NoneBot 与 NapCat 的 `/root/.cache/nonebot2`，其中 NapCat 使用只读挂载。这样插件向 OneBot 发送本地图片、语音或视频路径时，NapCat 能读取同一文件；既避免跨容器 `ENOENT`，也无需对大媒体启用 Base64。该共享只覆盖 NoneBot 缓存，不包含插件配置、凭据或其他持久化数据。

镜像扩展预装 `ffmpeg`、Cairo 等常用媒体系统库；当锁定依赖中存在 Playwright 时才安装 Chromium。因此 `nonebot-plugin-parser[all]` 这类插件的 Python 依赖和浏览器依赖都会进入同一个可回滚镜像，而不是与 GsCore 共用不兼容的 Python 环境。

注意：个人 NB 是 OneBot v11 适配器，官方 NB 是 adapter-qq——给官方实例装插件前先确认其支持 QQ 官方适配器；AstrBot 与个人 NB 同时收到普通消息，避免两边安装功能重叠的插件。

NoneBot 命令前缀默认为 `/`，可通过私有环境文件中的 `NONEBOT_COMMAND_START` 修改（逗号分隔多个前缀，如 `#` 或 `#,/`；空串元素表示允许无前缀命令）。修改 `.installer` 私有 env 后重跑安装器即可生效，安装器重跑时会保留该设置。与 AstrBot 并存时建议 NB 使用不同前缀（如 `#`）以减少命令重叠。

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

`WS_TOKEN` 设置后，AstrBot 的 GsCore 适配器里必须填写同一个 token。Docker 同机跨容器时，不建议只依赖 `TRUSTED_IPS`。通过 `install.sh` 安装时会自动生成并持久化共享 token，无需手动执行上述命令。

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

首次登录后请修改默认密码。使用 `install.sh` 时，安装器会把开头输入的主人 QQ 写入“配置 → 平台配置 → 管理员 ID”，自动在机器人列表创建并启用 NapCat / OneBot V11 平台，同时配置 NapCat 的 WebSocket 客户端；这条容器内连接默认不启用 Token。手动使用 compose 部署时，按下面的值配置：

```text
消息平台类别：aiocqhttp / OneBot V11
启用：开启
反向 WebSocket 主机：0.0.0.0
反向 WebSocket 端口：6199
反向 WebSocket Token：留空
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

通过 `install.sh` 选择 AstrBot 作为 GScore 处理方时，安装器会在首次安装时自动创建该插件配置，写入 `gscore:8765` 和与 GsCore 相同的共享 `WS_TOKEN`；token 也会保存在权限为 `600` 的管理环境文件中。已有 AstrBot 插件配置不会被整体覆盖，但初始化任务会把其中的 `WS_TOKEN` 同步为当前共享 token。只要安装 AstrBot，脚本就会自动配置 OneBot 反向 WebSocket；启用 BotShepherd 时，NapCat 的目标会自动改为 `ws://botshepherd:2537/OneBotv11`。

安装器会等待 GsCore WebUI 完全就绪后再执行配置和插件安装，避免在配置文件写入期间重启；NapCat 启动后还会从容器日志中提取并打印 WebUI Token 和带 Token 的登录地址。

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

登录 NapCat 后扫码登录 QQ。直接手动使用 compose 时，默认使用：

```yaml
MODE: astrbot
```

这个模式会按 NapCat-Docker 的 AstrBot 预设配置：

```text
ws://astrbot:6199/ws
```

扫码登录 QQ 后，NapCat 会使用该客户端连接 AstrBot。使用 `install.sh` 时，地址、启用状态以及两端的空 Token 都会自动写入。如果手动部署时自动配置没有生效，可在 NapCat 网络配置中手动新建 WebSocket 客户端 / 反向 WebSocket：

```text
URL：ws://astrbot:6199/ws
消息格式：Array
Token：留空
```

启用 BotShepherd 时，将上述 URL 改为：

```text
URL：ws://botshepherd:2537/OneBotv11
```

### 4. 配置 BotShepherd（可选）

打开：

```text
http://127.0.0.1:5111
```

一键脚本会自动使用主人 QQ 作为 BotShepherd 超级用户，创建默认连接，并从日志中读取随机初始密码。默认连接已经配置为监听 NapCat，并转发给 AstrBot：

```text
客户端端点：ws://0.0.0.0:2537/OneBotv11
AstrBot 目标端点：ws://astrbot:6199/ws
NoneBot 目标端点：ws://nonebot:8080/onebot/v11/ws
```

配置、数据库和日志分别保存在 `/opt/nag-data/botshepherd/config`、`data` 和 `logs`。如果复用已有数据，安装器不会覆盖现有 WebUI 密码；切换 AstrBot/NoneBot 路线时会把默认连接目标更新为当前框架。

#### 管理 BotShepherd 宿主机端口

运行：

```bash
bash install.sh --mode botshepherd-ports
```

管理器支持单个端口和不超过 100 个端口的连续范围，例如：

```text
127.0.0.1:2537 -> botshepherd:2537
127.0.0.1:2538-2547 -> botshepherd:2538-2547
```

映射状态和生成的 Compose 叠加文件保存在 `.installer/`，应用变更时只会短暂重建 `nag-botshepherd`。默认使用 `127.0.0.1`，适合同一服务器上的非容器程序；只有确实需要其他主机连接时才使用 `0.0.0.0`，并应同步限制防火墙或安全组来源。

注意区分连接方向：

- 非容器 NapCat、Lagrange 等 OneBot 客户端主动连接 BotShepherd 时，需要映射其 `client_endpoint` 所使用的端口。
- 非容器 NoneBot 作为 BotShepherd 下游目标时，通常不需要新增 BotShepherd 映射；在目标端点中填写 `ws://host.docker.internal:<NoneBot端口>/<WebSocket路径>`。NoneBot 必须监听宿主机上容器可达的地址，不能只监听 `127.0.0.1`。
- 每个 OneBot 客户端仍应在 BotShepherd WebUI 中使用独立连接配置和独立监听端口。

例如新增 `2538` 映射后，在 BotShepherd WebUI 中创建连接：

```text
客户端端点：ws://0.0.0.0:2538/OneBotv11
目标端点：ws://host.docker.internal:8080/onebot/v11/ws
```

### 5. 联调

按顺序重启一次：

```bash
docker restart nag-gscore nag-astrbot nag-napcat
```

启用了 BotShepherd 时：

```bash
docker restart nag-gscore nag-astrbot nag-botshepherd nag-napcat
```

观察日志：

```bash
docker logs -f nag-gscore
docker logs -f nag-astrbot
docker logs -f nag-napcat
docker logs -f nag-botshepherd   # 仅启用 BotShepherd 时
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

一键脚本的大陆网络模式（`--cn` 或自动检测）会在这方面自动处理：鸣潮插件问答默认选 CNB 镜像、GsCore 的 `GSCORE_PYTHON_INDEX` 写为清华 PyPI 镜像，并可选配置 Docker Hub 镜像加速（写入 `/etc/docker/daemon.json`，已有 `registry-mirrors` 配置时不改动）。国际网络环境则保持 GitHub 与官方源。

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

### 一键脚本部署

更新代码后重新运行脚本，选择“修复或更新当前方案”。脚本会复用已有选择和私有配置，并按差异决定需要拉取、构建、重建或重启的组件：

```bash
git pull --ff-only
bash install.sh
```

查看所有 NAG 容器：

```bash
docker ps --filter name=nag-
```

查看常用日志：

```bash
docker logs -f nag-gscore
docker logs -f nag-astrbot
docker logs -f nag-napcat
docker logs -f nag-nonebot
docker logs -f nag-nonebot-qqofficial
docker logs -f nag-gscore-qqofficial
docker logs -f nag-botshepherd
```

只查看实际启用的容器即可。不要为了更新一键脚本部署而直接运行不带 `-f` 和 `--env-file` 的 `docker compose up`，否则可能使用到传统路线的默认 Compose。

备份默认运行数据和安装状态：

```bash
tar -czf "nag-backup-$(date +%F).tar.gz" \
  /opt/nag-data \
  .installer
```

如果安装时选择了其他数据目录，请将 `/opt/nag-data` 替换成实际路径。

### 手动 Compose 部署

查看状态：

```bash
docker compose ps
```

重启当前手动路线：

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

备份默认运行数据：

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

### AstrBot 初始密码没有打印或已经忘记

新安装时，AstrBot 通常要在 WebUI 真正就绪后才输出随机初始密码。一键脚本会等待并从当前容器日志提取；也可以手动查看：

```bash
docker logs nag-astrbot 2>&1 \
  | sed -n 's/.*Initial password:[[:space:]]*\([^[:space:]]*\).*/\1/p' \
  | tail -n 1
```

命令没有输出通常表示 AstrBot 正在复用已有数据，或者产生初始密码的旧容器日志已经随容器重建而消失。`/opt/nag-data/astrbot/cmd_config.json` 中的 `dashboard.password` 和 `pbkdf2_password` 都是哈希，不能还原成明文；不要把哈希直接当作登录密码，也不要为了找回密码直接删除整个 AstrBot 数据目录。

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

说明 NapCat 能解析到 AstrBot 容器，但 AstrBot 还没有监听 6199。`install.sh` 会自动创建平台并检查监听端口；手动部署时请检查 AstrBot 的 aiocqhttp / OneBot V11 平台是否启用，端口是否为 `6199`，保存后重启：

```bash
docker restart nag-astrbot nag-napcat
```

### NapCat 日志里出现 ECONNREFUSED botshepherd:2537

先确认 BotShepherd 容器已启动，并且默认连接仍在监听 `0.0.0.0:2537/OneBotv11`：

```bash
docker compose \
  -f docker-compose.yml \
  -f docker-compose.botshepherd.yml \
  ps
docker logs --tail=200 nag-botshepherd
```

BotShepherd 日志显示连接 AstrBot 失败时，再检查 AstrBot 的 `6199` 监听平台。容器之间使用 Compose 服务名，不要把地址改成 `localhost`。

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
