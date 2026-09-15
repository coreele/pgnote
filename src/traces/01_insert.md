# insert

![](../backend/storage/assets/insert.svg)

- 调试语句：`insert into tb values(1)`
- insert 核心流程梳理，将从最简单的插入数据开始，逐步讨论事务、锁、资源管理等相关内容
- 调试语句：`insert into tb values(1)`

## 概览

```cpp
start_xact_command
pg_parse_query
pg_analyze_and_rewrite_fixedparams
pg_plan_queries
PortalDefineQuery
PortalRun | PortalRunMulti | ProcessQuery /* tcop */
EndCommand
finish_xact_command
```

## `ProcessQuery`

```cpp
/* ... */
pg_plan_queries
CreatePortal
PortalDefineQuery
PortalStart
PortalRun | PortalRunMulti | ProcessQuery /* tcop */
    CreateQueryDesc
    ExecutorStart
    ExecutorRun | standard_ExecutorRun | ExecutePlan | ExecProcNode | ExecProcNodeFirst /* executor */
        ExecModifyTable | ExecInsert /* executor */
            table_tuple_insert       /* access/tableam.h call Relation::TableAmRoutine::tuple_insert */
                heapam_tuple_insert  /* access/heap/heapam_handler.c */
                    heap_insert      /* access/heap/heapam.c */
                        RelationGetBufferForTuple /* access/heap/hio.c */
                        RelationPutHeapTuple      /* access/heap/hio.c */
                            PageAddItemExtended   /* storage/page/bufpage.c */
                        MarkBufferDirty(buffer)   /* storage/buffer/bufmgr.c */
                        XLogInsert /* access/transam/xloginsert.c */
                            XLogRecordAssemble
                            XLogInsertRecord
                        PageSetLSN
    ExecutorFinish
PortalDrop
EndCommand
finish_xact_command
```

## `CommitTransaction`

```cpp
start_xact_command
pg_parse_query
pg_analyze_and_rewrite_fixedparams
pg_plan_queries
CreatePortal
PortalDefineQuery
PortalStart
PortalRun | PortalRunMulti | ProcessQuery /* tcop */
PortalDrop
EndCommand
finish_xact_command
    CommitTransactionCommand
        CommitTransaction
            s->state = TRANS_COMMIT;
            RecordTransactionCommit
                XactLogCommitRecord
                    XLogInsert
                XLogFlush /* wal -> disk */
                TransactionIdCommitTree
                    TransactionIdSetTreeStatus
                        TransactionIdSetPageStatus
                            TransactionIdSetPageStatusInternal
            s->state = TRANS_DEFAULT;
    xact_started = false;
```

## call stack

```cpp
start_xact_command
    StartTransactionCommand
        StartTransaction
            s->state = TRANS_START;
            /* initialize current transaction state fields */
            /* ... */
            s->state = TRANS_INPROGRESS;
    xact_started = true;
pg_parse_query
pg_analyze_and_rewrite_fixedparams
pg_plan_queries
CreatePortal
PortalDefineQuery
PortalStart
PortalRun | PortalRunMulti | ProcessQuery /* tcop */
    CreateQueryDesc
    ExecutorStart
    ExecutorRun | standard_ExecutorRun | ExecutePlan | ExecProcNode | ExecProcNodeFirst /* executor */
        ExecModifyTable | ExecInsert /* executor */
            table_tuple_insert       /* access/tableam.h call Relation::TableAmRoutine::tuple_insert */
                heapam_tuple_insert  /* access/heap/heapam_handler.c */
                    heap_insert      /* access/heap/heapam.c */
                        RelationGetBufferForTuple /* access/heap/hio.c */
                        RelationPutHeapTuple      /* access/heap/hio.c */
                            PageAddItemExtended   /* storage/page/bufpage.c */
                        MarkBufferDirty(buffer)   /* storage/buffer/bufmgr.c */
                        XLogInsert /* access/transam/xloginsert.c */
                            XLogRecordAssemble
                            XLogInsertRecord
                        PageSetLSN
    ExecutorFinish
PortalDrop
EndCommand
finish_xact_command
    CommitTransactionCommand
        CommitTransaction
            s->state = TRANS_COMMIT;
            RecordTransactionCommit
                XactLogCommitRecord
                    XLogInsert
                XLogFlush /* wal -> disk */
                TransactionIdCommitTree
                    TransactionIdSetTreeStatus
                        TransactionIdSetPageStatus
                            TransactionIdSetPageStatusInternal
            s->state = TRANS_DEFAULT;
    xact_started = false;
```

## Hint Bits

依赖扩展: [`pageinspect`](../tools/01_pageinspect.md): 用于直接查看页面和元组信息

```sql
drop table if exists tb;
create table tb(a int);
```

关闭自动提交并插入数据

```sql
\set AUTOCOMMIT off
insert into tb values (1);
```

插入后不提交，此时新开一个 psql 客户端无法查询到 tb 中的数据，但是使用 pageinspect 工具可以看到已经有记录已经占据了页面空间，upper 为 8160

```sql
select from tb;
(0 rows)

select * from page_header(get_raw_page('tb', 0));
+-----------+----------+-------+-------+-------+---------+----------+---------+-----------+
|    lsn    | checksum | flags | lower | upper | special | pagesize | version | prune_xid |
+-----------+----------+-------+-------+-------+---------+----------+---------+-----------+
| 0/2A5EB38 |        0 |     0 |    28 |  8160 |    8192 |     8192 |       4 |         0 |
+-----------+----------+-------+-------+-------+---------+----------+---------+-----------+
(1 row)
```

