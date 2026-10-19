# ORP 快速启动

本仓库统一管理本地演示环境，提供源码启动和预编译镜像启动。ORP 主程序已经将 Vue 管理界面嵌入 Go 可执行文件，启动后通过同一个地址提供页面和 API。

| 方式 | 用途 | 命令 |
| --- | --- | --- |
| Release 二进制启动 | 使用预编译的 Go 程序连接已配置的外部中间件 | `./quickstart.sh` |
| 源码启动 | 从 `orp` 拉取源码，在本机编译单体程序 | `./scripts/start-source.sh` |
| Compose 镜像启动 | 使用 Release/Beta 镜像启动管理平台 | `./scripts/start-compose.sh` |

两种模式都连接用户自行提供的 MySQL、Redis、Kafka，不会替用户启动这些中间件。启动前会检查必填连接配置和对应 TCP 端口。三个 OpenResty 演示节点及 Filebeat 默认关闭，可在 `.env` 设置 `QUICKSTART_START_DEMOS=true` 或启动时添加 `--with-demos` 开启。请求生成器也默认关闭；设置 `QUICKSTART_START_TRAFFIC_GENERATOR=true` 或添加 `--with-traffic` 可启用，它会自动启动三个演示节点，按演示路由清单持续轮询请求，并提供本地 HTTP API 和 TCP 回显上游。演示节点会输出 JSON 访问日志，Filebeat 自动将日志转发至 `ORP_KAFKA_TOPIC`；默认 broker 来自 `ORP_KAFKA_BOOTSTRAP_SERVERS`，也可通过 `FILEBEAT_KAFKA_HOSTS` 指定 JSON 字符串列表。Filebeat 为每个演示节点使用独立 Docker named volume 保存 registry 和磁盘队列；`FILEBEAT_DISK_QUEUE_MAX_SIZE` 可配置队列上限，`FILEBEAT_KAFKA_REQUIRED_ACKS` 默认 `1` 适用于本地演示，生产环境需结合 Kafka topic 副本与 `min.insync.replicas` 配置。普通 `docker compose down` 会保留状态卷；`docker compose down -v` 会删除它们并丢弃未发送队列。Quickstart 会自动关联演示中心 UUID 和节点 ID。演示容器使用 host network；主机需预留管理平台 8081、演示后端 19000–19002、节点管理/Control API 端口（18080/18081、18180/18181、18280/18281），以及本地演示数据面端口。为避免多个节点在同一主机上监听冲突，发布配置时 HTTP/Stream 监听端口按节点分别增加 20000、30000、40000；当前演示 HTTP/Stream 端口分别为 east-1 的 20080/28080/39090、east-2 的 30080/38080/49090、east-3 的 40080/48080/59090。源码模式额外需要 Go 1.26.1、Node.js 22.18+ 或 24.12+、pnpm 11.16.0 和 Docker。

## Release 二进制启动

准备运行环境配置：

```sh
cp .env.binary.example .env
```

编辑 `.env`，填写外部 MySQL 的 JDBC 地址、用户名和密码，Kafka broker 地址与 topic，Redis 地址，以及管理员密码和 64 位数据密钥。MySQL、Kafka 和 Redis 必须已启动，脚本会在启动前检查配置并检查对应 TCP 端口是否可达。

源码和 Compose 启动统一使用 `.env` 中的 `ORP_ADMIN_USERNAME`、`ORP_ADMIN_PASSWORD` 与 `ORP_DATA_KEY`。

登录页会从后端读取 quickstart `.env` 中的管理员账号和密码并预填，便于本地调试。`ORP_CAPTCHA_ENABLED` 默认是 `false`；设为 `true` 后登录页会显示必填的滑块验证。当前滑块由前端组件完成，适用于调试和交互校验，不应作为公网防刷措施。由于账号密码会提供给登录页用于预填，请勿将启用该配置的实例直接暴露到不可信网络。

未找到本地程序时，脚本会自动查询 ORP/orp 最新 GitHub Release，按当前系统和 CPU 架构下载程序包，校验 SHA-256 后安装到 `bin/orp`。也可在 `.env` 中设置 `ORP_BINARY_URL` 指定原始可执行文件下载地址；`ORP_BINARY_PATH` 可改为其他本地文件路径。自动解析 Release 需要 `curl` 和 `python3`。

```sh
./quickstart.sh
./quickstart.sh status
./quickstart.sh logs -f
./quickstart.sh restart
./quickstart.sh stop
```

默认命令为后台启动，管理界面和 API 地址由 `ORP_HTTP_ADDR` 决定，默认是 http://127.0.0.1:8081。该模式只启动 ORP 应用进程，不会启动或管理中间件容器。

