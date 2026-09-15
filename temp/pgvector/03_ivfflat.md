# pgvector：IVFFlat 索引

> 算法背景：k-means 分簇 + 倒排 + 簇内暴力（对应 ANN 理论中的 IVF-Flat）。

## 1. 创建索引

```sql
-- 建议：表内已有一定数据后再建（需 k-means 训练）
CREATE INDEX idx_ivf ON items
USING ivfflat (embedding vector_l2_ops)
WITH (lists = 100);
```

| 参数 | 含义 | 经验值 |
|---|---|---|
| `lists` | 簇（倒排 list）个数，类比 FAISS `nlist` | ≤1M 行：`rows/1000`；>1M：`sqrt(rows)` |

**与 FAISS 对照**：`lists` = `nlist`；pgvector 无单独 `train` 步骤，**建索引时**对表现有向量跑 k-means。

## 2. 查询调参：`ivfflat.probes`

```sql
SET ivfflat.probes = 10;   -- 默认 1

SELECT id FROM items
ORDER BY embedding <-> $1
LIMIT 10;
```

| GUC | 默认 | 作用 |
|---|---|---|
| `ivfflat.probes` | 1 | 查询时探查几个 list，类比 FAISS `nprobe` |
| `ivfflat.max_probes` | — | 上限；若小于 `probes` 则实际用 `probes` |

- `probes` ↑ → recall ↑、延迟 ↑（近似线性）
- `probes = lists` → 等价于探查全部 list（接近暴力，planner 可能不用索引）

**连接池陷阱**（PgBouncer transaction pooling）：裸 `SET` 可能丢失，应用：

```sql
BEGIN;
SET LOCAL ivfflat.probes = 10;
SELECT ... ORDER BY embedding <-> $1 LIMIT 10;
COMMIT;
```

或 `ALTER DATABASE db SET ivfflat.probes = 10;`

## 3. 建索引注意

```sql
SET maintenance_work_mem = '2GB';   -- k-means 与 list 构建吃内存

CREATE INDEX CONCURRENTLY idx_ivf ON items
USING ivfflat (embedding vector_l2_ops) WITH (lists = 1000);
```

| 要点 | 说明 |
|---|---|
| **先有数据** | 空表建索引质心无意义；大量增量后考虑 **REINDEX** |
| **分布漂移** | 新数据偏离旧质心 → recall 降；定期重建或换 HNSW |
| **CONCURRENTLY** | 生产常用，避免长时间写锁 |
| **维度** | `vector` ≤ 2000；更高用 `halfvec` + `halfvec_*_ops` |

## 4. 执行计划

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT id FROM items ORDER BY embedding <-> $1 LIMIT 10;
```

期望：`Index Scan using idx_ivf` + `Order By: (embedding <-> …)`。

调试时可临时 `SET enable_seqscan = off` 强制索引（仅测试，生产慎用）。

## 5. 与 HNSW 选型（pgvector 语境）

| | IVFFlat | HNSW |
|---|---|---|
| 建索引 | 快，需已有数据 | 慢，可空表建 |
| 内存 | 较低 | 较高 |
| 查询 | 中，靠 `probes` | 快，靠 `ef_search` |
| 增量 | add 进 list 即可 | 在线 insert 进图 |
| 数据漂移 | 质心老化 | 相对不依赖训练 |

中小规模、可接受定期 REINDEX、写入频繁 → **IVFFlat**；要低延迟高 recall、读多写少 → **HNSW**。

## 6. 边界与召回

- **Voronoi 边界**：`probes=1` 易漏跨 list 近邻 → 生产常 `probes ≈ sqrt(lists)` 起调。
- **WHERE 过滤**：`WHERE category = 1 ORDER BY dist LIMIT k` 可能返回不足 k 条；0.8+ 支持 **iterative index scan**（官方 README *Iterative Index Scans*）。
- **dead tuple**：与 PG MVCC 相同，需 VACUUM；影响有效召回。

## 7. 实验模板

```sql
-- 1. 暴力 ground truth（小表）
CREATE TEMP TABLE gt AS
SELECT id FROM items ORDER BY embedding <-> $1 LIMIT 10;

-- 2. 调 probes，对比 id 重叠率 ≈ recall@10
SET ivfflat.probes = 1;
-- ... 记录结果 ...
SET ivfflat.probes = 10;
-- ...
```

## 8. 自检

1. `lists` 过大过小各有什么问题？→ 过大：质心比较贵、list 稀疏；过小：list 内扫描贵（见 ANN §4.4）。
2. IVFFlat 为何建议有数据再建？→ k-means 需要样本代表分布。
3. `ivfflat.probes` 与 FAISS `nprobe` 关系？→ 同义调参，**查询阶段**、无需重建索引。

## 9. 参考

- [pgvector IVFFlat](https://github.com/pgvector/pgvector#ivfflat)
- 源码：`src/ivfbuild.c`、`src/ivfscan.c`