此时 t_xmin 表示插入数据的事务 id

```sql
select lp, lp_off, lp_flags, lp_len, t_xmin, t_xmax, t_field3, t_ctid, t_infomask from heap_page_items(get_raw_page('tb', 0));
+----+--------+----------+--------+--------+--------+----------+--------+------------+
| lp | lp_off | lp_flags | lp_len | t_xmin | t_xmax | t_field3 | t_ctid | t_infomask |
+----+--------+----------+--------+--------+--------+----------+--------+------------+
|  1 |   8160 |        1 |     28 |   1228 |      0 |        0 | (0,1)  |       2048 |
+----+--------+----------+--------+--------+--------+----------+--------+------------+
```

`lp`: 行指针序号
`lp_off`: 页面内物理偏移量
`lp_flags`: 状态标记(1: LP_NORMAL， 2: REDIRECT, 3: DEAD, 0: UNUSED)
`lp_len`: 元组长度。这行数据（含头+数据+对齐）总共占用了 28 字节，实际存储占用 32 字节（8 字节对齐）
`t_xmin`: 插入事务 ID。表示这个元组是由事务号为 1228 的操作创建的
`t_xmax`: 删除/锁定事务 ID。0 表示该行目前是“活的”，尚未被删除或更新
`t_field3`: 命令 ID (t_cid)。表示这是事务 1228 里的第几个命令（从 0 开始计数）
`t_ctid`: 物理指针, 指向最新版本
`t_infomask`: 状态信息， `HEAP_XMAX_INVALID`

此时执行提交

```sql
commit;
```

再次使用 heap_page_items 发现 `t_infomask` 无变化

```sql
select lp, lp_off, lp_flags, lp_len, t_xmin, t_xmax, t_field3, t_ctid, t_infomask from heap_page_items(get_raw_page('tb', 0));
+----+--------+----------+--------+--------+--------+----------+--------+------------+
| lp | lp_off | lp_flags | lp_len | t_xmin | t_xmax | t_field3 | t_ctid | t_infomask |
+----+--------+----------+--------+--------+--------+----------+--------+------------+
|  1 |   8160 |        1 |     28 |   1228 |      0 |        0 | (0,1)  |       2048 |
+----+--------+----------+--------+--------+--------+----------+--------+------------+
```

另启客户端访问一下 tb

```sql
select from tb;
```

```sql
select lp, lp_off, lp_flags, lp_len, t_xmin, t_xmax, t_field3, t_ctid, t_infomask from heap_page_items(get_raw_page('tb', 0));
+----+--------+----------+--------+--------+--------+----------+--------+------------+
| lp | lp_off | lp_flags | lp_len | t_xmin | t_xmax | t_field3 | t_ctid | t_infomask |
+----+--------+----------+--------+--------+--------+----------+--------+------------+
|  1 |   8160 |        1 |     28 |   1228 |      0 |        0 | (0,1)  |       2304 |
+----+--------+----------+--------+--------+--------+----------+--------+------------+
```

再次使用 `heap_page_items` 发现 `t_infomask` 变为 2304 = 2048 + 256 = `HEAP_XMIN_COMMITTED` + `HEAP_XMAX_INVALID`

解释：基于 Hint Bits 的延迟状态更新

Hint Bits 是 CLOG 的缓存，提交/回滚时不改数据页，首次访问时再回填。

| 阶段     | 动作                     | 页上 `t_infomask`                    |
| -------- | ------------------------ | ------------------------------------ |
| COMMIT   | 只写 WAL + CLOG          | `XMIN_COMMITTED` 仍为 0              |
| 首次访问 | 查 CLOG → Buffer 设 hint | 置 `HEAP_XMIN_COMMITTED`             |
| ROLLBACK | 不改页                   | 后续置 `HEAP_XMIN_INVALID`，行不可见 |

目的：提交轻量，避免为 hint 同步刷大量数据页。

## WAL 日志

```sql
DROP TABLE IF EXISTS tb;

CREATE TABLE tb(a int);

\set AUTOCOMMIT off

SELECT pg_current_wal_insert_lsn() AS lsn_before;
 lsn_before
------------
 0/102BEB10
(1 row)

INSERT INTO tb VALUES (1);

SELECT pg_current_wal_insert_lsn() AS lsn_after;   -- INSERT 后 lsn 已前进
 lsn_after
------------
 0/102BEB50
(1 row)

SELECT lsn FROM page_header(get_raw_page('tb', 0)); -- 页 lsn 对应 heap WAL
    lsn
------------
 0/102BEB50
(1 row)

COMMIT;
```

```sh
# 从 lsn_before 起读 WAL（替换为实际值）
bin> pg_waldump -s 0/102BEB10 -n 10 -p ~/pgdata/pg_wal
rmgr: Heap        len (rec/tot):     59/    59, tx:       1608, lsn: 0/102BEB10, prev 0/102BE968, desc: INSERT+INIT off: 1, flags: 0x00, blkref #0: rel 1663/5/91165 blk 0
rmgr: Transaction len (rec/tot):     34/    34, tx:       1608, lsn: 0/102BEB50, prev 0/102BEB10, desc: COMMIT 2026-07-15 21:15:04.305921 CST
rmgr: Standby     len (rec/tot):     50/    50, tx:          0, lsn: 0/102BEB78, prev 0/102BEB50, desc: RUNNING_XACTS nextXid 1609 latestCompletedXid 1608 oldestRunningXid 1609
```
