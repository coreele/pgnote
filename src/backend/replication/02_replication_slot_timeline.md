# What: Replication Slot & Timeline

## 1. What & Why

两个正交概念，一起决定「WAL 能不能被下游持续消费、升主后还能不能接上」：

| 概念 | 是什么 | 解决什么问题 |
| ---- | ------ | ------------ |
| **Replication slot** | 主库上持久化的「消费者预订」 | 下游还没读到的 WAL（及逻辑解码所需 catalog 行）别被回收 |
| **Timeline** | WAL 历史的**分支编号**（`TimeLineID`） | 升主 / PITR 后出现分叉时，知道该跟哪条历史、哪段 WAL |

- 问题：checkpoint / 回收会删旧 WAL；逻辑解码还依赖旧 catalog 行。无预订则备库或解码客户端一断连就可能「段已删」。升主后新旧主各写各的 WAL，仅靠 LSN 不够区分历史。
- 解法：slot 钉住最小保留位点；timeline + `*.history` 描述分支与父子关系，恢复/复制按历史拼路径。
- 边界：本稿讲 **What**（语义与字段）；slot 失效策略细节、级联复制、failover slot 同步（如 `pg_sync_replication_slots`）不展开。

接上一课：[Streaming Replication & Log Decoding](./01_streaming_replication.md) 里「为何常和 slot 一起」「升主」在此落地。

---

## 2. 核心设计思想

### 2.1 Slot = 持久化的消费游标 + 保留约束

```text
下游进度反馈 / 解码确认
        |
        v
  ReplicationSlot  (pg_replslot/<name>/)
        |
        +--> restart_lsn      : 回收不得越过（物理/逻辑重启点）
        +--> confirmed_flush  : 逻辑侧「已确认交付」位点（推进更积极）
        +--> catalog_xmin     : 逻辑侧：系统表 vacuum 不得越过
```

一句话：slot 把「某个消费者还需要的最老 WAL / catalog」写进主库元数据，checkpoint 与 vacuum 都要看它。

### 2.2 Timeline = WAL 字节流的命名空间

```text
timeline 1:  ....----A----B----C
                          \
timeline 2:                ----D----E   (promote / PITR 开新支)
```

同一数值的 LSN 可以出现在不同 timeline 上（分叉后各自推进）。因此「从某 LSN 追 WAL」必须带上 **TimeLineID**（以及必要时读 history 找祖先段）。

### 2.3 二者如何配合

| 场景 | Slot | Timeline |
| ---- | ---- | -------- |
| 正常流复制 | 物理 slot 钉 `restart_lsn`，备库断连也可重连续传 | 主备同 timeline |
| 逻辑解码 / 逻辑复制 | 逻辑 slot 钉 WAL + `catalog_xmin` | 通常仍在同一 timeline 读主库 WAL |
| 备库 promote | 旧主上的 slot **不会自动**变新主的；需新拓扑重建或同步机制 | **新主开新 timeline**；旧主若仍在跑则成平行历史 |
| Archive / PITR | 一般不靠 slot；靠归档保留 | `recovery_target_timeline` + history 决定跟哪支 |

---

## 3. 关键文件与 API

| 概念 | 源码 / SQL |
| ---- | ---------- |
| Slot 核心 | `src/backend/replication/slot.c`、`slot.h` — `ReplicationSlot*` |
| 持久化目录 | `$PGDATA/pg_replslot/<slotname>/`（state 文件） |
| 物理建槽 | `pg_create_physical_replication_slot`；复制协议 `CREATE_REPLICATION_SLOT ... PHYSICAL` |
| 逻辑建槽 | `pg_create_logical_replication_slot`；`CREATE_REPLICATION_SLOT ... LOGICAL` |
| 观测 | `pg_replication_slots` |
| Timeline 类型 | `TimeLineID`（`xlogdefs.h` 等） |
| History 读写 | `src/backend/access/transam/timeline.c` — `*.history` |
| 恢复跟线 | `xlogrecovery.c` — `recovery_target_timeline`、切换 / 校验 |
| 控制文件 | `pg_control` 中当前 `timeline` / checkpoint 相关字段 |
| WAL 文件名 | `TTTTTTTTXXXXXXXXYYYYYYYY`（timeline + 逻辑段号） |

配置相关：`max_replication_slots`、`max_wal_senders`、`max_slot_wal_keep_size`（可限制槽位无限囤积 WAL；触顶可使槽失效）、`wal_level`。

---

## 4. Replication Slot

### 4.1 物理 vs 逻辑

| | Physical | Logical |
| --- | -------- | ------- |
| 消费者 | 流复制备库（walsender 按槽续传） | 逻辑解码客户端 / 逻辑复制 |
| 钉住什么 | 主要是 WAL（`restart_lsn`） | WAL + 解码重启所需状态 + 常含 `catalog_xmin` |
| `wal_level` | `replica` 即可 | 要 `logical` |
| 典型用途 | HA 备库不断档 | CDC、`pgoutput`、审计 |

物理槽可与 `primary_slot_name`（备库）绑定，让主库按该备的反馈推进保留位点。

### 4.2 关键位点（逻辑槽尤甚）

