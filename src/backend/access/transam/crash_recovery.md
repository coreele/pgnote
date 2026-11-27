# crash recovery

`CHECKPOINT` → `INSERT` + `COMMIT` → `kill -9` → 重启 Startup redo。机制见 [15_crash_recovery_redo](./15_crash_recovery_redo.md)；写路径见 [insert](../heap/insert.md)。仅本地 crash recovery。

## 时序

```text
t0  CHECKPOINT              -> CheckPoint.redo = R
t1  INSERT                  -> Heap INSERT WAL; page dirty in buffers
t2  COMMIT + XLogFlush      -> COMMIT WAL on disk
t3  kill -9 postmaster      -> no DB_SHUTDOWNED; buffers gone
t4  restart                 -> StartupXLOG -> PerformWalRecovery (R .. EndOfWAL)
```

崩溃后可信的是已 flush 的 WAL；堆文件页可能仍旧。

## 调用栈

```cpp
StartupXLOG                          /* access/transam/xlog.c */
  PerformWalRecovery                 /* access/transam/xlogrecovery.c */
    ReadRecord
    ApplyWalRecord
      RmgrTable[rmid].rm_redo
        // Heap INSERT:
        heap_xlog_insert             /* access/heap/heapam_xlog.c */
          XLogReadBufferForRedo*     /* -> BLK_RESTORED|DONE|NEEDS_REDO */
        // Transaction COMMIT:
        xact_redo_commit             /* access/transam/xact.c */
  // end-of-recovery checkpoint
```

本场景常见：未刷脏 → `BLK_NEEDS_REDO`；崩溃前已 `CHECKPOINT`/刷页 → `BLK_DONE`；带 FPI APPLY → `BLK_RESTORED`。分支条件见 [15_crash_recovery_redo](./15_crash_recovery_redo.md) §4。

## 实验

```sql
DROP TABLE IF EXISTS tb;
CREATE TABLE tb(a int);
CHECKPOINT;
SELECT pg_current_wal_insert_lsn() AS redo_anchor;
INSERT INTO tb VALUES (1);
COMMIT;
-- 立刻 kill -9 postmaster（勿 pg_ctl stop）
-- 重启后: SELECT * FROM tb;  -- 应仍有行
```

```sh
pg_waldump -s <redo_anchor> -n 20 -p $PGDATA/pg_wal
# Heap INSERT ... then Transaction COMMIT ...
```

要稳定打到 `NEEDS_REDO`：提交后立刻杀，别再等刷脏。对照 `DONE`：提交后再 `CHECKPOINT` 再杀。

## gdb

redo 在 Startup，不在 postmaster / backend。需 `-g` 构建（[Compile](../../../meta/compile.md)）。

造数（可选）attach backend：`break heap_insert` / `XLogFlush`，跑完上节 SQL 后 `kill -9` postmaster。

跟 Startup：

```sh
gdb --args /path/to/postgres -D $PGDATA
```

```text
(gdb) break StartupXLOG
(gdb) break PerformWalRecovery
(gdb) break XLogReadBufferForRedoExtended
(gdb) break heap_xlog_insert
(gdb) set follow-fork-mode child
(gdb) set detach-on-fork on
(gdb) run
```

fork 到无关进程时 `continue` 直到 `StartupXLOG`，或 `info inferiors` / `inferior <n>`。在 `XLogReadBufferForRedoExtended` 返回处看 `BLK_*`。

Startup 太快时：在 `PerformWalRecovery` 入口临时 `pg_usleep(30 * 1000000L);`，`pg_ctl start` 后 `gdb -p` 到 `postgres: startup`，调完删 sleep。

约束：必须非正常退出才进 crash redo；backend 造数与 Startup redo 分两次 gdb。