## 源码启动

```sh
./scripts/start-source.sh
```

首次运行会克隆 [openresty-pilot](https://github.com/OpenrestyPilot/openresty-pilot) 仓库，生成本地 `.env` 中的管理员和数据加密密钥，并提示填写 MySQL、Redis、Kafka 外部连接配置。再次运行会先检查连接，再编译前后端单体可执行文件，最后以前台模式运行程序。默认不启动演示节点、Filebeat 和请求生成器。使用 `--with-demos` 时会先临时启动管理 API，自动准备演示中心、三台节点和告警演示数据，再启动演示服务并以前台模式运行管理平台。使用 `--with-traffic` 会同时启用这些演示服务和请求生成器。

```sh
# 源码启动，默认不启动演示服务
./scripts/start-source.sh

# 同时启动三个 OpenResty 演示节点和 Filebeat
./scripts/start-source.sh --with-demos

# 启动演示服务，并持续请求三个节点以生成访问日志
./scripts/start-source.sh --with-traffic
```

- 管理界面和 API：http://127.0.0.1:8081
- 默认账号：`admin`；随机密码保存在 `.env` 的 `ORP_ADMIN_PASSWORD`
- OpenResty 节点管理/探针地址（启用 `--with-demos` 后）：http://127.0.0.1:18080、http://127.0.0.1:18180、http://127.0.0.1:18280；已发布的演示业务流量通过各节点独立的数据面端口访问，端口表见下文。
- 请求生成器默认关闭；启用 `--with-traffic` 后按顺序轮询三个节点。`.env` 中的 `TRAFFIC_REQUEST_INTERVAL_SECONDS`（默认 0.5 秒）和 `TRAFFIC_REQUEST_TIMEOUT_SECONDS` 可调整请求间隔和超时。
- 导入器：可在镜像模式中按需启用，访问 http://127.0.0.1:8090

按 Ctrl+C 停止前台程序。演示服务可运行 `docker compose --env-file .env -f docker-compose.source.yaml --profile demos --profile traffic down` 停止。

## Compose 镜像启动

### 1. 生成本地配置

```sh
./scripts/init-compose-env.sh
```

编辑 `.env`，确认 `ORP_IMAGE` 使用主程序仓库的 Container Registry 地址，`RUNTIME_IMAGE` 和 `FILEBEAT_IMAGE` 使用本仓库的 Registry 地址，并填写 MySQL、Redis、Kafka 连接参数。`IMAGE_TAG=latest` 表示稳定版，`IMAGE_TAG=beta` 表示 Beta。私有镜像仓库需先运行 `docker login <GitLab registry 地址>`。

脚本会生成管理员密码和数据密钥。请填写外部 MySQL、Redis、Kafka 连接配置；`.env` 不要提交，升级后继续使用原 `ORP_DATA_KEY`。

### 2. 启动

```sh
./scripts/start-compose.sh
```

启动脚本会检查连接配置和端口，再启动管理平台。要同时启动演示节点和 Filebeat：

```sh
./scripts/start-compose.sh --with-demos

# 自动开启三个演示节点、Filebeat 和请求生成器
./scripts/start-compose.sh --with-traffic
```

也可以在 `.env` 中设置 `QUICKSTART_START_DEMOS=true`，让后续启动默认包含这些演示服务。
请求生成器可单独通过 `QUICKSTART_START_TRAFFIC_GENERATOR=true` 启用；此时脚本会一并启动三个 OpenResty 节点。请求默认每 0.5 秒发出一次，并在三台节点间轮询；可用 `TRAFFIC_REQUEST_INTERVAL_SECONDS` 和 `TRAFFIC_REQUEST_TIMEOUT_SECONDS` 调整频率和超时。使用 `--without-traffic` 可在某次启动时关闭生成器。

启用演示服务时，quickstart 会等待管理 API 就绪，使用管理员账号幂等创建/复用 `quickstart-local` 演示中心，并登记 `openresty-east-1/2/3`。它还会准备带上海坐标的演示中心、HTTP 监听与路由、多个 Upstream、TCP Stream、DNS 解析器、IP 组、系统配置，以及 HTTP/Stream 全局指令、日志格式和错误页；请求清单写入 `runtime/traffic-generator/manifest.json`。本地 Webhook、飞书待配置通道、TLS 到期证书和提醒规则由告警演示数据脚本准备；通知通道默认停用，不会外发。演示资源会形成待比较/待发布的配置，但启动时不会自动下发到 OpenResty 节点。GeoIP 地理流量需要管理员导入合法的 GeoLite2 City 数据库后才会显示真实位置。Compose 镜像模式需要安装 Go 并有 `openresty-pilot/orp-backend` 源码目录；目录不在默认位置时可设置 `ORP_BACKEND_DIR`。首次启用演示服务的 Compose 流程会先单独启动管理平台，完成登记和数据准备后再启动节点与 Filebeat。

启用演示节点时，quickstart 会同时运行每个节点的 `orp-node-agent`。Agent 使用独立客户端证书通过 mTLS 回连管理平台；CA 与节点私钥存放在 Git 忽略的 `secrets/node-agent/`，管理容器只挂载服务端证书、私钥和客户端 CA。每个 Agent 以低权限账户运行，只允许调用固定的 OpenResty 配置校验与 reload helper。若相邻目录存在 `orp-node-agent` 仓库，启动时优先使用该源码；否则从 GitHub 获取 `main`（可通过 `ORP_NODE_AGENT_REF` 指定分支或标签）。Agent 控制协议支持状态心跳、受控 reload，以及在固定非 root 发布 profile 下进行候选配置校验和发布；root-master、容器编排和多实例拓扑仍不支持 Agent 候选发布。

打开 http://127.0.0.1:8081 登录；Quickstart 同时启动独立大屏，地址为 http://127.0.0.1:8082/。管理员账号和密码分别见 `.env` 中的 `ORP_ADMIN_USERNAME`、`ORP_ADMIN_PASSWORD`。主程序在首次启动时自动初始化数据库表结构。Quickstart 的控制面与大屏分别监听 8081 和 8082，构建本地控制面镜像时必须把卡片入口指向独立大屏地址：

```sh
docker build --build-arg VITE_ORP_SCREEN_URL=http://127.0.0.1:8082/ \
  -t "${ORP_IMAGE:-orp-local}:${IMAGE_TAG:-latest}" \
  -f ../openresty-pilot/deploy/Dockerfile ../openresty-pilot
docker compose --env-file .env -f docker-compose.yaml up -d --no-deps --force-recreate orp
```

若在发布网关后面部署并将同源 `/screen/` 转发至 `orp-screen`，才使用默认 `/screen/` 路径。Quickstart 的控制面没有该同源反向代理，不能把 `/screen/` 当作独立大屏服务入口。

OpenResty 演示节点管理/探针端口为 18080、18180、18280；Control API 端口为 18081、18181、18281。发布到本机三节点时，HTTP/Stream 监听端口分别使用 east-1 的 `20080/28080/39090`、east-2 的 `30080/38080/49090`、east-3 的 `40080/48080/59090`，以隔离同一主机上的监听端口。演示发布会通过 Docker socket 操作本地节点，并使用 `runtime/` 下的共享配置目录。Docker socket 赋予容器管理本机 Docker 的能力，只应在可信的开发或演示主机运行。

按需启动 NGINX 配置导入器：

```sh
docker compose --profile importer up -d importer
```

导入器只写入控制面资源，不会发布、校验或重载 OpenResty 配置。

查看日志及停止：

```sh
docker compose logs -f orp
docker compose down
```

演示服务不启动时，Compose 只运行管理平台容器。

## Release 与 Beta 镜像

`orp` monorepo 的 GitLab CI 在 `beta` 分支生成 Beta 二进制和单体应用镜像；推送 `vX.Y.Z` 或 `vX.Y.Z-beta.N` 标签时发布对应镜像并创建 Release，Release 附有可下载的 Linux 可执行文件。本仓库的 GitLab CI 发布 OpenResty Control API 与 Filebeat 演示镜像。GitLab Runner 需允许启用 TLS 的 Docker-in-Docker；首次发布前，在两个项目的 GitLab CI/CD 设置中启用 Container Registry。

如果 GitHub 是源仓库，需将两个项目同步到 GitLab 并启用 GitLab CI/CD；GitHub 上的 `.gitlab-ci.yml` 不会自行触发 GitLab Pipeline。

## 目录

```text
docker-compose.yaml            预编译镜像和可选演示服务配置
docker-compose.source.yaml     源码模式的可选演示服务配置
deploy/openresty/              OpenResty 演示节点镜像与配置
deploy/filebeat/               Filebeat 演示镜像与日志采集配置
deploy/LOG-OPERATIONS.md       日志链路生产运维及故障验收清单
deploy/traffic-generator/      可选的三节点演示请求生成器
scripts/start-source.sh        获取源码、生成配置并启动源码模式
scripts/start-compose.sh       检查外部依赖并启动镜像模式
scripts/dev-source.sh          检查依赖、编译并启动源码程序
scripts/init-compose-env.sh    生成 Compose 镜像模式的本地密钥
scripts/deploy/                节点登记、迁移及发布运维脚本
```