| 字段（概念名） | 含义 |
| -------------- | ---- |
| `restart_lsn` | 下游若要从头「安全重启」所需的最老 WAL 位置；**回收下限** |
| `confirmed_flush_lsn` | 消费者已确认处理到的位置；逻辑侧常据此推进，可比 `restart_lsn` 新 |
| `catalog_xmin` | 逻辑解码仍可能需要的系统表行的 xmin 下界；挡住过早 vacuum |
| `xmin`（若暴露） | 与快照 / 水平相关的保留（随版本与槽类型关注点不同） |

推进规则直觉：

```text
消费者确认进度 → 更新 confirmed_flush（等）
                → 在安全时抬高 restart_lsn
                → 更老的 WAL 段才允许被删
```

滞后的槽 → `pg_wal` 膨胀；删槽或修好消费者后才会释放。

### 4.3 生命周期（最小）

```text
create slot  →  占用 max_replication_slots 配额，写入 pg_replslot/
active       →  walsender / 解码会话占用（pg_replication_slots.active）
inactive     →  仍保留 WAL；断连不等于丢槽
drop / 失效  →  释放保留；max_slot_wal_keep_size 等可令槽 invalid
```

**易踩坑**：只建槽不消费、或备库长期宕机 → 主库磁盘被 WAL 撑满。运维上要监控 `restart_lsn` 与磁盘，并理解 `max_slot_wal_keep_size` 是「宁可槽失效也不塞爆盘」的权衡。

---

## 5. Timeline

### 5.1 什么时候分叉

| 事件 | 行为 |
| ---- | ---- |
| 备库 **promote** 成主 | 新主切换到新 `TimeLineID`，写出 history，之后 WAL 写在新线上 |
| **PITR** 恢复到某目标后以新主身份跑 | 同样进入新 timeline，避免与「原主若仍存活」的历史混淆 |
| 普通 crash recovery（同实例重启） | **通常不换** timeline，继续原线 |

### 5.2 History 文件

形如 `00000002.history`（内容随版本为文本行）：记录「本 timeline 从哪条父线、在哪个 LSN 分出」。

恢复 / 追归档时：若目标 LSN 落在父线段，需按 history **回溯父 timeline** 打开正确的 WAL 文件名（同 offset、不同 `TTTTTTTT` 前缀）。

### 5.3 与复制、升主

```text
1. 主(TLI=1) ----WAL----> 备(TLI=1)  redo
2. 备 promote → 新主(TLI=2)，写 00000002.history
3. 旧主若仍接受写入 → 仍在 TLI=1 上前进（脑裂风险；运维上应 fence）
4. 其他备要跟新主：改连新主，并按 timeline history 衔接 WAL
```

流复制握手会交换 / 校验 timeline；对不上就无法简单「同一 LSN 接着传」。

---

## 6. 与 streaming / backup / redo 的衔接

| 机制 | 角色 |
| ---- | ---- |
| [Crash redo](../access/transam/15_crash_recovery_redo.md) | 本地、通常单 timeline、有终点 |
| [Base backup](../access/transam/16_base_backup.md) | 文件起点；`backup_label` 含 start 点（含 timeline 语境） |
| [Streaming](./01_streaming_replication.md) | 持续喂 WAL；物理槽降低「段已删」概率 |
| Slot | 主库侧保留契约 |
| Timeline | 升主 / PITR 后的历史坐标系 |

备库 `restartpoint` 推进本地可回收位点；**主库**是否删段还要看所有 slot 的 `restart_lsn`（以及 `wal_keep_size` 等）。

---

## 7. 易混点

| 说法 | 澄清 |
| ---- | ---- |
| Slot = 备库上的对象 | **否**；槽建在**提供 WAL 的那一侧**（通常是主库） |
| 有 `wal_keep_size` 就不用 slot | `wal_keep_size` 是粗粒度多留一段；slot 按**消费者进度**精确保留，逻辑解码还要 `catalog_xmin` |
| LSN 全局唯一跨升主 | LSN 是线上的字节偏移；**跨 timeline 必须带 TLI**，不能只比数字 |
| Promote 后旧主 slot 自动跟上 | **不会**；拓扑变了要重建或专用同步手段 |
| 逻辑槽只挡 WAL | 还常挡 catalog vacuum；忽略会导致解码失败或槽增长 |

---

## 8. 速查

| 问题 | 答案 |
| ---- | ---- |
| Slot 解决什么？ | 钉住下游仍需的 WAL（及逻辑 catalog），防回收 |
| 物理 / 逻辑槽差别？ | 逻辑额外要 `wal_level=logical` 与解码相关保留 |
| `restart_lsn` 是什么？ | 槽的回收下界 / 安全重启点 |
| Timeline 解决什么？ | WAL 历史分叉后的命名与追溯 |
| 何时新 timeline？ | Promote、PITR 开新主写等 |
| History 干什么？ | 记录父线与分叉 LSN，供恢复拼路径 |
| 本稿不含 | 失效抢修流程、槽同步升主、级联、具体报文格式 |

---

## 9. 总结

1. **Slot**：主库上的持久消费者预订 → 保留 WAL（逻辑再加 catalog）→ 支撑断连续传与解码。
2. **Timeline**：WAL 历史的分支 ID + history → 升主/PITR 后仍能找到正确段。
3. **合起来**：流复制日常靠 slot 保段；拓扑变更靠 timeline 保「跟对历史」。
