# OpenResty Plus 快速启动

本仓库统一管理本地演示环境，提供源码启动和预编译镜像启动。OpenResty Plus 主程序已经将 Vue 管理界面嵌入 Go 可执行文件，启动后通过同一个地址提供页面和 API。

| 方式 | 用途 | 命令 |
| --- | --- | --- |
| Release 二进制启动 | 使用预编译的 Go 程序连接已配置的外部中间件 | `./quickstart.sh` |
| 源码启动 | 从 `openresty-plus` 拉取源码，在本机编译单体程序 | `./scripts/start-source.sh` |
| Compose 镜像启动 | 使用 Release/Beta 镜像启动管理平台 | `./scripts/start-compose.sh` |

两种模式都连接用户自行提供的 MySQL、Redis、Kafka，不会替用户启动这些中间件。启动前会检查必填连接配置和对应 TCP 端口。三个 OpenResty 演示节点及 Filebeat 默认关闭，可在 `.env` 设置 `QUICKSTART_START_DEMOS=true` 或启动时添加 `--with-demos` 开启。请求生成器也默认关闭；设置 `QUICKSTART_START_TRAFFIC_GENERATOR=true` 或添加 `--with-traffic` 可启用，它会自动启动三个演示节点，并持续轮询请求它们。Filebeat 默认使用 `OPENRESTY_KAFKA_BOOTSTRAP_SERVERS` 中的 broker；如需单独指定，可编辑 `FILEBEAT_KAFKA_HOSTS` 为 JSON/YAML 列表。演示容器使用 host network；主机需预留管理平台 8081 端口，以及每个演示节点的 HTTP、Control API 端口（18080/18081、18180/18181、18280/18281）。源码模式额外需要 Go 1.26.1、Node.js 22.18+ 或 24.12+、pnpm 11.16.0 和 Docker。

## Release 二进制启动

准备运行环境配置：

```sh
cp .env.binary.example .env
```

编辑 `.env`，填写外部 MySQL 的 JDBC 地址、用户名和密码，Kafka broker 地址与 topic，Redis 地址，以及管理员密码和 64 位数据密钥。MySQL、Kafka 和 Redis 必须已启动，脚本会在启动前检查配置并检查对应 TCP 端口是否可达。

管理员配置可使用 `OPENRESTY_ADMIN_USERNAME`/`OPENRESTY_ADMIN_PASSWORD`，也兼容 Compose 风格的 `ADMIN_USERNAME`/`ADMIN_PASSWORD`；如果两种名称都填写，优先使用 `OPENRESTY_*`。

未找到本地程序时，脚本会自动查询 OpenrestyPlus/openresty-plus 最新 GitHub Release，按当前系统和 CPU 架构下载程序包，校验 SHA-256 后安装到 `bin/openresty-plus`。也可在 `.env` 中设置 `OPENRESTY_PLUS_BINARY_URL` 指定原始可执行文件下载地址；`OPENRESTY_PLUS_BINARY_PATH` 可改为其他本地文件路径。自动解析 Release 需要 `curl` 和 `python3`。

```sh
./quickstart.sh
./quickstart.sh status
./quickstart.sh logs -f
./quickstart.sh restart
./quickstart.sh stop
```

默认命令为后台启动，管理界面和 API 地址由 `OPENRESTY_HTTP_ADDR` 决定，默认是 http://127.0.0.1:8081。该模式只启动 OpenResty Plus 应用进程，不会启动或管理中间件容器。

## 源码启动

```sh
./scripts/start-source.sh
```

