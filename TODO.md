# TODO

## meta

| number | topic           | study | share | review | where                                |
| ------ | --------------- | ----- | ----- | ------ | ------------------------------------ |
| 1      | Architecture    | ok    | ok    |        | [00_arch](src/meta/00_arch.md)       |
| 2      | Code Structure  | ok    | ok    |        | [01_code](src/meta/01_code.md)       |
| 3      | Compile & Debug | ok    | ok    |        | [02_compile](src/meta/02_compile.md) |
| 4      | Boot            | ok    | ok    |        | [03_boot](src/meta/03_boot.md)       |

## arch

| number | topic                     | study | share | review | where |
| ------ | ------------------------- | ----- | ----- | ------ | ----- |
| 1      | Process-based Model       | ok    | ok    |        |       |
| 2      | DSA                       |       |       |        |       |
| 3      | Aux Processes             |       |       |        |       |
| 4      | Shared Memory & ProcArray |       |       |        |       |

## tcop

| number | topic                   | study | share | review | where                                          |
| ------ | ----------------------- | ----- | ----- | ------ | ---------------------------------------------- |
| 1      | Traffic Cop             | ok    | ok    |        | [00_overview](src/backend/tcop/00_overview.md) |
| 2      | Simple query protocol   | ok    | ok    |        |                                                |
| 3      | Extended query protocol |       |       |        |                                                |

## parser

| number | topic           | study | share | review | where                                            |
| ------ | --------------- | ----- | ----- | ------ | ------------------------------------------------ |
| 1      | Parser Overview | ok    | ok    |        | [00_overview](src/backend/parser/00_overview.md) |
| 2      | Flex & Bison    |       |       |        |                                                  |

## analyzer

| number | topic                                | study | share | review | where                                          |
| ------ | ------------------------------------ | ----- | ----- | ------ | ---------------------------------------------- |
| 1      | Analyze Overview                     | ok    | ok    |        | [01_analyze](src/backend/parser/01_analyze.md) |
| 2      | expr                                 |       |       |        |                                                |
| 3      | func call                            |       |       |        |                                                |
| 4      | pg_type / Typmod / Type OID          |       |       |        |                                                |
| 5      | Type Coercion & Casts (pg_cast)      |       |       |        |                                                |
| 6      | Function / Operator Type Resolution  |       |       |        |                                                |
| 7      | Polymorphism (anyelement / anyarray) |       |       |        |                                                |
| 8      | Collation                            |       |       |        |                                                |

## rewriter

| number | topic                | study | share | review | where |
| ------ | -------------------- | ----- | ----- | ------ | ----- |
| 1      | Rewriter Overview    |       |       |        |       |
| 2      | View Expansion       |       |       |        |       |
| 3      | Rule Rewrite         |       |       |        |       |
| 4      | RLS Policy Injection |       |       |        |       |

## optimizer

| number | topic                                         | study | share | review | where                                               |
| ------ | --------------------------------------------- | ----- | ----- | ------ | --------------------------------------------------- |
| 1      | Optimizer Overview                            | ok    | ok    |        | [00_overview](src/backend/optimizer/00_overview.md) |
| 2      | Planner & Path Generation                     |       |       |        |                                                     |
| 3      | Join Order                                    |       |       |        |                                                     |
| 4      | Path to Plan Conversion                       |       |       |        |                                                     |
| 5      | Costing & Statistics (ANALYZE / pg_statistic) |       |       |        |                                                     |
| 6      | Partition Pruning                             |       |       |        |                                                     |

## executor

| number | topic                                        | study | share | review | where                                              |
| ------ | -------------------------------------------- | ----- | ----- | ------ | -------------------------------------------------- |
| 1      | Executor Overview                            | ok    | ok    |        | [00_overview](src/backend/executor/00_overview.md) |
| 2      | Demand-Driven Pipeline                       | ok    | ok    |        | [01_pipeline](src/backend/executor/01_pipeline.md) |
| 3      | Executor / Portal State                      | ok    | ok    |        | [02_state](src/backend/executor/02_state.md)       |
| 4      | TupleTableSlot                               | ok    | ok    |        |                                                    |
| 5      | Materialize & Sort                           |       |       |        |                                                    |
| 6      | Join Nodes (NestLoop / HashJoin / MergeJoin) |       |       |        |                                                    |
| 7      | Agg / HashAgg / Window                       |       |       |        |                                                    |

## transaction

