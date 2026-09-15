# How: Crash Recovery Redo Path

## 1. What is Crash Recovery Redo

Crash recovery：实例非正常退出后，Startup 进程从最近一次 checkpoint 记下的 `CheckPoint.redo` 起，按序重放 WAL，直到本地 WAL 末尾（已 flush 的部分），把数据文件推回与 WAL 一致的状态。

本笔记只覆盖**本地崩溃恢复的 redo 主路径**。Archive recovery / PITR、流复制持续 apply、restartpoint 另篇。

---

## 2. 核心设计思想

- 问题：共享缓冲在进程死后作废；数据文件上的脏页可能未刷完，且可能停在任意 LSN。仅靠数据文件无法知道「缺了哪些已持久化的修改」。
- 解法：持久真相在已 flush 的 WAL。从 `redo` 点顺序 `rm_redo`；页上 `pd_lsn` 决定跳过或应用；有 FPI 则先整页覆盖。
- 边界：只保证 flush 到盘的 WAL；未 flush 的提交按 `synchronous_commit` 语义可能丢失。Redo 不「撤销」用户事务，未提交 XID 靠 MVCC / CLOG 不可见。

---

## 3. 关键文件与 API

| 概念                | 源码                                                                       |
| ------------------- | -------------------------------------------------------------------------- |
| Startup 进程入口    | `src/backend/postmaster/startup.c`                                         |
| 启动与控制文件      | `src/backend/access/transam/xlog.c` — `StartupXLOG`                        |
| 恢复主循环          | `src/backend/access/transam/xlogrecovery.c` — `PerformWalRecovery`         |
| 读缓冲 / 跳过 / FPI | `src/backend/access/transam/xlogutils.c` — `XLogReadBufferForRedoExtended` |
| 检查点记录          | `src/include/catalog/pg_control.h` — `CheckPoint`（含 `redo`）             |
| 资源管理器表        | `src/backend/access/rmgrdesc.c` / 各 `*xlog.c` — `rm_redo`                 |
| Heap / B-tree redo  | `heapam_xlog.c`、`nbtxlog.c` 等                                            |

控制文件里与起点相关的字段：

| 字段                | 含义                                                             |
| ------------------- | ---------------------------------------------------------------- |
| `CheckPoint.redo`   | 本次 checkpoint **开始时**的「下一条可写 LSN」；崩溃恢复从此读起 |
| `state`             | 如 `DB_SHUTDOWNED` / `DB_IN_CRASH_RECOVERY` / `DB_IN_PRODUCTION` |
| timeline / WAL 位置 | 决定打开哪条时间线、哪个 segment                                 |

---

## 4. 为何从 `redo` 起、而非从「上次刷脏」起

Checkpoint 并不保证「redo 点之后的脏页都已落盘」；它保证的是：

1. 写下一条 checkpoint WAL，并把控制文件里的 `redo` 指到该点（或该点附近约定位置）；
2. `redo` **之前**的修改，对应脏页会在 checkpoint 完成前刷到数据文件（或等价地可被后续逻辑覆盖）。

因此崩溃后：

```text
data files:  pages durable up to roughly last completed checkpoint
WAL:         flushed records from CheckPoint.redo .. EndOfWAL
replay:      apply that WAL range onto data files
```

`redo` 之后、崩溃之前已刷盘的页：页上 `pd_lsn` 已较新 → redo 时 `BLK_DONE`，不重复改。  
`redo` 之后未刷盘的页：靠 WAL（增量或 FPI）重建。

---

## 5. 启动到恢复结束的时序

```text
postmaster
  -> fork Startup
       -> StartupXLOG
            read ControlFile / last CheckPoint
            if clean shutdown (DB_SHUTDOWNED):
                 skip crash redo (or minimal validation)
            else:
                 enter crash recovery
                 PerformWalRecovery
                   loop:
                     ReadRecord
                     ApplyWalRecord
                       RmgrTable[rmid].rm_redo(record)
                   until end of available WAL
                 end-of-recovery checkpoint
            -> signal postmaster: recovery finished
  -> start normal backends
```

`PerformWalRecovery` 内对每条记录的处理骨架：

```text
record = ReadRecord(...)
rmid   = XLogRecGetRmid(record)
RmgrTable[rmid].rm_redo(record)
  // typical page-touching rm_redo:
  XLogReadBufferForRedo(record, block_id, &buf)
    -> BLK_RESTORED | BLK_DONE | BLK_NEEDS_REDO
  if NEEDS_REDO: apply incremental change; PageSetLSN; MarkBufferDirty
```

