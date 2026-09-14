# Heap Access Method

PostgreSQL 默认表访问方法。上层只认 Table AM；本目录把 scan / DML / 可见性 / TOAST / 页内回收 / VACUUM / 整表改写接到堆页上。

源码：`src/backend/access/heap/`。

## 1. 分层

```text
执行器 / commands（INSERT/UPDATE/DELETE/SELECT/VACUUM/CLUSTER …）
        │
        ▼
┌───────────────────┐
│ heapam_handler.c  │  Table AM（`TableAmRoutine`）
└─────────┬─────────┘
          │
     ┌────┼────────────────┐
     ▼    ▼                ▼
 heapam.c  vacuumlazy.c   rewriteheap.c
  CRUD      并发 VACUUM     CLUSTER / 整表改写
     │
     ├─ heapam_visibility.c   元组是否可见
     ├─ heaptoast.c           大字段外置
     ├─ hio.c                 选页 + 写入
     ├─ pruneheap.c           页内剪枝 / HOT
     └─ visibilitymap.c       all-visible / frozen
```

`vacuumlazy` 同样走 prune / visibility / visibilitymap（**置位**）。DML 只**清** VM。

## 2. 各文件职责

| 文件                    | 职责                                                                                                                                                   |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **heapam_handler.c**    | 把堆 AM 接到 `tableam`：实现 `TableAmRoutine`。上层不直接绑 `heap_*`。                                                                                 |
| **heapam.c**            | scan / fetch / insert / update / delete，以及行锁、XLOG、HOT、与 FSM/VM 协作。真正改表的主路径。                                                       |
| **heapam_visibility.c** | MVCC 可见性：`HeapTupleSatisfies*`，安全时写 hint bit。scan、更新冲突、VACUUM 判死元组都靠它。见 [MVCC Visibility](../transam/08_mvcc_visibility.md)。 |
| **heapam_xlog.c**       | 堆 WAL 的 redo。                                                                                                                                       |
| **hio.c**               | 堆页 I/O：`RelationGetBufferForTuple` 找空位，`RelationPutHeapTuple` 写入；协作 [FSM](../../storage/freespace/01_fsm.md)，必要时清 VM。                |
| **heaptoast.c**         | 元组太大则压缩/外置到 toast 表；删除时回收。insert/update 路径由 `heapam.c` 调用。                                                                     |
| **pruneheap.c**         | 页内剪枝与 [HOT](./02_hot.md)：回收死元组、改 redirect/dead/unused。见 [Page Prune](./03_prune.md)；普通访问也可 `heap_page_prune_opt`。               |
| **visibilitymap.c**     | 每堆页 2 bit（all-visible / all-frozen）。VACUUM 置位以便跳页；DML 破坏「全可见」时清位。见 [VM](./01_vm.md)。                                         |
| **vacuumlazy.c**        | 并发 VACUUM：扫堆 → 收死 TID → 清索引 → 再清堆页 → 更新 VM / 截断。见 [Lazy VACUUM](05_vacuumlazy.md)。                                              |
| **rewriteheap.c**       | CLUSTER / 整表改写：在新堆重写元组，修正 update 链的 ctid。                                                                                            |
| **syncscan.c**          | 多个 seqscan 扫同一表时尽量共用 I/O。                                                                                                                  |

行锁协议见 [Tuple Lock](./00_README.tuplock.md)；页布局见 [Page Layout](../../storage/page/01_page_layout.md)。

## 3. 典型调用链

**读：**  
`handler` scan → `heapam` 取页/元组 → `heapam_visibility` 判断可见 →（大字段）detoast

**写：**  
`handler` insert/update/delete → `heapam`（必要时 `heaptoast`）→ `hio` 选页写入 → 同一临界区清 VM → 可能 `heap_page_prune_opt`

**VACUUM：**  
`vacuumlazy` → `heapam_visibility` 判死活 → `pruneheap` 回收页空间 → 清索引死指针 → `visibilitymap_set` 标记可跳过页。见 [Lazy VACUUM](05_vacuumlazy.md)。

**CLUSTER / 表改写：**  
`handler` → `rewriteheap`（保可见性与 ctid 链）→ 底层仍走堆写入路径

可复现路径：[insert](../../../traces/01_insert.md) · [delete](../../../traces/02_delete.md) · [update](../../../traces/03_update.md) · [VM](../../../traces/05_vm.md)

## 4. 总结

| 层                          | 责任                   |
| --------------------------- | ---------------------- |
| **handler**                 | 对外接口（Table AM）   |
| **heapam**                  | CRUD / scan            |
| **visibility**              | 能不能看见             |
| **hio / toast**             | 往哪写、怎么塞得下     |
| **prune / vacuumlazy / VM** | 回收空间、加速后续扫描 |
| **rewriteheap**             | 整表搬迁时保住版本链   |
