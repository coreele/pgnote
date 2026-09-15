# What & Why: XLogRecPtr (LSN)

## 1. What is LSN

**LSN**（Log Sequence Number）在源码里就是 `XLogRecPtr`：`typedef uint64 XLogRecPtr`，表示 WAL **字节流上的位置**（当前时间线上的偏移）。

显示格式（`LSN_FORMAT_ARGS`）：

```text
0/102BEB10  →  高 32 位 / 低 32 位，合起来一个 64 位偏移
```

`InvalidXLogRecPtr = 0` 表示无效位置。

---

## 2. 核心设计思想

- **统一坐标**：WAL 记录、数据页、checkpoint、复制、PITR 都用同一套 LSN 刻度
- **记录链**：每条 WAL 的 `xl_prev` 指向上一条的 **start**，顺序回放时校验链接
- **页版本戳**：`pd_lsn` 记下「最后一次改这页的 WAL 记录结束位置」，redo / FPW 都靠它比较
- **持久边界**：Insert → Write → Flush 三级指针，区分「已生成 / 已写内核 / 已落盘」

---

## 3. 关键文件与 API

| 概念       | 源码 / SQL                                                                                      |
| ---------- | ----------------------------------------------------------------------------------------------- |
| 类型定义   | `src/include/access/xlogdefs.h` — `XLogRecPtr`                                                  |
| 记录头     | `src/include/access/xlogrecord.h` — `xl_prev`                                                   |
| 页 LSN     | `src/include/storage/bufpage.h` — `pd_lsn` / `PageGetLSN` / `PageSetLSN`                        |
| 插入返回值 | `src/backend/access/transam/xloginsert.c` — `XLogInsert` → `EndPos`                             |
| 恢复起点   | `src/include/catalog/pg_control.h` — `CheckPoint.redo`                                          |
| 共享指针   | `src/backend/access/transam/xlog.c` — `GetRedoRecPtr` / `GetFlushRecPtr` / `GetXLogWriteRecPtr` |
| SQL 观测   | `src/backend/access/transam/xlogfuncs.c` — `pg_current_wal_*`                                   |

---

## 4. 三种 LSN 角色（先分清）

### 4.1 WAL 记录上的 LSN

一条记录在字节流上占 `[start, end)`：

| 字段 / 工具输出         | 含义                                                             |
| ----------------------- | ---------------------------------------------------------------- |
| `xl_prev`               | **上一条**记录的**开始位置**（`ReserveXLogInsertLocation` 写入） |
| `XLogInsert()` 返回值   | **本条**记录的结束位置（`EndRecPtr`）                            |
| `pg_waldump` 的 `lsn:`  | 本条记录的 **EndRecPtr**                                         |
| `pg_waldump` 的 `prev:` | 本条 `xl_prev` = 上一条记录的 **start**                          |

### 4.2 数据页上的 LSN（`page_lsn`）

页头 `pd_lsn` 注释（`bufpage.h`）：

> next byte after last byte of xlog record for last change to this page

即：**最后一次修改该页的 WAL 记录的 EndRecPtr**。

典型路径（`heap_insert`）：

```c
recptr = XLogInsert(...);
PageSetLSN(page, recptr);
```

`pageinspect` 里 `page_header.lsn` 应与对应 Heap WAL 记录的 `lsn` 一致（见 [pageinspect](../../../tools/01_pageinspect.md)、`traces/01_insert.md` 实验）。

### 4.3 系统级 LSN 指针

| 指针       | 获取函数                | 含义                                                                           |
| ---------- | ----------------------- | ------------------------------------------------------------------------------ |
| **Insert** | `GetXLogInsertRecPtr()` | WAL 已保留到的位置（**end+1**，下一条从这里插）；`pg_current_wal_insert_lsn()` |
| **Write**  | `GetXLogWriteRecPtr()`  | 已写入 OS 缓存；`pg_current_wal_lsn()`                                         |
| **Flush**  | `GetFlushRecPtr()`      | 已 `fsync` 到盘；`pg_current_wal_flush_lsn()`                                  |
| **Redo**   | `GetRedoRecPtr()`       | 当前 checkpoint 的恢复起点                                                     |

