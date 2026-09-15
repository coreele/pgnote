# How: Streaming Replication & Log Decoding

## 1. What & Why

两条把 WAL「送出去」的路径，消费方式不同：

| 路径                                | 传什么                       | 备端 / 下游怎么用                                           |
| ----------------------------------- | ---------------------------- | ----------------------------------------------------------- |
| Streaming replication（物理流复制） | 物理 WAL 字节流              | 同一套 `rm_redo` 持续 apply，得到页级副本                   |
| Log decoding（逻辑解码）            | 仍读物理 WAL，解码成逻辑变更 | 输出插件变成 INSERT/UPDATE/DELETE 等逻辑流（逻辑复制、CDC） |

- 问题：crash recovery / base backup 是「一段 WAL 用完即止」；HA 与持续同步需要**不断**把主库新 WAL 送到另一进程/节点。
- 解法：物理路径用 walsender → walreceiver → Startup redo；逻辑路径用 decoding 读 WAL → ReorderBuffer → output plugin。
- 边界：slot / timeline 见 [Replication Slot & Timeline](./02_replication_slot_timeline.md)；本稿先钉进程、LSN 位点与两条路径的对照。

物理流复制通常先有一份 [Base Backup](../access/transam/16_base_backup.md)，再从 backup stop（或指定 LSN）起追 WAL。逻辑解码不要求备库有整份数据文件镜像，但要求有能读到的 WAL（及常配合 replication slot）。

---

## 2. 核心设计思想

### 2.1 物理流复制

```text
primary                          standby
  backends -> WAL insert/flush
  walsender  ---- WAL bytes ---->  walreceiver
                                      |
                                      v
                                 Startup / redo
                                 (same rm_redo as crash recovery)
```

|            | Crash recovery             | Streaming (physical)                                   |
| ---------- | -------------------------- | ------------------------------------------------------ |
| WAL 从哪来 | 本地 `pg_wal`（已 flush）  | walreceiver 写入的 WAL，再 redo                        |
| 何时停     | 本地 WAL 末尾              | 不停；主库持续推送                                     |
| 检查点     | end-of-recovery checkpoint | 备库 **restartpoint**（类 checkpoint，推进可清理位点） |
| 读查询     | 恢复结束前不可用           | Hot Standby：redo 同时可开只读会话                     |

一句话：流复制 = 「永不结束的 crash redo」，WAL 由网络持续供给，而不是只读本地文件到 EOF。

### 2.2 逻辑解码

```text
WAL (physical records)
  -> Logical decoding
       reorder by XID / commit order
       output plugin  ->  logical change stream
```

|                    | 物理 apply（`rm_redo`）               | 逻辑解码                               |
| ------------------ | ------------------------------------- | -------------------------------------- |
| 单位               | 页 / 块变更                           | 行级 / 事务级逻辑变更                  |
| 是否改本地数据文件 | 是（备库页）                          | 解码本身只产出变更流；逻辑订阅端另说   |
| 典型用途           | 热备、物理 HA                         | 逻辑复制、CDC、审计                    |
| 与 FPW             | 备库 apply 依赖主库 WAL 中的 FPI/增量 | 解码关注堆变更语义；仍读同一条物理 WAL |

---

## 3. 关键文件与 API

| 概念             | 源码 / 入口                                                              |
| ---------------- | ------------------------------------------------------------------------ |
| 主库发送         | `replication/walsender.c` — walsender                                    |
| 备库接收         | `replication/walreceiver.c` — walreceiver                                |
| 持续 redo        | `access/transam/xlogrecovery.c` — `PerformWalRecovery`（恢复模式不退出） |
| 复制连接         | 复制协议（`START_REPLICATION` 等）；`primary_conninfo`                   |
| 逻辑解码         | `replication/logical/` — `decode.c`、`logical.c`、`reorderbuffer.c`      |
| 输出插件         | `pgoutput`（内置逻辑复制）等                                             |
| SQL 入口（解码） | `pg_logical_slot_get_changes` / 逻辑复制 publication·subscription        |

