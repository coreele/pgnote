# MVCC Visibility

| client 1            | client 2                    | note                 |
| ------------------- | --------------------------- | -------------------- |
|                     | `insert into tb values(1);` | implicit transaction |
|                     | `begin;`                    |                      |
|                     | `insert into tb values(2);` |                      |
| `select * from tb;` |                             | 2 is **invisible**   |
|                     | `commit`;                   |                      |
| `select * from tb;` |                             | 2 is **visible**     |

## 核心函数 `HeapTupleSatisfiesMVCC`

```
SeqNext | table_scan_getnextslot | heap_getnextslot
    heapgettup_pagemode | heapgetpage
        HeapTupleSatisfiesVisibility
            HeapTupleSatisfiesMVCC
```

## PostgreSQL MVCC 可见性判断核心规则

![](assets/snapshot.png)

PostgreSQL 中 `HeapTupleSatisfiesMVCC` 函数判断元组对当前快照可见性的逻辑，可以分为两大阶段：

1. 判断 tuple 是否诞生: `xmin`
1. 判断 tuple 是否消亡: `xmax`

PostgreSQL 堆表元组仅定义**插入**与**删除**两种状态。MVCC 可见性判定核心为：基于当前快照，元组创建事务（t_xmin）**可见**且删除事务（t_xmax）**不可见**。

UPDATE 操作被底层解耦为 **“旧元组标记删除 + 新元组插入”**，并通过 `ctid` 链接版本链。该设计消除了对 UPDATE 的特殊逻辑依赖，仅通过统一管理元组状态即可覆盖所有写操作，确保了内核逻辑的极简与自洽。

PostgreSQL 堆表（Heap Table）的元组管理展现了极致的**逻辑简约**和**一致性**。

## 核心原则

- 快照隔离：元组的可见性完全由当前事务的快照决定，只“看到”快照建立前已提交的插入，以及快照建立后未提交的删除。
- 提示位优化：通过 `HEAP_XMIN_COMMITTED`/`HEAP_XMAX_INVALID` 等提示位缓存事务状态，避免重复查询事务日志，提升性能。
- 事务 ID 生命周期：每个元组的 XMIN/XMAX 都对应事务的完整生命周期（活跃、提交、终止），函数会根据其状态逐步校验。

堆页「对所有快照都可见」被收成 VM 的 all-visible，见 [Visibility Map](../heap/06_vm.md)。

---

**相关笔记**: [Snapshot](./07_mvcc_snapshot.md) · [CLOG](./09_clog.md) · [Heap AM](../heap/heap.md) · [VM](../heap/06_vm.md)