资源管理器按记录类型分发：`RM_HEAP_ID` → heap redo，`RM_BTREE_ID` → btree redo，checkpoint / clog / 等各有入口。一条 WAL 一个 atomic action，与 [Mini-Transaction](./12_mini_transaction.md) 一致。

---

## 6. 单页：何时跳过、何时套增量、何时整页覆盖

`XLogReadBufferForRedoExtended`（与 [Full Page Writes](./13_full_page_writes.md)、[LSN](./11_xlogrecptr_lsn.md) 对照）：

| 返回             | 条件                                    | 行为                         |
| ---------------- | --------------------------------------- | ---------------------------- |
| `BLK_RESTORED`   | 记录带须 APPLY 的 FPI                   | 整页覆盖，通常不再套本条增量 |
| `BLK_DONE`       | `record->EndRecPtr <= PageGetLSN(page)` | 页已含本条及更早修改，跳过   |
| `BLK_NEEDS_REDO` | 页旧于本条且无可用 FPI APPLY            | 在现有页上应用增量           |

```text
has FPI to APPLY?  --yes--> RestoreBlockImage -> BLK_RESTORED
        |
        no
        v
EndRecPtr <= page_lsn? --yes--> BLK_DONE
        |
        no
        v
BLK_NEEDS_REDO -> rm_redo incremental apply
```

半写页：若本周期曾拍 FPI，恢复时先覆盖再继续；这是 FPW 存在的直接消费者。

---

## 7. 与用户事务、可见性的关系

| 现象                                             | 解释                                                      |
| ------------------------------------------------ | --------------------------------------------------------- |
| 未 COMMIT 的修改出现在 redo 后的页上             | 物理 redo 不区分是否提交；可见性看 XID / CLOG / 快照      |
| COMMIT 已 `XLogFlush` 后崩溃                     | 对应 WAL 在盘上 → redo 后事务仍提交                       |
| `synchronous_commit=off` 且 COMMIT 未 flush 就崩 | 提交可能丢失；与 redo 路径无关，是持久边界问题            |
| 临界区内 PANIC                                   | 共享内存丢弃后走本路径；未记 WAL 的脏改不会进入 redo 输入 |

Crash recovery **不做**传统 undo 日志回滚堆元组；中止未完成事务靠事务状态与 MVCC。索引 incomplete split 等中间态由访问方法在后续插入时 lazy finish（见 MTR / nbtree）。

---

## 8. 结束条件与后续

Crash recovery 读到本地可提供的 WAL 末尾（通常受 Flush 边界约束）后结束，并做 **end-of-recovery checkpoint**，推进控制文件中的一致点，然后才允许普通后端进入。

与后续主题的划界：

| 主题                    | 与本稿差异                                                          |
| ----------------------- | ------------------------------------------------------------------- |
| Archive recovery / PITR | 还可读 archive；可在 `recovery_target_*` 停                         |
| Hot Standby / 流复制    | 同一套 `rm_redo`，但 WAL 由 walreceiver 持续供给；另有 restartpoint |
| Base backup             | 提供可 redo 的数据文件起点；不替代 redo 本身                        |

---

## 9. 速查

| 问题                   | 答案                                               |
| ---------------------- | -------------------------------------------------- |
| 从哪开始 redo？        | 控制文件里最近 checkpoint 的 `CheckPoint.redo`     |
| 谁跑恢复？             | Startup 进程：`StartupXLOG` → `PerformWalRecovery` |
| 一条记录怎么应用到页？ | `rm_redo` + `XLogReadBufferForRedo*`               |
| 为何有的记录不改页？   | `page_lsn` 已 ≥ 本条 `EndRecPtr`                   |
| FPI 在恢复里干什么？   | 整页覆盖，躲开半写 / 缺旧基线                      |
| 恢复完才能连库吗？     | 是；结束后 checkpoint，再放行正常后端              |

---

## 10. 总结

1. What：从 `CheckPoint.redo` 顺序重放已 flush WAL，经各 `rm_redo` 把数据文件补到与 WAL 一致。
2. Why：崩溃后共享缓冲与未刷脏页不可信；可依赖的是 WAL + 页 LSN / FPI。
3. How：`StartupXLOG` → `PerformWalRecovery` → ReadRecord → `rm_redo` → `BLK_RESTORED` / `DONE` / `NEEDS_REDO`。
4. 范围外：备库持续 apply、archive/PITR 目标点、base backup 引导。