关系（正常主库，瞬时值可能有微小先后差）：

```text
Insert LSN  ≥  Write LSN  ≥  Flush LSN
```

`Insert` 领先 `Write`：后端已 `XLogInsert` 进共享缓冲，walwriter 尚未 `write()`。`Write` 领先 `Flush`：已 `write()` 进内核缓存，尚未 `fsync`（`synchronous_commit=off` 时 COMMIT 后常见）。

`COMMIT` 时 `XLogFlush(commit_lsn)` 推进 **Flush**，保证已提交事务的 WAL 可崩溃恢复。

`RedoRecPtr`（`CheckPoint.redo`）：最近一次 checkpoint **开始时**记下的「下一条可用 LSN」；崩溃恢复从此重放。也是 FPW 里 `page_lsn <= RedoRecPtr` 的参照点（见 [Full Page Writes](./13_full_page_writes.md)）。

---

## 5. 比较语义

### 5.1 Redo 跳过

`XLogReadBufferForRedoExtended`（`xlogutils.c`）：

```c
lsn = record->EndRecPtr;
if (lsn <= PageGetLSN(page))
    return BLK_DONE;   /* 页已包含本条及更早的修改 */
```

页上 LSN 是「已应用到的 WAL 位置」；当前记录结束位置不比页新 → 不必再 redo。

### 5.2 FPW 首次修改

```c
needs_backup = (PageGetLSN(page) <= RedoRecPtr);
```

页 LSN 还没越过本次 checkpoint 的 redo 点 → 本周期内首次 WAL 修改 → 附带 FPI。

---

## 6. 物理落点（简图）

WAL 按 **segment 文件**（`pg_wal/000000010000000000000001`）顺序追加；segment 内再按 **XLOG 页**（通常 8KB）切分。`XLogRecPtr` 是跨 segment 的全局字节偏移，`XLByteToSeg` 等宏负责换算文件名与段内偏移。

---

## 7. 实验（与 INSERT trace 衔接）

```sql
SELECT pg_current_wal_insert_lsn() AS insert_lsn,
       pg_current_wal_lsn()        AS write_lsn,
       pg_current_wal_flush_lsn()  AS flush_lsn;

-- 记下 insert_lsn 后
INSERT INTO tb VALUES (1);
COMMIT;

SELECT pg_current_wal_flush_lsn();  -- 应 ≥ insert_lsn

SELECT lsn FROM page_header(get_raw_page('tb', 0));  -- 与 pg_waldump 中 Heap 记录 lsn 对齐
```

```sh
pg_waldump -s <insert_lsn> -n 3
```

对照：`prev`（上条 start）→ `lsn`（本条 end+1）→ 页 `pd_lsn`（= 改页那条 WAL 的 end+1）。

---

## 8. 速查

| 问题                                   | 答案                                                    |
| -------------------------------------- | ------------------------------------------------------- |
| LSN 是什么类型？                       | `uint64` 字节偏移                                       |
| `xl_prev` 存什么？                     | 上一条记录的 **start**                                  |
| `page_lsn` / `pg_waldump lsn` 存什么？ | 本条 WAL 的 **end+1**（EndRecPtr）                      |
| `pg_current_wal_insert_lsn` 是什么？   | 全局最新 **end+1**（下一条插入位置）                    |
| 恢复从哪开始？                         | 最近 checkpoint 的 `redo` / `GetRedoRecPtr()`           |
| `pg_current_wal_lsn` 是刷盘了吗？      | **否**，只到 Write；刷盘看 `pg_current_wal_flush_lsn`   |
| 和事务提交的关系？                     | COMMIT 记录写入后 `XLogFlush`，把 Flush 推到 commit LSN |

---

## 9. 总结

1. **What**：`XLogRecPtr` = WAL 上的 64 位位置；对外常叫 LSN。
2. **Why**：同一刻度串联 WAL 链、页版本、恢复起点与复制位点。
3. **How**：改页 → `XLogInsert` 得 EndRecPtr → `PageSetLSN`；恢复 / FPW 用 `<=` 比较页 LSN 与记录 / redo 位置。
