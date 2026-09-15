# update

观测 UPDATE 的 MVCC 新版本、HOT vs cold、hint bit，以及 VACUUM prune 后的 `LP_REDIRECT`。机制见 [Why & How: HOT](../backend/access/heap/02_hot.md)；锁顺序见 [Lock in update](../backend/storage/lmgr/02_update.md)。

- 调试：`pageinspect` 的 `heap_page_items` / `bt_page_items`
- 表上 `autovacuum_enabled = off`，否则 prune / VACUUM 会抢在观察之前发生
- 必须有**索引**才能对比是否膨胀；无索引时同页 UPDATE 几乎总是 HOT

`t_infomask2` 低 11 bit = `natts`（本例 2）。HOT 标志叠在上面：

| `t_infomask2` | 含义                            |
| ------------- | ------------------------------- |
| 2             | 仅 `natts`                      |
| 16386         | `HEAP_HOT_UPDATED (0x4000)` + 2 |
| 32770         | `HEAP_ONLY_TUPLE (0x8000)` + 2  |

`t_infomask`：`HEAP_XMIN_COMMITTED=256`，`HEAP_XMAX_COMMITTED=1024`，`HEAP_XMAX_INVALID=2048`，`HEAP_UPDATED=8192`（新版本）。`lp_flags`：1=`LP_NORMAL`，2=`LP_REDIRECT`，3=`LP_DEAD`，0=`LP_UNUSED`。

xid / OID 随实例变化，看相对关系和标志位。

## Case：HOT

索引列 `a` 不变，只改 `b`。新元组同页、不插索引。

```sql
CREATE EXTENSION IF NOT EXISTS pageinspect;

DROP TABLE IF EXISTS tb;
CREATE TABLE tb (a int, b int) WITH (autovacuum_enabled = off);
INSERT INTO tb VALUES (1, 10);
CREATE INDEX idx ON tb (a);

SELECT * FROM tb;  -- 给插入版本打 xmin hint
```

```sql
SELECT lp, lp_off, lp_flags, lp_len, t_xmin, t_xmax, t_ctid, t_infomask2, t_infomask
FROM heap_page_items(get_raw_page('tb', 0));
 lp | lp_off | lp_flags | lp_len | t_xmin | t_xmax | t_ctid | t_infomask2 | t_infomask
----+--------+----------+--------+--------+--------+--------+-------------+------------
  1 |   8160 |        1 |     32 |   1228 |      0 | (0,1)  |           2 |       2304
```

2304 = `HEAP_XMIN_COMMITTED` + `HEAP_XMAX_INVALID`。索引一项，TID 为 root `(0,1)`：

```sql
SELECT itemoffset, ctid FROM bt_page_items('idx', 1);
 itemoffset | ctid
------------+-------
          1 | (0,1)
```

```sql
UPDATE tb SET b = 20;
SELECT * FROM tb;  -- 提交后读一遍，回填 xmax/xmin hint（不保证 prune）
```

```sql
SELECT lp, lp_off, lp_flags, lp_len, t_xmin, t_xmax, t_ctid, t_infomask2, t_infomask
FROM heap_page_items(get_raw_page('tb', 0));
 lp | lp_off | lp_flags | lp_len | t_xmin | t_xmax | t_ctid | t_infomask2 | t_infomask
----+--------+----------+--------+--------+--------+--------+-------------+------------
  1 |   8160 |        1 |     32 |   1228 |   1229 | (0,2)  |       16386 |       1280
  2 |   8128 |        1 |     32 |   1229 |      0 | (0,2)  |       32770 |      10496
```

- lp 1：`HOT_UPDATED`，`t_ctid` 指向新版本；`t_xmax` = 更新事务。1280 = `HEAP_XMIN_COMMITTED` + `HEAP_XMAX_COMMITTED`。
- lp 2：`HEAP_ONLY` + `HEAP_UPDATED`；10496 = 8192 + 2048 + 256。
- 索引数据项 **仍是** `(0,1)`（叶页可能另有 high key）。Index Scan 先落到 lp 1，再跟链到 lp 2。

页几乎全空时，`SELECT` 通常只打 hint、**不** prune。VACUUM 才会收掉死版本：

```sql
VACUUM tb;

SELECT lp, lp_off, lp_flags, lp_len, t_xmin, t_xmax, t_ctid, t_infomask2, t_infomask
FROM heap_page_items(get_raw_page('tb', 0));
 lp | lp_off | lp_flags | lp_len | t_xmin | t_xmax | t_ctid | t_infomask2 | t_infomask
----+--------+----------+--------+--------+--------+--------+-------------+------------
  1 |      2 |        2 |      0 |        |        |        |             |
  2 |   8160 |        1 |     32 |   1229 |      0 | (0,2)  |       32770 |      10496
```

lp 1：`lp_flags=2`（`LP_REDIRECT`），`lp_off=2` 是 **OffsetNumber**，不是字节偏移。索引仍指向 `(0,1)`，经 redirect 到活元组。

## Case：cold

改索引列。同页仍能放下新版本，但必须新索引项。

```sql
DROP TABLE IF EXISTS tb;
CREATE TABLE tb (a int, b int) WITH (autovacuum_enabled = off);
INSERT INTO tb VALUES (1, 10);
CREATE INDEX idx ON tb (a);
SELECT * FROM tb;

UPDATE tb SET a = 2;
SELECT * FROM tb;
```

```sql
SELECT lp, lp_off, lp_flags, t_xmin, t_xmax, t_ctid, t_infomask2, t_infomask
FROM heap_page_items(get_raw_page('tb', 0));
 lp | lp_off | lp_flags | t_xmin | t_xmax | t_ctid | t_infomask2 | t_infomask
----+--------+----------+--------+--------+--------+-------------+------------
  1 |   8160 |        1 |   1230 |   1231 | (0,2)  |           2 |       1280
  2 |   8128 |        1 |   1231 |      0 | (0,2)  |           2 |      10496
```

`t_infomask2` 仍是 `natts`，**没有** `HOT_UPDATED` / `HEAP_ONLY`。`t_ctid` 照样串版本链。索引两项：

```sql
SELECT itemoffset, ctid FROM bt_page_items('idx', 1);
 itemoffset | ctid
------------+-------
          1 | (0,1)
          2 | (0,2)
```

VACUUM 必须先清指向 `(0,1)` 的索引项，才能把 lp 1 标 `LP_UNUSED`。不能只靠 redirect 丢掉 root——cold 的新版本有自己的索引 TID。

HOT-safe 但页满时同样走 cold（新页 + 新索引项）。可用更低 `fillfactor` 或填满页后只改非索引列复现。

## 调用链

```text
ExecModifyTable | ExecUpdate
  table_tuple_update
    heapam_tuple_update
      heap_update
        HeapTupleSatisfiesUpdate
        compute_new_xmax_infomask
        /* HOT-safe && same page space */
        PageSetPrunable
        [HOT] HeapTupleSetHotUpdated / HeapTupleSetHeapOnly
        RelationPutHeapTuple
        old.t_ctid = new
        log_heap_update
        visibilitymap_clear
  [not HOT] ExecInsertIndexTuples
```

UPDATE 与 DELETE 一样先给旧版本写 `t_xmax`；差别是再插入新版本，并决定要不要索引项。锁：vxid → `RowExclusiveLock` → xid → 元组，见 [Lock in update](../backend/storage/lmgr/02_update.md)。
