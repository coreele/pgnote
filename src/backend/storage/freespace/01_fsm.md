# Why & How: Free Space Map (FSM)

## 1. 定义

**Free Space Map（FSM）**：关系的独立 fork（`<relfilenode>_fsm`，`FSM_FORKNUM`），按 **堆/索引页** 记录「大约还有多少空闲空间」，供插入与扩展决策快速查询。

- 每数据页对应 **1 个 category 字节**：空闲量 ≈ `cat * (BLCKSZ/256)`（向下取整）；假定空闲 < `BLCKSZ`，故 cat ∈ 0…255。
- 不存精确字节数，以便 map 小、可树形搜索。
- Heap 与多数索引（hash 除外）有 FSM。

源码：`src/backend/storage/freespace/`（`freespace.c`、`fsmpage.c`、[README](./00_readme.md)）。

---

## 2. 为何需要

`heap_insert` → `RelationGetBufferForTuple` 需要一块能容纳新 tuple（含对齐/填充）的页。

若无 FSM，只能从 block 0 起试探或扫表，随 `nblocks` 恶化。FSM 把「是否存在 ≥ X 空闲」变成对 FSM 树的下降搜索；整棵子树不够时，根节点一次即可否定。返回 `InvalidBlockNumber` 时由调用方 **extend** 关系。

信息是**近似且可能过期**的：并发插入、粒度舍入、未及时 `RecordPageWithFreeSpace` 都会让「FSM 说够、页上不够」出现；API 契约要求调用方能处理该情况。

---

## 3. 页内结构：byte 数组上的 max 树

每个 FSM 页把一棵二叉树摊在数组里：叶子存「某一堆页（或下一层 FSM 页）的空闲类别」；非叶 = 两子的 **max**。

```text
        4
     4     2
   3  4  0  2     <- 叶：对应数据页（或下层 FSM）
```

因页头占用，叶层不是完美 2 的幂：右侧缺若干叶，上层仍保持完全。对外用「slot」抽象，由 `fsm_search_avail` / `fsm_set_avail` 隐藏数组下标细节。

**搜索**（要 cat ≥ X）：从根往下，选「子 ≥ X」的分支；两子都可则按策略选一（可偏向某页邻近，或打散负载）。`fp_next_slot` 等状态用于轮转起点，减少总挤同一叶。

**更新**：写叶 → 沿父 **bubble up** 重算 max，直到根或父值不变。

性质：根 < X ⇒ 本 FSM 页覆盖范围内不存在足够空闲。

---

## 4. 跨页：FSM 页树

数据页很多时，底层 FSM 页的根再作为上层 FSM 页的叶子，形成多层。`freespace.c` 负责地址换算与层间遍历；单页内算法在 `fsmpage.c`。

物理上 FSM fork 随关系增长扩展；与 main fork 的 block 编号通过固定扇出关系映射（见 README「Higher-level structure」）。

---

## 5. 对外 API 与插入路径

| 函数                                                | 作用                                                                                         |
| --------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| `GetPageWithFreeSpace(rel, spaceNeeded)`            | `fsm_space_needed_to_cat` 后 `fsm_search`；命中返回 `BlockNumber`，否则 `InvalidBlockNumber` |
| `RecordPageWithFreeSpace(rel, heapBlk, spaceAvail)` | 把该堆页的实测/估计空闲写回 FSM                                                              |
| `RecordAndGetPageWithFreeSpace(...)`                | 先更新「刚失败的那页」空闲，再搜下一候选（插入重试）                                         |
| `FreeSpaceMapVacuum` 等                             | VACUUM 后批量校正 FSM（与清理路径配合）                                                      |

典型插入：

```text
RelationGetBufferForTuple
  -> GetPageWithFreeSpace(spaceNeeded)
       命中 -> 锁页、复核空闲
            不够 -> RecordAndGetPageWithFreeSpace / 再试
       未命中 -> RelationAddBlocks 扩展 main fork，初始化新页
  -> 放入 tuple 后视情况 RecordPageWithFreeSpace
```

VACUUM / page prune 回收空间后应更新 FSM，否则空闲「看不见」，表会不必要地膨胀。

观测：contrib `pg_freespacemap`。

---

## 6. 源码入口

- 设计说明：`src/backend/storage/freespace/README`
- 关系级搜索/记录：`freespace.c`
- 页内树：`fsmpage.c`
- 插入选页：`access/heap/hio.c` — `RelationGetBufferForTuple`
- Fork 常量：`FSM_FORKNUM`（`relfilenode.h` / smgr）

---

## 7. 小结

1. FSM = 每数据页一字节空闲类别 + 页内/跨页 **max 树**，加速「找够大的页」。
2. 粒度与并发使结果不可盲信；选页后必须在堆页上复核。
3. 扩展与 VACUUM 都要维护 FSM，否则插入只见「假满」。
