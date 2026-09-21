# Page Prune

## 1. Overview

**Page prune**：在**单个 heap 页内部**回收已死元组、缩短 HOT 链、整理碎片。**不跨页，不碰索引**。

与 lazy `VACUUM` 共用 `heap_page_prune()`，但 opportunistic 路径条件更严、不做索引清理。

源码：`src/backend/access/heap/pruneheap.c`。

| 路径               | 入口                          | 锁                                     | 特点                    |
| ---------------- | --------------------------- | ------------------------------------- | --------------------- |
| **按需 prune**     | `heap_page_prune_opt()`     | 非阻塞 `ConditionalLockBufferForCleanup` | 读路径触发；页快满才做           |
| **VACUUM prune** | `heap_page_prune()`         | 已持 cleanup lock                       | 每页必做；用 `OldestXmin`   |
| **WAL replay**   | `heap_page_prune_execute()` | redo 路径                               | 应用 `XLOG_HEAP2_PRUNE` |

## 2. Entry

### 2.1. Optionally

**在读路径**访问某页时调用 `heap_page_prune_opt`.

按需 prune 的执行条件:

```text
1. !RecoveryInProgress()
2. pd_prune_xid is valid          // page may have prunable tuples
3. GlobalVis can remove prune_xid // xid is below OldestXmin (or old_snapshot_threshold)
4. page needs space:
     PageIsFull(page)
     OR PageGetHeapFreeSpace(page) < max(fillfactor target, BLCKSZ/10)
5. ConditionalLockBufferForCleanup succeeds
6. re-check condition 4 while holding the lock
```

设计意图（README.HOT）：只在页**几乎满**且**可能有 dead/HOT 链**时才修剪；页还空时不做，避免每次读都 prune。

拿不到 cleanup lock → **直接跳过**，不阻塞读/写。

### 2.2. VACUUM

`vacuumlazy.c` 扫描每页时**直接**调用，已持 cleanup lock，用 `vacrel->cutoffs.OldestXmin` 判断是否可清理，调用 prune 核心函数 `heap_page_prune`。

## 3. pd_prune_xid

页上**最早**「将来可 prune」的 XID。UPDATE/DELETE 在旧页留下 dead 候选时设置：

```c
PageSetPrunable(page, xid);   // heap_update / heap_delete · heapam.c
```

- 事务提交后，该 xid 低于 `OldestXmin` 时 tuple 才可 prune
- 事务 abort → 后续 prune 是 no-op，hint 会被清掉
- `pd_prune_xid == InvalidTransactionId` → `heap_page_prune_opt` 立刻返回

## 4. Process

`heap_page_prune()` 流程：

1. 对每个 slot 预计算 `HeapTupleSatisfiesVacuum`（HTSV）
2. 按 HOT 链调用 `heap_prune_chain()`，计划：
   - `LP_REDIRECT`：缩短链，索引仍指向 root
   - `LP_DEAD`：有索引指向、暂不能复用 slot（等 VACUUM 清索引）
   - `LP_UNUSED`：heap-only 死 tuple，slot 可复用
3. 临界区内 `heap_page_prune_execute()` + `PageRepairFragmentation()`
4. 更新 `pd_prune_xid`、`PageClearFull`
5. 写 WAL：`XLOG_HEAP2_PRUNE`

## 5. Function

| 函数                          | 作用                                     |
| --------------------------- | -------------------------------------- |
| `heap_page_prune_opt()`     | 检查 hint + 视界 + 空闲启发式；非阻塞拿 cleanup lock |
| `heap_page_prune()`         | 扫描页、规划 HOT 链变更、写 WAL                   |
| `heap_page_prune_execute()` | 应用 redirect/dead/unused + 碎片整理         |
| `heap_prune_chain()`        | 单条 HOT 链的 prune 逻辑                     |
| `PageRepairFragmentation()` | 紧凑页内空闲区（`bufpage.c`）                   |

## 6. Case

### 6.1 `heap_page_prune_opt`

```sql
DROP TABLE IF EXISTS test_prune;

CREATE TABLE test_prune (id int PRIMARY KEY, val text)
  WITH (autovacuum_enabled = off, fillfactor = 100);

INSERT INTO test_prune SELECT i, repeat('a', 200) FROM generate_series(1, 30) i;

-- HOT 更新，产生 dead heap-only tuple（不增索引项）
UPDATE test_prune SET val = repeat('b', 200) WHERE id <= 20;

-- 确保 UPDATE 的 xid 低于 GlobalVis  horizon
BEGIN; SELECT 1; COMMIT;

-- Seq Scan 读到该页且页空闲 < fillfactor 阈值时触发 heap_page_prune_opt
SELECT count(*) FROM test_prune;
```

页仍很空时，`heap_page_prune_opt` 通常**只检查 hint、不 prune**；要强制观察可再 UPDATE 把页填满，或跑 `VACUUM`。

### 6.2 VACUUM

```sql
DROP TABLE IF EXISTS test_prune;

CREATE TABLE test_prune (id int PRIMARY KEY, val int)
WITH (autovacuum_enabled = off, fillfactor = 100);

INSERT INTO test_prune values (1, 1), (2, 2), (3, 3);

-- HOT 更新，产生 dead heap-only tuple（不增索引项）
UPDATE test_prune SET val = val * 10 WHERE id = 2;

DELETE from test_prune where id = 3;

VACUUM test_prune;   -- 每页直接 heap_page_prune，不依赖 PageIsFull
```

### 6.3 Call Stack

```c
ExecVacuum | vacuum
    vacuum_rel | table_relation_vacuum
        heap_vacuum_rel | lazy_scan_heap | lazy_scan_prune
            heap_page_prune /* Prune and repair fragmentation in the specified page. */
	            heap_prune_chain /* Process this item or chain of items */
	            heap_page_prune_execute /* Perform the actual page changes needed by heap_page_prune */
		            ItemIdSetRedirect /* Update all redirected line pointers */
		            ItemIdSetDead     /* Update all now-dead line pointers */
		            ItemIdSetUnused   /* Update all now-unused line pointers */
		            PageRepairFragmentation /* bufpage.c */
			            compactify_tuples   /* bufpage.c */
	            PageClearFull
	            XLogInsert(RM_HEAP2_ID, XLOG_HEAP2_PRUNE);
```