配置侧常见：`wal_level >= replica`（物理）；逻辑解码 / 逻辑复制要 `wal_level = logical`。

---

## 4. 时序：物理流复制

```text
1. standby = base backup (+ backup_label) of primary
2. configure recovery / standby.signal, primary_conninfo
3. start standby
     Startup enters recovery
     walreceiver connects to primary
4. primary forks walsender
     streams WAL from requested LSN
5. walreceiver writes WAL locally
     Startup ReadRecord / rm_redo  (continuous)
6. optional: Hot Standby backends read consistent snapshots
7. promote: stop receiving, finish recovery, become primary
```

位点（名字随版本略有差异，语义如下）：

| 位点           | 含义                               |
| -------------- | ---------------------------------- |
| send / write   | 主库已发给 / 备库已写入的 WAL 位置 |
| flush          | 备库已持久化到盘的 WAL             |
| apply / replay | Startup 已 redo 到的位置           |

Lag ≈ 主库 flush LSN − 备库 apply LSN（还受网络与 redo 速度影响）。

---

## 5. 时序：逻辑解码（最小）

```text
create logical slot  (pin WAL from restart_lsn)
client / apply worker asks for changes
  -> read WAL from slot position
  -> decode heap/xact records
  -> ReorderBuffer until commit
  -> output plugin emits change
advance slot confirmed_flush
```

未提交事务的变更会在 ReorderBuffer 中暂存，**按提交顺序**输出。槽位钉住 WAL，防止 `restart_lsn` 之前的段被回收（细节见 [Replication Slot & Timeline](./02_replication_slot_timeline.md)）。

---

## 6. 与 crash redo / base backup 的衔接

| 机制                                                          | 角色                                        |
| ------------------------------------------------------------- | ------------------------------------------- |
| [Crash redo](../access/transam/15_crash_recovery_redo.md)     | 单机、本地 WAL、有终点                      |
| [Base backup](../access/transam/16_base_backup.md)            | 给物理备库（或 PITR）一个可 redo 的文件起点 |
| Streaming（物理）                                             | 起点之后持续喂 WAL + 同一套 `rm_redo`       |
| Log decoding                                                  | 同一条 WAL 的另一条消费管道；不替代物理 apply |

备库上的 restartpoint：在持续恢复中周期性做「像 checkpoint 一样」的落点，便于推进可回收 WAL / 缩短再次启动时的重放量；不是主库那种结束恢复的 end-of-recovery checkpoint。

---

## 7. 易混点

| 说法                               | 澄清                                           |
| ---------------------------------- | ---------------------------------------------- |
| 流复制 = 拷贝数据文件              | 否；文件靠 base backup（或等价），之后只流 WAL |
| 逻辑解码 = 另一套 WAL 格式         | 否；读物理 WAL，解码成逻辑变更                 |
| Hot Standby 与逻辑复制             | 前者是物理备上只读；后者是逻辑变更订阅，可异构 |
| `wal_level = replica` 够逻辑复制吗 | 不够；逻辑解码需要 `logical`                   |

---

## 8. 速查

| 问题               | 答案                                          |
| ------------------ | --------------------------------------------- |
| 物理流复制解决什么 | 持续页级副本 / HA；redo 不停                  |
| 谁发送、谁接收     | walsender → walreceiver → Startup redo        |
| 和 crash redo 差别 | WAL 来源与是否结束；`rm_redo` 相同            |
| 逻辑解码解决什么   | 从物理 WAL 抽出逻辑变更流                     |
| 为何常和 slot 一起 | 钉住 WAL，避免解码所需段被删                  |
| 本稿不含           | slot 生命周期、timeline history、级联复制细节（→ [02](./02_replication_slot_timeline.md)） |