| number | topic                               | study | share | review | where                                                                  |
| ------ | ----------------------------------- | ----- | ----- | ------ | ---------------------------------------------------------------------- |
| 1      | Transaction Overview                | ok    | ok    |        | [01_overview](src/backend/access/transam/01_overview.md)               |
| 2      | Transaction Process                 | ok    | ok    |        | [02_process](src/backend/access/transam/02_process.md)                 |
| 3      | Transaction State                   | ok    | ok    |        | [03_state](src/backend/access/transam/03_state.md)                     |
| 4      | Virtual XID                         | ok    | ok    |        | [04_vxid](src/backend/access/transam/04_vxid.md)                       |
| 5      | XID                                 | ok    | ok    |        | [05_xid](src/backend/access/transam/05_xid.md)                         |
| 6      | Isolation                           | ok    | ok    |        | [06_iso](src/backend/access/transam/06_iso.md)                         |
| 7      | MVCC Snapshot                       | ok    | ok    |        | [07_mvcc_snapshot](src/backend/access/transam/07_mvcc_snapshot.md)     |
| 8      | MVCC Visibility                     | ok    | ok    |        | [08_mvcc_visibility](src/backend/access/transam/08_mvcc_visibility.md) |
| 9      | CLOG                                | ok    | ok    |        | [09_clog](src/backend/access/transam/09_clog.md)                       |
| 10     | Non-overwrite MVCC                  | ok    | ok    |        | [00_readme](src/backend/access/transam/00_readme.md)                   |
| 11     | MultiXact                           |       |       |        |                                                                        |
| 12     | Subtrans / SAVEPOINT                |       |       |        |                                                                        |
| 13     | XID Wraparound & Freeze             |       |       |        |                                                                        |
| 14     | SSI (Serializable / Predicate Lock) |       |       |        |                                                                        |
| 15     | Two-Phase Commit                    |       |       |        |                                                                        |

## lmgr

| number | topic                                  | study | share | review | where                                                                                                     |
| ------ | -------------------------------------- | ----- | ----- | ------ | --------------------------------------------------------------------------------------------------------- |
| 1      | Lock Overview                          |       |       |        | [01_overview](src/backend/storage/lmgr/01_overview.md)                                                    |
| 2      | Tuple Lock (UPDATE / DELETE path)      |       |       |        | [tuplock](src/backend/access/heap/00_README.tuplock.md) · [update](src/backend/storage/lmgr/02_update.md) |
| 3      | LWLock vs SpinLock vs Heavyweight Lock | ok    | ok    |        | [01_overview](src/backend/storage/lmgr/01_overview.md)                                                    |
| 4      | Deadlock Detector                      |       |       |        |                                                                                                           |

## wal

| number | topic                            | study | share | review | where                                                                          |
| ------ | -------------------------------- | ----- | ----- | ------ | ------------------------------------------------------------------------------ |
| 1      | WAL Recovery / Failure Domains   | ok    | ok    |        | [14_wal_recovery](src/backend/access/transam/14_wal_recovery.md)               |
| 2      | WAL Record Structure & Insertion | ok    | ok    |        | [10_wal_record_insert](src/backend/access/transam/10_wal_record_insert.md)     |
| 3      | Full Page Writes                 | ok    | ok    |        | [13_full_page_writes](src/backend/access/transam/13_full_page_writes.md)       |
| 4      | XLogRecPtr (LSN)                 | ok    | ok    |        | [11_xlogrecptr_lsn](src/backend/access/transam/11_xlogrecptr_lsn.md)           |
| 5      | Mini-Transaction                 | ok    | ok    |        | [12_mini_transaction](src/backend/access/transam/12_mini_transaction.md)       |
| 6      | Crash Recovery Redo Path         | ok    | ok    |        | [15_crash_recovery_redo](src/backend/access/transam/15_crash_recovery_redo.md) |
| 7      | Base Backup                      | ok    | ok    |        | [16_base_backup](src/backend/access/transam/16_base_backup.md)                 |

## replication

| number | topic                                | study | share | review | where                                                                       |
| ------ | ------------------------------------ | ----- | ----- | ------ | --------------------------------------------------------------------------- |
| 1      | Streaming Replication & Log Decoding | ok    | ok    |        | [01_streaming](src/backend/replication/01_streaming_replication.md)         |
| 2      | Replication Slot & Timeline          | ok    | ok    |        | [02_slot_timeline](src/backend/replication/02_replication_slot_timeline.md) |

## access