首次运行会克隆 [openresty-plus](https://github.com/OpenrestyPlus/openresty-plus) monorepo，生成本地 `.env` 中的管理员和数据加密密钥，并提示填写 MySQL、Redis、Kafka 外部连接配置。再次运行会先检查连接，再编译前后端单体可执行文件，最后以前台模式运行程序。默认不启动演示节点、Filebeat 和请求生成器。使用 `--with-demos` 时会先临时启动管理 API，自动准备演示中心、三台节点和告警演示数据，再启动演示服务并以前台模式运行管理平台。使用 `--with-traffic` 会同时启用这些演示服务和请求生成器。

```sh
# 源码启动，默认不启动演示服务
./scripts/start-source.sh

# 同时启动三个 OpenResty 演示节点和 Filebeat
./scripts/start-source.sh --with-demos

# 启动演示服务，并持续请求三个节点以生成访问日志
./scripts/start-source.sh --with-traffic
```

- 管理界面和 API：http://127.0.0.1:8081
- 默认账号：`admin`；随机密码保存在 `.env` 的 `OPENRESTY_ADMIN_PASSWORD`
- OpenResty 演示节点（启用 `--with-demos` 后）：http://127.0.0.1:18080、http://127.0.0.1:18180、http://127.0.0.1:18280
- 请求生成器默认关闭；启用 `--with-traffic` 后按顺序轮询三个节点。`.env` 中的 `TRAFFIC_REQUEST_INTERVAL_SECONDS`（默认 0.5 秒）和 `TRAFFIC_REQUEST_TIMEOUT_SECONDS` 可调整请求间隔和超时。
- 导入器：可在镜像模式中按需启用，访问 http://127.0.0.1:8090

按 Ctrl+C 停止前台程序。演示服务可运行 `docker compose --env-file .env -f docker-compose.source.yaml --profile demos --profile traffic down` 停止。

## Compose 镜像启动

### 1. 生成本地配置

```sh
./scripts/init-compose-env.sh
```

编辑 `.env`，确认 `OPENRESTY_PLUS_IMAGE` 使用主程序仓库的 Container Registry 地址，`RUNTIME_IMAGE` 和 `FILEBEAT_IMAGE` 使用本仓库的 Registry 地址，并填写 MySQL、Redis、Kafka 连接参数。`IMAGE_TAG=latest` 表示稳定版，`IMAGE_TAG=beta` 表示 Beta。私有镜像仓库需先运行 `docker login <GitLab registry 地址>`。

脚本会生成管理员密码和数据密钥。请填写外部 MySQL、Redis、Kafka 连接配置；`.env` 不要提交，升级后继续使用原 `DATA_KEY`。

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

启用演示服务时，quickstart 会等待管理 API 就绪，使用管理员账号幂等创建/复用 `quickstart-local` 演示中心，并登记 `openresty-east-1/2/3`。若本地存在 monorepo 后端源码，还会自动运行告警演示数据脚本（本地 Webhook、飞书待配置通道、TLS 到期证书和提醒规则）；通道默认停用，不会外发。Compose 镜像模式需要安装 Go 并有 `openresty-plus/orp-backend` 源码目录；目录不在默认位置时可设置 `ORP_BACKEND_DIR`。首次启用演示服务的 Compose 流程会先单独启动管理平台，完成登记和数据准备后再启动节点与 Filebeat。

启用演示节点时，quickstart 会同时运行每个节点的 `orp-node-agent`。Agent 使用独立客户端证书通过 mTLS 回连管理平台；CA 与节点私钥存放在 Git 忽略的 `secrets/node-agent/`，管理容器只挂载服务端证书、私钥和客户端 CA。每个 Agent 以低权限账户运行，只允许调用固定的 OpenResty 配置校验与 reload helper。若相邻目录存在 `orp-node-agent` 仓库，启动时优先使用该源码；否则从 GitHub 获取 `main`（可通过 `ORP_NODE_AGENT_REF` 指定分支或标签）。当前 Agent 控制协议支持状态心跳和受控 reload；发布制品传输及批量发布尚未接入此 Agent 协议。

打开 http://127.0.0.1:8081 登录。管理员账号和密码分别见 `.env` 中的 `ADMIN_USERNAME`、`ADMIN_PASSWORD`。主程序在首次启动时自动初始化数据库表结构。

OpenResty 演示节点使用主机端口 18080、18180、18280；Control API 端口为 18081、18181、18281。演示发布会通过 Docker socket 操作本地节点，并使用 `runtime/` 下的共享配置目录。Docker socket 赋予容器管理本机 Docker 的能力，只应在可信的开发或演示主机运行。

按需启动 NGINX 配置导入器：

```sh
docker compose --profile importer up -d importer
```

导入器只写入控制面资源，不会发布、校验或重载 OpenResty 配置。

查看日志及停止：

```sh
docker compose logs -f openresty-plus
docker compose down
```

演示服务不启动时，Compose 只运行管理平台容器。

## Release 与 Beta 镜像

`openresty-plus` monorepo 的 GitLab CI 在 `beta` 分支生成 Beta 二进制和单体应用镜像；推送 `vX.Y.Z` 或 `vX.Y.Z-beta.N` 标签时发布对应镜像并创建 Release，Release 附有可下载的 Linux 可执行文件。本仓库的 GitLab CI 发布 OpenResty Control API 与 Filebeat 演示镜像。GitLab Runner 需允许启用 TLS 的 Docker-in-Docker；首次发布前，在两个项目的 GitLab CI/CD 设置中启用 Container Registry。

如果 GitHub 是源仓库，需将两个项目同步到 GitLab 并启用 GitLab CI/CD；GitHub 上的 `.gitlab-ci.yml` 不会自行触发 GitLab Pipeline。

## 目录

```text
docker-compose.yaml            预编译镜像和可选演示服务配置
docker-compose.source.yaml     源码模式的可选演示服务配置
deploy/openresty/              OpenResty 演示节点镜像与配置
deploy/filebeat/               Filebeat 演示镜像与日志采集配置
deploy/traffic-generator/      可选的三节点演示请求生成器
scripts/start-source.sh        获取源码、生成配置并启动源码模式
scripts/start-compose.sh       检查外部依赖并启动镜像模式
scripts/dev-source.sh          检查依赖、编译并启动源码程序
scripts/init-compose-env.sh    生成 Compose 镜像模式的本地密钥
scripts/deploy/                节点登记、迁移及发布运维脚本
```
