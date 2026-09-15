# vacuum

**Lazy vacuum**：在 `ShareUpdateExclusiveLock` 下按页清理堆与索引，不重写整表、不更换 `relfilenode`。普通 `VACUUM` 与 autovacuum worker 均走此路径。

| 路径          | 锁                         | 作用                                                                            | 文件                          |
| ------------- | -------------------------- | ------------------------------------------------------------------------------- | ----------------------------- |
| prune         | page cleanup lock          | 仅当前页；可回收 HOT 死版本；带索引项的死 lp 标 `LP_DEAD`                       | `pruneheap.c`                 |
| lazy `VACUUM` | `ShareUpdateExclusiveLock` | prune + 清理索引 + `LP_DEAD`→`LP_UNUSED` + 置 VM / 记 FSM；仅表尾连续空页可截断 | `vacuumlazy.c`                |
| `VACUUM FULL` | `AccessExclusiveLock`      | 按堆扫描顺序 `rewriteheap`，新 `relfilenode`，重建索引                          | `cluster.c` / `rewriteheap.c` |
| `CLUSTER tb`  | `AccessExclusiveLock`      | 按索引顺序 `rewriteheap`，新 `relfilenode`，重建索引                            | `cluster.c` / `rewriteheap.c` |

PG 9.0 起 `VACUUM FULL` 不再在原文件内搬元组，而是调用 `cluster_rel()`，与 `CLUSTER` 共用 `rewriteheap`：将仍需保留的元组写入新堆文件、重建全部索引、切换 `relfilenode` 后删除旧文件。

`VACUUM FULL` 和 `CLUSTER` 区别:

- `VACUUM FULL`：`vacuum_rel` 在 `VACOPT_FULL` 时调用 `cluster_rel`（不走 `heap_vacuum_rel`），按旧堆页顺序复制，不要求索引；**目标是收缩膨胀**。
- `CLUSTER tb` / `CLUSTER tb USING idx`：按指定索引（或 `pg_index.indisclustered` 记录的上次聚簇索引）顺序复制，**使堆物理顺序接近该索引**，Index Scan 更易顺序读盘；收缩是副作用。**无可用索引时 `CLUSTER` 不能执行**。

二者均持 `AccessExclusiveLock`，阻塞全部读写。

`ShareUpdateExclusiveLock` 与 `RowExclusiveLock` 不冲突，SELECT / INSERT / UPDATE / DELETE 可与 lazy `VACUUM` 并发；与另一 `VACUUM` 或 `CREATE INDEX CONCURRENTLY` 冲突。

