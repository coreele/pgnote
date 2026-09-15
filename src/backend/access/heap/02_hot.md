# HOT

## 1. 定义

**HOT（Heap-Only Tuple）**：同页 UPDATE，且索引列都没变，则新版本**不建索引项**。索引仍指向链的 **root** line pointer；顺着 `t_ctid` 在页内找到活元组。

标志在 **`t_infomask2`**（不是 `t_infomask`），低 11 bit 仍是 `natts`：

| flag               | value    | which          | meaning                      |
| ------------------ | -------- | -------------- | ---------------------------- |
| `HEAP_HOT_UPDATED` | `0x4000` | 链中较旧的版本 | 下一版本是 heap-only，应跟随 |
| `HEAP_ONLY_TUPLE`  | `0x8000` | 新版本         | 无直接索引项                 |

`t_infomask` 上的 `HEAP_UPDATED`（`0x2000`）表示「这是 UPDATE 产生的新版本」，HOT / cold 都有。

源码：`heapam.c`（`heap_update`）、`htup_details.h`。页内缩短链、回收死版本见 [Page Prune](./03_prune.md)。

```sql
DROP TABLE IF EXISTS tb;

CREATE TABLE tb (id int PRIMARY KEY, val int)
WITH (autovacuum_enabled = off, fillfactor = 100);

INSERT INTO tb values (1, 1);

-- HOT 更新，产生 dead heap-only tuple（不增索引项）
UPDATE tb SET val = val * 10 WHERE id = 1;

SELECT * FROM tb;
```

---

## 2. 为何需要

无 HOT 时，每次 UPDATE 即使索引列不变也要：

1. 为新 `ctid` 插一条相同 key 的索引记录 → 索引膨胀、扫描变慢。
2. 旧版本的 line pointer 有索引指着，页内回收不能丢掉它，除非整表 VACUUM 先清索引。

HOT 把「索引列没变」收成**单页**约束：整条链共享一个索引 TID，中间死版本可以只做页内 prune，不必扫索引。

不能跨页续链：跨页就无法只靠本页操作回收，索引查找也会多一次堆页 I/O。空间不够或索引列变了，链在此结束，新版本走 **cold update**（新索引项）。

---

## 3. 何时能 HOT

两条件同时成立才是 HOT update；只满足第一项叫 **HOT-safe**，仍可能因没空间而 cold：

| 条件                     | 判定                                                                                      |
| ------------------------ | ----------------------------------------------------------------------------------------- |
| 索引列未变               | 对索引用到的列做 **bitwise** 比较（不用类型 `=`）。表达式索引、部分索引谓词用到的列也算。 |
| 新版本能放进**同一堆页** | 当前页空闲（必要时可先 prune）≥ 新元组。                                                  |

无索引时同页有空就 HOT。观测索引膨胀必须先建索引。

---

## 4. 链与 prune

HOT 决定**索引只钉 root**；prune 负责把链缩短、把死 root 变成 `LP_REDIRECT`。后者的触发、hint、与 VACUUM 分工见 [Page Prune](./03_prune.md)。

```text
Index -> lp[1]
         [v1 HOT_UPDATED] --t_ctid--> [v2 HEAP_ONLY]

after prune:
Index -> lp[1] LP_REDIRECT --> lp[2]
                               [v2]
```

索引始终指向 **root**（lp 1）。HOT 新版本没有自己的索引项：Index Scan 先落到 root，再沿 `t_ctid` 找到活元组；Seq Scan 扫每个 lp，不用跟链。

v1 对所有快照都不可见后，prune 收回它的元组体，但 root 这个槽还在——改成 `LP_REDIRECT`（`lp_off` = 活元组的 OffsetNumber）。索引仍是 `(0,1)`。这就是 [update trace](../../../traces/03_update.md) 里 `VACUUM` 之后的页。

---

## 5. 路径

**UPDATE：**

```text
ExecModifyTable | ExecUpdate
  table_tuple_update
    heapam_tuple_update
      heap_update
        HeapTupleSatisfiesUpdate
        /* HOT-safe? + same-page space */
        PageSetPrunable
        [HOT] HeapTupleSetHotUpdated(old)
              HeapTupleSetHeapOnly(new)
        RelationPutHeapTuple
        old.t_ctid = new
        log_heap_update
        visibilitymap_clear     /* 与其它 DML 一样 */
  [not HOT] ExecInsertIndexTuples
```

HOT 时打标志、写 `pd_prune_xid`（`PageSetPrunable`），给后续页内回收留 hint；非 HOT 才插索引。

**Prune：** `heap_page_prune_opt` / `heap_page_prune` 如何缩短这条链、何时真正动手，见 [Page Prune](./03_prune.md)。

---

## 6. 源码入口

- 设计：`src/backend/access/heap/README.HOT`
- 判定与打标：`heap_update`（`heapam.c`）
- 剪枝：[Page Prune](./03_prune.md)（`pruneheap.c`）
- 标志：`HEAP_HOT_UPDATED` / `HEAP_ONLY_TUPLE`（`htup_details.h`，`infomask2`）
- 索引插入：`ExecInsertIndexTuples`（非 HOT）
- WAL：`log_heap_update`（HOT 与 cold 不同 flags）

---

## 7. 小结

1. HOT = 同页 + 索引列 bitwise 不变 → 不插索引；旧版 `HOT_UPDATED`，新版 `HEAP_ONLY`。
2. 索引始终指向 root；prune 把死 root 变成 `LP_REDIRECT`，从而能收回元组体且索引仍有效（细节见 [Page Prune](./03_prune.md)）。
3. 没空间或改了索引列 → cold update，必须新索引项；VACUUM 才能回收带索引的死 lp。
