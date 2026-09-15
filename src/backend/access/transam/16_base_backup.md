# How: Base Backup

## 1. What & Why

Base backup：在线拷贝数据目录（及表空间），再配上备份窗口内的 WAL，恢复时靠 redo（含 FPI）把「不一致的文件拷贝」推到一致点。

- 问题：在线逐文件拷贝不是库级快照——各文件拷于不同时刻，对不齐同一 LSN；若拷时该页正在 flush，备份里还可能半写。
- 解法：备份会话期间强制拍 FPI（`runningBackups`）；从 `backup_label` 的 start LSN 起重放 WAL，用 FPI/增量把副本推齐。
- 边界：本稿讲与 FPW / `runningBackups` 的耦合；流复制持续 apply、增量 base backup 协议细节另篇。

> 稳定旧页、无并发写时：纯读文件得到的 8KB 与盘上一致，拷贝本身不会造半写。半写只来自「拷的同时该页正在被写」。FPI 解决这类并发半写；跨文件时间错位靠 start～stop 的 WAL 重放。

对照 [Full Page Writes](./13_full_page_writes.md)：crash recovery 防本机半写；base backup 防备份窗口内并发写造成的副本半写，并消化跨文件不一致。

---

## 2. 核心设计思想


|        | Crash recovery（`full_page_writes`）                     | Base backup（`runningBackups`）   |
| ------ | ------------------------------------------------------ | ------------------------------- |
| 触发     | GUC；按 checkpoint 周期 `page_lsn <= RedoRecPtr` 首次改页拍 FPI | 备份进行中强制 `doPageWrites`          |
| 保护对象   | 本机数据文件 + 本地 WAL                                        | 备份副本中的页 + 备份窗口 WAL              |
| 关闭 GUC | `full_page_writes=off` 可关（有风险）                         | `runningBackups > 0` 时仍必须拍 FPI  |
| 恢复入口   | Startup crash redo                                     | 恢复簇 + `backup_label` 指引的 WAL 区间 |


`doPageWrites`（写入侧本地缓存，权威在 `XLogCtl->Insert`）：

```c
doPageWrites = (Insert->fullPageWrites || Insert->runningBackups > 0);
/* 或等价：forcePageWrites || fullPageWrites；force 随 runningBackups 置位 */
```

一句话：有在线备份时，即使关掉 `full_page_writes`，WAL 仍必须带够 FPI，否则从该备份恢复时无法修好拷贝里的坏页。

---



## 3. 关键文件与 API


| 概念        | 源码 / 入口                                                                                         |
| --------- | ----------------------------------------------------------------------------------------------- |
| 备份开始 / 结束 | `xlog.c` — `do_pg_backup_start` / `do_pg_backup_stop`（SQL：`pg_backup_start` / `pg_backup_stop`） |
| 计数器       | `XLogCtl->Insert.runningBackups`；`lastBackupStart`                                              |
| 组装是否拍 FPI | `GetFullPageWriteInfo` → `XLogRecordAssemble` / `XLogCheckBufferNeedsBackup`（同 FPW）             |
| 复制协议拷贝    | `backup/basebackup*.c`；客户端 `pg_basebackup`                                                      |
| 恢复元数据     | 数据目录内 `backup_label`（及 `tablespace_map`）                                                        |


非独占备份（现行默认路径）：不写 exclusive lock 文件挡其它备份；可与 `pg_basebackup` 并发会话，每个会话 `runningBackups++`。

---



## 4. 时序

```text
pg_backup_start / BASE_BACKUP start
  -> (often) CHECKPOINT
  -> WALInsertLock; runningBackups++
  -> record start LSN  (backup start location)
copy PGDATA / tablespaces   // files may be torn or mutually inconsistent
pg_backup_stop
  -> record stop LSN
  -> runningBackups--
  -> need WAL [start .. stop]  (archive or stream with backup)
restore:
  place files + backup_label
  Startup recovery applies WAL until consistent  (FPI / incremental)
```

拷贝窗口内单页：可能是稳定旧/新镜像（字节完整），或并发 flush 下的半写。恢复不依赖「整库拷齐」，依赖 start 之后 WAL 里的 FPI/增量。

---



## 5. 与 FPW 判定的衔接

备份进行中 `doPageWrites == true`，之后与平常 FPW 相同：

```c
needs_backup = (PageGetLSN(page) <= RedoRecPtr);  /* 本周期首次修改 */
```


| 现象                            | 解释                                            |
| ----------------------------- | --------------------------------------------- |
| 备份期间 WAL 变胖                   | `runningBackups > 0` 强制 page writes；首次改页带 FPI |
| `full_page_writes=off` 仍见 FPI | 有未结束的 `pg_backup_*` / `pg_basebackup`         |
| 只拷文件、不留 WAL                   | 无法恢复到一致；缺 start～stop 的 WAL 会失败或损坏             |
| 与 crash redo 共用 `rm_redo`     | 恢复路径同一套；差别在是否有 `backup_label` / 恢复目标          |


`RedoRecPtr` 仍随 checkpoint 推进；备份不会改成「另一套 FPW 算法」，只是把 `doPageWrites` 钉死为开。

---



## 6. 运维对应（最小）

```sql
SELECT pg_backup_start('label', false);
-- 外部拷贝 $PGDATA
SELECT * FROM pg_backup_stop(true);

-- 或走 pg_basebackup，内部走复制协议
```

`pg_basebackup`：一次会话内完成 start → 流式拷文件 → 拉齐所需 WAL → stop，不必手写两段 SQL。

恢复：用备份目录启动，存在 `backup_label` 时按其中 start 位置进入恢复，直到备份结束点（及配置的 recovery target）一致。

---



## 7. 速查


| 问题                    | 答案                                           |
| --------------------- | -------------------------------------------- |
| base backup 解决什么？     | 跨文件时间错位 + 并发拷写时的半写；用 WAL+FPI 推齐              |
| 稳定旧页纯拷会半写吗？           | 不会；半写要有对该页的并发写                               |
| `runningBackups` 干什么？ | 计数在线备份；>0 则强制 `doPageWrites`                 |
| 和 `full_page_writes`？ | 或关系：GUC 开 **或** 备份中，都要拍 FPI                  |
| 为何对照 FPW？             | 同一套 `needs_backup` / FPI；动机从「本机半写」扩到「备份副本半写」 |
| 本稿不含？                 | 流复制位点持续 apply、slot、增量 base backup 报文细节       |