| number | topic                               | study | share | review | where                                                     |
| ------ | ----------------------------------- | ----- | ----- | ------ | --------------------------------------------------------- |
| 1      | Heap AM Overview                    |       |       |        | [heap](src/backend/access/heap/heap.md)                   |
| 2      | VM                                  | ok    |       |        | [06_vm](src/backend/access/heap/06_vm.md)                 |
| 3      | HOT                                 | ok    | ok    |        | [02_hot](src/backend/access/heap/02_hot.md)               |
| 4      | Heap Prune                          | ok    | ok    |        | [03_prune](src/backend/access/heap/03_prune.md)           |
| 5      | Lazy VACUUM                         | ok    |       |        | [05_vacuumlazy](src/backend/access/heap/05_vacuumlazy.md) |
| 6      | index types                         |       |       |        |                                                           |
| 7      | nbtree                              | ok    | ok    |        | [nbtree](src/backend/access/nbtree/nbtree.md)             |
| 8      | Table AM / Index AM API             |       |       |        |                                                           |
| 9      | GIN / GiST / BRIN                   |       |       |        |                                                           |
| 10     | pgvector: vector Type & Typmod      |       |       |        |                                                           |
| 11     | pgvector: Distance Functions & SIMD |       |       |        |                                                           |
| 12     | pgvector: IVFFlat Index             |       |       |        |                                                           |
| 13     | pgvector: HNSW Index                |       |       |        |                                                           |

## memory

| number | topic                | study | share | review | where                                                    |
| ------ | -------------------- | ----- | ----- | ------ | -------------------------------------------------------- |
| 1      | MemoryContext / mmgr | ok    | ok    |        | [01_overview](src/backend/utils/mmgr/01_overview.md)     |
| 2      | ResourceOwner        | ok    | ok    |        | [01_overview](src/backend/utils/resowner/01_overview.md) |
| 3      | syscache             |       |       |        |                                                          |
| 4      | Relcache             |       |       |        |                                                          |
| 5      | cache invalidation   |       |       |        |                                                          |
| 6      | Double Buffering     |       |       |        |                                                          |

## storage

| number | topic                                 | study | share | review | where                                                        |
| ------ | ------------------------------------- | ----- | ----- | ------ | ------------------------------------------------------------ |
| 1      | Page Layout                           | ok    | ok    |        | [01_page_layout](src/backend/storage/page/01_page_layout.md) |
| 2      | Page Checksums                        | ok    | ok    |        | [00_readme](src/backend/storage/page/00_readme.md)           |
| 3      | Buffer Manager Overview               | ok    | ok    |        | [01_overview](src/backend/storage/buffer/01_overview.md)     |
| 4      | Clock Sweep (buffer replacement)      | ok    | ok    |        | [02_victim](src/backend/storage/buffer/02_victim.md)         |
| 5      | FSM                                   | ok    | ok    |        | [01_fsm](src/backend/storage/freespace/01_fsm.md)            |
| 6      | Deduplication                         |       |       |        |                                                              |
| 7      | TOAST                                 |       |       |        |                                                              |
| 8      | Data Checksums & Sync Method (vs FPW) |       |       |        |                                                              |

## tools

| number | topic       | study | share | review | where                                         |
| ------ | ----------- | ----- | ----- | ------ | --------------------------------------------- |
| 1      | pageinspect | ok    | ok    |        | [01_pageinspect](src/tools/01_pageinspect.md) |

## traces

| number | topic          | study | share | review | where                                                |
| ------ | -------------- | ----- | ----- | ------ | ---------------------------------------------------- |
| 1      | Query Overview | ok    | ok    |        | [00_query](src/traces/00_query_overview.md)          |
| 2      | Insert         | ok    | ok    |        | [01_insert](src/traces/01_insert.md)                 |
| 3      | Delete         | ok    | ok    |        | [02_delete](src/traces/02_delete.md)                 |
| 4      | Update         | ok    | ok    |        | [03_update](src/traces/03_update.md)                 |
| 5      | Crash Recovery | ok    | ok    |        | [04_crash_recovery](src/traces/04_crash_recovery.md) |
| 6      | VM             | ok    | ok    |        | [05_vm](src/traces/05_vm.md)                         |
| 7      | Prune          |       |       |        |                                                      |

## others

| number | topic                 | study | share | review | where |
| ------ | --------------------- | ----- | ----- | ------ | ----- |
| 1      | Parallel Query        |       |       |        |       |
| 2      | JIT Compilation       |       |       |        |       |
| 3      | FDW / Extension Hooks |       |       |        |       |

## reference


- http://pgint.vonng.com/