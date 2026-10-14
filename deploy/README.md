# 演示节点和日志采集镜像

本目录包含快速启动环境专用的 OpenResty Control API 演示节点、Lua 配置及 Filebeat 日志采集镜像。这些镜像只供 `docker-compose.yaml` 与 `docker-compose.source.yaml` 使用，不属于 `orp` 单体应用制品。

- `openresty/`: 构建带 Control API 的 OpenResty 演示节点。
- `filebeat/`: 采集演示节点的访问和错误日志并写入 `.env` 中配置的 Kafka。

源码模式由 `docker-compose.source.yaml` 从本目录构建镜像；`beta` 分支和版本标签会由本仓库的 GitLab CI 构建并发布镜像。
