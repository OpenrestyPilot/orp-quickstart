# 日志链路生产运维与验收

本文定义 Filebeat → Kafka → ORP 控制面的上线检查和故障验收。Quickstart 的三节点演示配置用于验证链路，不代表生产容量、可用性或数据保留承诺。容量、延迟和丢失容忍度应由部署方按日志量、恢复时间目标及存储预算确定。

## 交付与持久化边界

- Filebeat 为每个节点配置独立 `path.data`、磁盘队列和 Docker named volume。设置 `FILEBEAT_DISK_QUEUE_MAX_SIZE` 前应预留磁盘空间，并将队列容量与 Kafka 最长中断时长、日志峰值速率一起核算。
- Filebeat 磁盘队列只缓存未能交付的事件；Kafka 仍需配置生产级副本、`min.insync.replicas`、保留期、磁盘告警和故障域。配置 `FILEBEAT_KAFKA_REQUIRED_ACKS=-1` 前，确认 topic 的副本和最小同步副本配置能满足该确认级别。
- named volume 保存 Filebeat registry 与磁盘队列。普通 `docker compose down` 保留 named volume；`docker compose down -v` 会删除它们。应先确认队列已清空并有可接受的 checkpoint/恢复方案，再执行删除卷操作。
- 控制面消费 Kafka 后写入 MySQL。生产部署还要定义日志表保留、归档/清理、备份恢复、磁盘阈值与查询性能策略；本项目不默认删除生产日志。

## 上线前检查

1. 明确访问/错误日志字段、脱敏规则、日志峰值和平均速率、Kafka 故障容忍时长、允许积压、端到端延迟和保留期，并形成部署记录。
2. 检查 Kafka topic 分区、副本数、`min.insync.replicas`、保留策略、ACL/TLS，以及 Filebeat 与控制面使用的 broker/topic 是否一致。
3. 根据中断窗口和峰值写入估算每个 Filebeat 节点的磁盘队列上限；检查持久卷的容量、权限、inode、告警和备份/恢复策略。
4. 检查 Filebeat registry 与队列数据目录挂载在专用持久卷，卷不会被部署清理流程误删。
5. 检查控制面 consumer group、MySQL 写入权限/连接池、数据保留作业和备份恢复演练安排。

## 故障注入验收

在隔离验收环境中逐项执行，记录开始/结束时间、broker 状态、consumer lag、MySQL 最新事件时间和错误日志：

| 场景 | 注入方式 | 验收条件 |
| --- | --- | --- |
| Kafka 短时不可用 | 暂停 broker 网络或停止验收 Kafka | Filebeat 保持运行，磁盘队列增长；恢复 broker 后队列下降，事件最终进入 MySQL，允许按 Kafka/消费语义出现重复但不得静默丢失 |
| Filebeat 重启 | 保持 Kafka 可用时重启一个采集器 | 重启后从持久 registry 继续采集；没有从最早位置重复读取整个文件，也没有跳过未确认事件 |
| Filebeat 卷保留 | `docker compose down` 后再启动 | named volume 仍存在，registry 与队列状态恢复 |
| 队列达到容量 | 在隔离环境降低队列上限并中断 Kafka | 观察磁盘告警、Filebeat backpressure 和源日志轮转窗口；记录达到容量后的可接受行为，确认容量阈值不会被误报为无损 |
| 控制面消费者暂停 | 停止控制面消费但保持 Kafka/Filebeat | consumer lag 上升且 Kafka 保留期足以覆盖暂停时间；恢复后 lag 回落、MySQL 持续写入 |
| MySQL 短时不可用 | 隔离验收环境暂停数据库写入 | 控制面不提交尚未持久化的 Kafka offset；数据库恢复后可重试处理。核对错误日志与 lag 恢复 |
| 脏/超限消息 | 向验收 topic 写入无效 envelope 与超限 payload | 记录消息拒绝/隔离行为；确认不会无限阻塞同一 partition，或明确由运维通过审计过的流程处置 |

每项记录通过/失败、观测指标、恢复时长和数据核对结果。不要在生产环境直接注入故障；先在同版本、等价配置的验收环境验证。

## 运行观察与升级

- 监测 Filebeat 事件输出/重试、磁盘队列占用、数据目录剩余空间、进程重启和 Kafka broker 错误。
- 监测 Kafka partition/group lag、消息速率、磁盘空间、副本同步状态和 topic retention。
- 监测控制面消费速率、写入失败、MySQL 表增长/写延迟、最旧未处理事件时间和归档作业结果。
- 发布或升级前记录镜像版本、配置摘要、卷位置和回滚步骤。升级期间保留 Filebeat 数据卷；若需要重建卷，先核实队列为空并保存验收记录。
- 若 Filebeat 队列耗尽、Kafka 保留期不足或数据库空间不足，按既定事件流程降载/扩容/归档；不要删除队列或 offset 来掩盖积压。

## 项目当前未验证项

本仓库提供演示 Filebeat、Kafka 接入与控制面 MySQL 消费实现，但没有随附生产 Kafka 集群、生产指标/SLO、容量参数、备份系统或真实故障注入结果。部署团队须填写目标值并完成以上验收后，才能声明生产日志链路已验收。
