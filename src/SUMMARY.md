# Summary

- [Overview](./index.md)

---

# Meta

- [Architecture](./meta/00_arch.md)
- [Code Structure](./meta/01_code.md)
- [Compile](./meta/02_compile.md)
- [Boot](./meta/03_boot.md)

---

# Traces

- [Query Overview](./traces/00_query_overview.md)
- [Insert](./traces/01_insert.md)
- [Delete](./traces/02_delete.md)
- [Update](./traces/03_update.md)
- [Crash Recovery](./traces/04_crash_recovery.md)
- [VM](./traces/05_vm.md)

---

# backend

- [tcop](./backend/tcop/tcop.md)
  - [Overview](./backend/tcop/00_overview.md)
- [parser](./backend/parser/parser.md)
  - [Overview](./backend/parser/00_overview.md)
  - [Analyze](./backend/parser/01_analyze.md)

<!--
- [optimizer](./backend/optimizer/optimizer.md)
  - [Overview](./backend/optimizer/00_overview.md)
-->

- [executor](./backend/executor/executor.md)
  - [Overview](./backend/executor/00_overview.md)
  - [Pipeline](./backend/executor/01_pipeline.md)
  - [State](./backend/executor/02_state.md)
- [node](./backend/node/node.md)
  - [List](./backend/node/list.md)
- [access](./backend/access/access.md)
  - [heap](./backend/access/heap/heap.md)
    - [VACUUM Overview](./backend/access/heap/01_vacuum.md)
    - [HOT](./backend/access/heap/02_hot.md)
    - [Page Prune](./backend/access/heap/03_prune.md)
    - [Freeze](./backend/access/heap/04_freeze.md)
    - [Lazy VACUUM](./backend/access/heap/05_vacuumlazy.md)
    - [Visibility Map](./backend/access/heap/06_vm.md)
    - [README.HOT](./backend/access/heap/00_README.HOT.md)
    - [Tuple Lock](./backend/access/heap/00_README.tuplock.md)
  - [nbtree](./backend/access/nbtree/nbtree.md)
    - [README](./backend/access/nbtree/00_readme.md)
    - [Plan](./backend/access/nbtree/01_plan.md)
    - [Page](./backend/access/nbtree/02_page.md)
    - [Code](./backend/access/nbtree/03_code.md)
  - [transam](./backend/access/transam/transam.md)
    - [README](./backend/access/transam/00_readme.md)
    - [Overview](./backend/access/transam/01_overview.md)
    - [Process](./backend/access/transam/02_process.md)
    - [State](./backend/access/transam/03_state.md)
    - [Virtual XID](./backend/access/transam/04_vxid.md)
    - [XID](./backend/access/transam/05_xid.md)
    - [CLOG](./backend/access/transam/09_clog.md)
    - [Isolation](./backend/access/transam/06_iso.md)
    - [MVCC Snapshot](./backend/access/transam/07_mvcc_snapshot.md)
    - [MVCC Visibility](./backend/access/transam/08_mvcc_visibility.md)
    - [WAL Record Structure & Insertion](./backend/access/transam/10_wal_record_insert.md)
    - [XLogRecPtr (LSN)](./backend/access/transam/11_xlogrecptr_lsn.md)
    - [Mini-Transaction](./backend/access/transam/12_mini_transaction.md)
    - [Full Page Writes](./backend/access/transam/13_full_page_writes.md)
    - [WAL Recovery](./backend/access/transam/14_wal_recovery.md)
    - [Crash Recovery Redo Path](./backend/access/transam/15_crash_recovery_redo.md)
    - [Base Backup](./backend/access/transam/16_base_backup.md)
- [storage](./backend/storage/storage.md)
  - [page](./backend/storage/page/page.md)
    - [README](./backend/storage/page/00_readme.md)
    - [Page Layout](./backend/storage/page/01_page_layout.md)
  - [freespace](./backend/storage/freespace/freespace.md)
    - [README](./backend/storage/freespace/00_readme.md)
    - [Free Space Map](./backend/storage/freespace/01_fsm.md)
  - [buffer](./backend/storage/buffer/buffer.md)
    - [README](./backend/storage/buffer/00_readme.md)
    - [Overview](./backend/storage/buffer/01_overview.md)
    - [Victim](./backend/storage/buffer/02_victim.md)
  - [lmgr](./backend/storage/lmgr/lmgr.md)
    - [README](./backend/storage/lmgr/00_readme.md)
    - [Overview](./backend/storage/lmgr/01_overview.md)
    - [Update](./backend/storage/lmgr/02_update.md)
    - [Conflict](./backend/storage/lmgr/03_conflict.md)
- [utils](./backend/utils/utils.md)
  - [mmgr](./backend/utils/mmgr/mmgr.md)
    - [README](./backend/utils/mmgr/00_readme.md)
    - [Overview](./backend/utils/mmgr/01_overview.md)
    - [Top Context](./backend/utils/mmgr/02_top.md)
    - [Query Context](./backend/utils/mmgr/03_query.md)
    - [Buffer Resource](./backend/utils/mmgr/04_buf_res.md)
    - [Implementation](./backend/utils/mmgr/05_impl.md)
  - [resowner](./backend/utils/resowner/resowner.md)
    - [README](./backend/utils/resowner/00_readme.md)
    - [Overview](./backend/utils/resowner/01_overview.md)
- [replication](./backend/replication/replication.md)
  - [README](./backend/replication/00_readme.md)
  - [Streaming Replication & Log Decoding](./backend/replication/01_streaming_replication.md)
  - [Replication Slot & Timeline](./backend/replication/02_replication_slot_timeline.md)

---

# Tools

- [pageinspect](./tools/01_pageinspect.md)
