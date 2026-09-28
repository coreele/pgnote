# Table AM / Index AM API

**概要**：PostgreSQL 把「表 / 索引的物理实现」抽象成两组回调结构体 —— `TableAmRoutine` 与 `IndexAmRoutine`。relcache 打开关系时，经 `pg_am.amhandler` 调 handler 函数拿到结构体，缓存在 `Relation->rd_tableam` / `Relation->rd_indam`；上层（executor、commands、DDL、VACUUM、optimizer）只调 `table_*` / `index_*` 包装函数，由包装函数转发到 routine 里的函数指针。in-tree 的 table AM 只有 heap，index AM 有 btree / hash / gin / gist / spgist / brin。

源码：`include/access/tableam.h`、`include/access/amapi.h`、`backend/access/table/`、`backend/access/index/`。

## 1. 分层

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

## 2. routine 从哪来

`pg_class.relam` → `pg_am.amhandler`（regproc）、`pg_am.amtype`（`AMTYPE_TABLE 't'` / `AMTYPE_INDEX 'i'`）。

**Table**（`backend/access/table/`）：

- `table_open()`（table.c）→ `relation_open()` → relcache `RelationInitTableAccessMethod()`
- `InitTableAmRoutine()` → `rd_tableam = GetTableAmRoutine(rd_amhandler)`
- `GetTableAmRoutine()`（tableamapi.c）用 `OidFunctionCall0(amhandler)` 调 handler，并 Assert 必需回调齐全
- catalog / sequence 直接置 `F_HEAP_TABLEAM_HANDLER`，避免 syscache 查询

**Index**（`backend/access/index/`）：

- `index_open()`（indexam.c）→ relcache `InitIndexAmRoutine()`
- `GetIndexAmRoutine(rd_amhandler)` 取回后 memcpy 进 `rd_indexcxt`，存 `rd_indam`
- `GetIndexAmRoutineByAmId()`（amapi.c）先校验 `amtype == AMTYPE_INDEX`，再调 handler

## 3. `TableAmRoutine`（tableam.h:283）

| 分组        | 回调                                                                                                 | 说明                                    |
| ----------- | ---------------------------------------------------------------------------------------------------- | --------------------------------------- |
| slot        | `slot_callbacks`                                                                                     | 返回 `TupleTableSlotOps`，决定元组容器  |
| scan        | `scan_begin` / `scan_end` / `scan_rescan` / `scan_getnextslot`                                       | `TableScanDesc` 生命周期                |
| tid range   | `scan_set_tidrange` / `scan_getnextslot_tidrange`                                                    | 二者成对出现                            |
| 并行 scan   | `parallelscan_estimate` / `parallelscan_initialize` / `parallelscan_reinitialize`                    |                                         |
| index fetch | `index_fetch_begin` / `index_fetch_reset` / `index_fetch_end` / `index_fetch_tuple`                  | 索引 → 表回表                           |
| tuple 读    | `tuple_fetch_row_version` / `tuple_tid_valid` / `tuple_get_latest_tid` / `tuple_satisfies_snapshot` / `index_delete_tuples` | 非修改操作              |
| tuple 写    | `tuple_insert` / `multi_insert` / `tuple_insert_speculative` / `tuple_complete_speculative` / `tuple_delete` / `tuple_update` / `tuple_lock` / `finish_bulk_insert` | DML |
| DDL / 维护  | `relation_set_new_filelocator` / `relation_nontransactional_truncate` / `relation_copy_data` / `relation_copy_for_cluster` / `relation_vacuum` / `scan_analyze_next_block(tuple)` / `index_build_range_scan` / `index_validate_scan` | |
| 杂项        | `relation_size` / `relation_needs_toast_table` / `relation_toast_am` / `relation_fetch_toast_slice`  |                                         |
| planner     | `relation_estimate_size`                                                                             |                                         |
| executor    | `scan_bitmap_next_block(tuple)` / `scan_sample_next_block(tuple)`                                    |                                         |

heap 的填法见 `heapam_methods`（heapam_handler.c:2545），由 `heap_tableam_handler()` 返回。

## 4. `IndexAmRoutine`（amapi.h:210）

分两部分：能力 flags + 回调。

**能力 flags**（供 planner / DDL 判断，会经 `amproperty` 暴露为 SQL 属性）：

- 规模类：`amstrategies`（策略数）、`amsupport`（支持函数数）、`amoptsprocnum`（opclass 选项函数号）、`amkeytype`
- 布尔类：`amcanorder`、`amcanorderbyop`、`amcanbackward`、`amcanunique`、`amcanmulticol`、`amoptionalkey`、`amsearcharray`、`amsearchnulls`、`amstorage`、`amclusterable`、`ampredlocks`、`amcanparallel`、`amcaninclude`、`amusemaintenanceworkmem`、`amsummarizing`
- `amparallelvacuumoptions`

**回调**：

