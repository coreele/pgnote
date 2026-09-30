# amroutine

## AmRoutine

- PostgreSQL 把表/索引的物理实现抽象成两组回调结构体 —— `TableAmRoutine` 与 `IndexAmRoutine`。
- relcache 打开关系时，经 `pg_am.amhandler` 调 handler 函数拿到结构体，缓存在 `Relation->rd_tableam` / `Relation->rd_indam`；
- 上层（executor、commands、DDL、VACUUM、optimizer）只调 `table_*` / `index_*` 包装函数，由包装函数转发到 routine 里的函数指针
- in-tree 的 table AM 只有 heap，index AM 有: btree/hash/ gin/gist/spgist/brin。

```sql
postgres=# select * from pg_am;
  oid  | amname  |      amhandler       | amtype
-------+---------+----------------------+--------
     2 | heap    | heap_tableam_handler | t
   403 | btree   | bthandler            | i
   405 | hash    | hashhandler          | i
   783 | gist    | gisthandler          | i
  2742 | gin     | ginhandler           | i
  4000 | spgist  | spghandler           | i
  3580 | brin    | brinhandler          | i
 49730 | ivfflat | ivfflathandler       | i
 49732 | hnsw    | hnswhandler          | i
(9 rows)
```

源码：`include/access/tableam.h`、`include/access/amapi.h`、`backend/access/table/`、`backend/access/index/`。

## 分层

```text
executor / commands / DDL / VACUUM / optimizer
        │  table_*()                       │  index_*()
        ▼                                  ▼
   Relation->rd_tableam            Relation->rd_indam        ← relcache 缓存
        │                                  │
        ▼                                  ▼
   TableAmRoutine                   IndexAmRoutine           ← handler 返回的 vtable
        │                                  │
   heapam_handler.c                 bthandler / hashhandler / ...
        │                                  │
   heapam.c / vacuumlazy.c ...      nbtree.c / hash.c / ...
```

要点：上层**从不**直接调 `heap_insert` / `btgettuple`，只经过 `table_*` / `index_*` 转发。

## 查询

`pg_class.relam` → `pg_am.amhandler`（regproc）、`pg_am.amtype`（`AMTYPE_TABLE 't'` / `AMTYPE_INDEX 'i'`）。


```c
RelationInitTableAccessMethod
	SearchSysCache1(AMOID, rd_rel->relam) /* query pg_am.amhandler */
	InitTableAmRoutine
		GetTableAmRoutine
			OidFunctionCall0(rd_amhandler) → 调 handler 函数
				heap_tableam_handler
					return TableAmRoutine heapam_methods
```


## `TableAmRoutine`

> tableam.h:288

| 分组        | 回调                                                                                                                                                                                                                                 | 说明                                   |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------- |
| slot        | `slot_callbacks`                                                                                                                                                                                                                     | 返回 `TupleTableSlotOps`，决定元组容器 |
| scan        | `scan_begin` / `scan_end` / `scan_rescan` / `scan_getnextslot`                                                                                                                                                                       | `TableScanDesc` 生命周期               |
| tid range   | `scan_set_tidrange` / `scan_getnextslot_tidrange`                                                                                                                                                                                    | 二者成对出现                           |
| 并行 scan   | `parallelscan_estimate` / `parallelscan_initialize` / `parallelscan_reinitialize`                                                                                                                                                    |                                        |
| index fetch | `index_fetch_begin` / `index_fetch_reset` / `index_fetch_end` / `index_fetch_tuple`                                                                                                                                                  | 索引 → 表回表                          |
| tuple 读    | `tuple_fetch_row_version` / `tuple_tid_valid` / `tuple_get_latest_tid` / `tuple_satisfies_snapshot` / `index_delete_tuples`                                                                                                          | 非修改操作                             |
| tuple 写    | `tuple_insert` / `multi_insert` / `tuple_insert_speculative` / `tuple_complete_speculative` / `tuple_delete` / `tuple_update` / `tuple_lock` / `finish_bulk_insert`                                                                  | DML                                    |
| DDL / 维护  | `relation_set_new_filelocator` / `relation_nontransactional_truncate` / `relation_copy_data` / `relation_copy_for_cluster` / `relation_vacuum` / `scan_analyze_next_block(tuple)` / `index_build_range_scan` / `index_validate_scan` |                                        |
| 杂项        | `relation_size` / `relation_needs_toast_table` / `relation_toast_am` / `relation_fetch_toast_slice`                                                                                                                                  |                                        |
| planner     | `relation_estimate_size`                                                                                                                                                                                                             |                                        |
| executor    | `scan_bitmap_next_block(tuple)` / `scan_sample_next_block(tuple)`                                                                                                                                                                    |                                        |

heap 的填法见 `heapam_methods`（heapam_handler.c:2545），由 `heap_tableam_handler()` 返回。

