# Lazy Vacuum

参考资料: [https://pgint.vonng.com/ch6/](https://pgint.vonng.com/ch6/) | 英文原版：[https://www.interdb.jp/pg/pgsql06/index.html](https://www.interdb.jp/pg/pgsql06/index.html)

- 删除死元组（对象: 不可见的元组）
- 冻结事务标识（对象: 可见的元组，避免事务 ID 回绕）
## 1. dead tuple

- delete
- update
	- cold: delete + insert
	- hot: delete(redirect) + insert
## 2. line pointer

LP 的四种状态

```c
/*
 * lp_flags has these possible states.  An UNUSED line pointer is available
 * for immediate re-use, the other states are not.
 */
#define LP_UNUSED		0		/* unused (should always have lp_len=0) */
#define LP_NORMAL		1		/* used (should always have lp_len>0) */
#define LP_REDIRECT	    2		/* HOT redirect (should have lp_len=0) */
#define LP_DEAD			3		/* dead, may or may not have storage */
```

普通 / cold 旧版本: UNUSED → NORMAL [→ DEAD] → UNUSED
HOT 根（对外 TID）: UNUSED → NORMAL → REDIRECT [→ DEAD] → UNUSED
HOT 中间（HEAP_ONLY）: UNUSED → NORMAL → UNUSED

VACUUM 合法顺序：

1. 遍历 heap 标 `LP_DEAD`（保留编号、禁止复用；元组体可已由 prune 回收）：收集待清除的 tuple tid
2. 遍历 index 删除 1 收集的 tids 对应的索引项
3. heap 中 LP 改为 `LP_UNUSED` 允许 LP 复用

WHY: 为什么必须按照 `heap -> index -> heap` 的顺序处理，而不是直接处理 `index -> heap` 或者 `heap -> index`？

> 1. 如果 heap -> index 顺序直接清理 tuple 标记为 LP_UNUNSED，并发场景该 tuple 空间可能被复用，导致 index 指向非法数据
> 2. 如果 index -> heap 顺序首先清理 index 同时清理其对应的可能已经失效的 tuple，逐个回表检查是否 DEAD 处理效率太低


## 3. `visibility`

VACUUM 不以当前会话快照为准，而要求元组对**所有仍可能引用它的快照**均不可见。

回收地平线由 ProcArray 计算：`ComputeXidHorizons` / `GetOldestXmin`（见 [transam README](../transam/00_readme.md)）：

- 已提交的 `xmax` **严格小于** `OldestXmin` → 可回收。
- 未结束事务、复制槽、预备事务会推迟该地平线，扫描后仍无法回收。

判定函数为 `HeapTupleSatisfiesVacuum`（`heapam_visibility.c`），而非查询路径的 `HeapTupleSatisfiesMVCC`。

```c
/* Result codes for HeapTupleSatisfiesVacuum */
typedef enum
{
	HEAPTUPLE_DEAD,				/* tuple is dead and deletable */
	HEAPTUPLE_LIVE,				/* tuple is live (committed, no deleter) */
	HEAPTUPLE_RECENTLY_DEAD,	/* tuple is dead, but not deletable yet */
	HEAPTUPLE_INSERT_IN_PROGRESS,	/* inserting xact is still in progress */
	HEAPTUPLE_DELETE_IN_PROGRESS	/* deleting xact is still in progress */
} HTSV_Result;
```

## 4. VM

```
lazy_scan_skip
	visibilitymap_get_status
```

## 5. VACUUM

```
vacuum
	prune | 页面修剪 | 收集tid并剪枝不可见元组 
	vacuum index | 根据tid清理索引
	vacuum heap | 清理不可见元组
```

## 6. Call stack

```c
ExecVacuum | vacuum /* vacuum relations or all releated tables */
    vacuum_rel
        /* or cluster_rel for vacuum full */
        table_relation_vacuum | heap_vacuum_rel /* perform VACUUM for one heap relation */
            lazy_scan_heap      /* heap pruning + index vac + heap vac */
                lazy_scan_prune /* prune heap pages */
                    heap_page_prune /* prune one page */
                        heap_prune_satisfies_vacuum /* tuple visibility checks */
                        heap_prune_chain /* process all line pointer */
                        heap_page_prune_execute
                            ItemIdSetRedirect /* Update all redirected line pointers */
	        	            ItemIdSetDead     /* Update all now-dead line pointers */
	        	            ItemIdSetUnused   /* Update all now-unused line pointers */
	        	            PageRepairFragmentation
	        		            compactify_tuples
                        PageClearFull
                        MarkBufferDirty
                        XLogInsert(RM_HEAP2_ID, XLOG_HEAP2_PRUNE)
                    heap_prepare_freeze_tuple
                    heap_freeze_execute_prepared /* freeze heap tuples */
                        heap_execute_freeze_tuple /* Execute the prepared freezing of a tuple with caller's freeze plan */
                        MarkBufferDirty
                        XLogInsert(RM_HEAP2_ID, XLOG_HEAP2_FREEZE_PAGE);
                lazy_vacuum     /* index vacuuming */
                    lazy_vacuum_all_indexes
                        lazy_vacuum_one_index | vac_bulkdel_one_index /* vacuum index relation */
                            index_bulk_delete | IndexAmRoutine::ambulkdelete
                                btbulkdelete /* nbtree.c */
                    lazy_vacuum_heap_rel /* LP_DEAD -> LP_UNUSED */
                        lazy_vacuum_heap_page
                            ItemIdSetUnused
                            PageTruncateLinePointerArray
                            MarkBufferDirty
                            XLogInsert(RM_HEAP2_ID, XLOG_HEAP2_VACUUM);
            lazy_truncate_heap
            vac_update_relstats /* update stats */
    vac_update_datfrozenxid
```

核心
- `lazy_scan_heap`: 按块号扫描堆，通过 `heap_page_prune` 回收元组空间收集 TID（仍被索引引用的元组标记为 LP_DEAD），更新 VM 和 FSM
- `lazy_vacuum_all_indexes`: 对每个索引调用 `ambulkdelete`（nbtree 扫描叶页，删除 `ctid ∈ 死 TID 集` 的项）
- `lazy_vacuum_heap_rel`: 再次访问含死 TID 的堆页，将对应 `LP_DEAD` 改为 `LP_UNUSED`(slot 可复用)


收尾
- `lazy_cleanup_all_indexes`：`ambulkvacuumcleanup`（b-tree 回收空页、更新 `reltuples`）。
- `lazy_truncate_heap`：表尾连续空页时缩小文件；并发扫描可能导致截断放弃。文件中部空洞不会消失。
- `vac_update_relstats`：写入 `pg_class` / `pgstat`。

## 7. freeze

元组冻结见 [Freeze](./04_freeze.md)。

```c
heap_prepare_freeze_tuple
heap_freeze_execute_prepared /* freeze heap tuples */
	heap_execute_freeze_tuple /* Execute the prepared freezing of a tuple with caller's freeze plan */
	MarkBufferDirty
	XLogInsert(RM_HEAP2_ID, XLOG_HEAP2_FREEZE_PAGE);
```

## 8. Case

关闭表级 autovacuum，避免 worker 在观测前完成 prune / vacuum。

```sql
CREATE EXTENSION IF NOT EXISTS pageinspect;

DROP TABLE IF EXISTS tb;
CREATE TABLE tb (a int PRIMARY KEY, b int) WITH (autovacuum_enabled = off);

-- three kinds of dead tuples in one page
INSERT INTO tb VALUES (1, 10), (2, 20), (3, 30);
DELETE FROM tb WHERE a = 1;        -- (1) plain delete
UPDATE tb SET a = 22 WHERE a = 2;  -- (2) cold update: indexed column changed
UPDATE tb SET b = 33 WHERE a = 3;  -- (3) hot update: non-indexed column only

-- before VACUUM: lp 1-3 dead, lp 4-5 live
SELECT lp, lp_flags, t_xmin, t_xmax, t_ctid
FROM heap_page_items(get_raw_page('tb', 0));

-- 4 entries: a=1,2,3,22
SELECT itemoffset, ctid FROM bt_page_items('tb_pkey', 1);

VACUUM FREEZE VERBOSE tb;

-- after VACUUM: changes on lp 1-3
SELECT lp, lp_off, lp_flags
FROM heap_page_items(get_raw_page('tb', 0));

-- only a=3, a=22 remain
SELECT itemoffset, ctid FROM bt_page_items('tb_pkey', 1);
```