| 阶段        | 回调                                                                                    | 说明                          |
| ----------- | --------------------------------------------------------------------------------------- | ----------------------------- |
| 构建        | `ambuild` / `ambuildempty`                                                              | 建索引 / 建空索引             |
| 写入        | `aminsert`                                                                              | 插入一条索引项                |
| 清理        | `ambulkdelete` / `amvacuumcleanup`                                                      | VACUUM                        |
| 规划        | `amcostestimate`                                                                        | 代价估算                      |
| 选项 / 属性 | `amoptions` / `amproperty` / `ambuildphasename`                                         | 后两者可为 NULL               |
| opclass     | `amvalidate` / `amadjustmembers`                                                        | 校验 opclass / opfamily       |
| 扫描        | `ambeginscan` / `amrescan` / `amgettuple` / `amgetbitmap` / `amendscan` / `ammarkpos` / `amrestrpos` | `amgettuple` 与 `amgetbitmap` 至少一个 |
| 并行扫描    | `amestimateparallelscan` / `aminitparallelscan` / `amparallelrescan`                    |                               |

btree 的例子：`bthandler()`（nbtree.c:96）逐字段填好后返回。

## 5. 包装层如何转发

**Table 侧全部是 `static inline`**（tableam.h），例如：

```c
table_beginscan()          -> rel->rd_tableam->scan_begin(...)
table_scan_getnextslot()   -> ...->scan_getnextslot(...)
table_index_fetch_tuple()  -> ...->index_fetch_tuple(...)
table_tuple_insert()       -> ...->tuple_insert(...)
table_tuple_update/delete/lock()
```

**Index 侧**在 indexam.c / genam.c：

```c
index_insert()       -> rd_indam->aminsert(...)
index_beginscan()    -> rd_indam->ambeginscan(...)
index_getnext_tid()  -> rd_indam->amgettuple(...)
index_getbitmap()    -> rd_indam->amgetbitmap(...)
index_bulk_delete()  -> rd_indam->ambulkdelete(...)
index_build()        -> rd_indam->ambuild(...)          /* catalog/index.c */
```

## 6. 描述符结构：base class + AM 扩展

- 表扫描：`TableScanDescData`（relscan.h:31）—— `rs_rd` / `rs_snapshot` / `rs_nkeys` / `rs_key` / `rs_flags` / `rs_parallel` …；AM 把扩展字段（如 `HeapScanDescData`）**内嵌** base。并行用 `ParallelTableScanDescData`。
- 索引回表：`IndexFetchTableData`（relscan.h:104）只有一个 `rel`，AM 内嵌扩展。
- 索引扫描：`IndexScanDescData`（relscan.h:114），`ambeginscan` 返回 `IndexScanDesc`。

`table_index_fetch_tuple()` 与 `table_tuple_fetch_row_version()` 的区别：前者用于「索引项 → 表元组」，可能返回**当前可见的版本**（配合 HOT）；后者严格按给定 TID 取。

## 7. 一次索引扫描的路线

```text
index_beginscan  -> rd_indam->ambeginscan
index_getnext_slot
  loop:
    tid  = index_getnext_tid  -> rd_indam->amgettuple
    tuple = index_fetch_heap   -> rd_tableam->index_fetch_tuple  (可见性测试)
index_endscan    -> rd_indam->amendscan
```

bitmap 路径：`index_beginscan_bitmap` → `index_getbitmap` → `rd_indam->amgetbitmap`，再由执行器按 TID 回表。

DML 路线（以 UPDATE 为例）：执行器 `table_tuple_update()` → heapam（可能 HOT / HOT-chain）→ 返回 `TM_Result`，据此决定是否插入新索引项。

## 8. 注册与 SQL 接口

- catalog：`pg_am`（`amname`、`amhandler`、`amtype`），`CREATE ACCESS METHOD` 即插入一行。
- opclass 体系：`pg_opclass` / `pg_opfamily` / `pg_amop` / `pg_amproc`。
- 支持函数：`index_getprocinfo()`（indexam.c）按 `amsupport` 取 proc；opclass 选项走 `amoptsprocnum`。
- 校验：SQL 函数 `amvalidate()` → `GetIndexAmRoutineByAmId()` → `amroutine->amvalidate()`。

## 9. 小结

|                | Table AM                              | Index AM                            |
| -------------- | ------------------------------------- | ----------------------------------- |
| 接口结构       | `TableAmRoutine`                      | `IndexAmRoutine`                    |
| relcache 字段  | `rd_tableam`                          | `rd_indam`                          |
| 包装函数       | `table_*`                             | `index_*`                           |
| handler        | `heap_tableam_handler`                | `bthandler` / …                     |
| 描述符基类     | `TableScanDescData` / `IndexFetchTableData` | `IndexScanDescData`           |
| 元组容器       | `TupleTableSlotOps`（`slot_callbacks`） | —                                 |
| in-tree 实现   | heap                                  | btree / hash / gin / gist / spgist / brin |

关键源码：

- `include/access/tableam.h`、`backend/access/table/tableam.c`、`tableamapi.c`
- `include/access/amapi.h`、`backend/access/index/indexam.c`、`genam.c`、`amapi.c`
- handler：`backend/access/heap/heapam_handler.c`、各 index AM 的 `*handler`