## `IndexAmRoutine`

> amapi.h:210

分两部分：能力 flags + 回调。

**能力 flags**（供 planner / DDL 判断，会经 `amproperty` 暴露为 SQL 属性）：

- 规模类：`amstrategies`（策略数）、`amsupport`（支持函数数）、`amoptsprocnum`（opclass 选项函数号）、`amkeytype`
- 布尔类：`amcanorder`、`amcanorderbyop`、`amcanbackward`、`amcanunique`、`amcanmulticol`、`amoptionalkey`、`amsearcharray`、`amsearchnulls`、`amstorage`、`amclusterable`、`ampredlocks`、`amcanparallel`、`amcaninclude`、`amusemaintenanceworkmem`、`amsummarizing`
- `amparallelvacuumoptions`

**回调**：

| 阶段        | 回调                                                                                                 | 说明                                   |
| ----------- | ---------------------------------------------------------------------------------------------------- | -------------------------------------- |
| 构建        | `ambuild` / `ambuildempty`                                                                           | 建索引 / 建空索引                      |
| 写入        | `aminsert`                                                                                           | 插入一条索引项                         |
| 清理        | `ambulkdelete` / `amvacuumcleanup`                                                                   | VACUUM                                 |
| 规划        | `amcostestimate`                                                                                     | 代价估算                               |
| 选项 / 属性 | `amoptions` / `amproperty` / `ambuildphasename`                                                      | 后两者可为 NULL                        |
| opclass     | `amvalidate` / `amadjustmembers`                                                                     | 校验 opclass / opfamily                |
| 扫描        | `ambeginscan` / `amrescan` / `amgettuple` / `amgetbitmap` / `amendscan` / `ammarkpos` / `amrestrpos` | `amgettuple` 与 `amgetbitmap` 至少一个 |
| 并行扫描    | `amestimateparallelscan` / `aminitparallelscan` / `amparallelrescan`                                 |                                        |

btree 的例子：`bthandler()`（nbtree.c:96）逐字段填好后返回。

## 索引扫描

```text
index_beginscan  -> rd_indam->ambeginscan
index_getnext_slot
  loop:
    tid  = index_getnext_tid  -> rd_indam->amgettuple
    tuple = index_fetch_heap   -> rd_tableam->index_fetch_tuple  (可见性测试)
index_endscan    -> rd_indam->amendscan
```

## 注册

```sql
CREATE ACCESS METHOD duckdb
    TYPE TABLE
    HANDLER duckdb._am_handler;

CREATE ACCESS METHOD orioledb TYPE TABLE
HANDLER orioledb_tableam_handler;

CREATE ACCESS METHOD hnsw TYPE INDEX HANDLER hnswhandler;
CREATE ACCESS METHOD ivfflat TYPE INDEX HANDLER ivfflathandler;
```

除 in-tree 实现外，扩展同样通过 `CREATE ACCESS METHOD` 注册自定义 AM：

- [orioledb](https://github.com/orioledb/orioledb/blob/3eb704e78be72a1825625e027fcedcee671d361b/sql/orioledb--1.0_prod.sql#L14)：table AM（`TYPE TABLE`），用 undo log 实现 MVCC，替代 heap 的就地更新，缓解表膨胀并降低 WAL 开销。
- [pg_duckdb](https://github.com/duckdb/pg_duckdb/blob/ee38d3b540ecea1d93683ba99bdcec5632a21eaf/sql/pg_duckdb--1.0.0.sql#L138)：table AM（`TYPE TABLE），底层接入 DuckDB 的列式存储，面向 AP/OLAP 分析场景。
- [pgvector](https://github.com/pgvector/pgvector/blob/468fc77093e4d92596dab5d0943633fc8eef24e1/sql/vector.sql#L355-L364)：index AM（`TYPE INDEX`），注册 `ivfflat` / `hnsw` 两种索引，为向量类型提供近似最近邻检索，即开头 `pg_am` 中的 `ivfflat` / `hnsw` 两行。

## 小结

| 项目          | Table AM                                    | Index AM                                  |
| ------------- | ------------------------------------------- | ----------------------------------------- |
| 接口结构      | `TableAmRoutine`                            | `IndexAmRoutine`                          |
| relcache 字段 | `rd_tableam`                                | `rd_indam`                                |
| 包装函数      | `table_*`                                   | `index_*`                                 |
| handler       | `heap_tableam_handler`                      | `bthandler` / …                           |
| 描述符基类    | `TableScanDescData` / `IndexFetchTableData` | `IndexScanDescData`                       |
| 元组容器      | `TupleTableSlotOps`（`slot_callbacks`）     | —                                         |
| 实现          | heap(in-tree) / duckdb                      | btree / hash / gin / gist / spgist / brin |
