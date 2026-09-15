# pgvector：HNSW 索引

> 算法背景：分层可导航小世界图（HNSW，Hierarchical Navigable Small World）。

## 1. 创建索引

```sql
CREATE INDEX idx_hnsw ON items
USING hnsw (embedding vector_l2_ops);

-- 指定建图参数
CREATE INDEX idx_hnsw ON items
USING hnsw (embedding vector_l2_ops)
WITH (m = 16, ef_construction = 64);
```

| 建索引参数 | 默认 | 含义（对照 ANN 理论） |
|---|---|---|
| `m` | 16 | 每层最大连边数（第 0 层 `2m`） |
| `ef_construction` | 64 | 建图时候选集宽度 |

- `ef_construction` ↑ → 图质量 ↑、建索引 / insert 更慢
- **可在空表上建索引**（无 k-means 训练）；数据后续 INSERT 会维护图

支持类型与维度（索引）：`vector` ≤ 2000；`halfvec` ≤ 4000；`bit` / `sparsevec` 见官方文档。

## 2. 查询调参：`hnsw.ef_search`

```sql
SET hnsw.ef_search = 100;   -- 默认 40

SELECT id FROM items
ORDER BY embedding <-> $1
LIMIT 10;
```

| GUC | 默认 | 作用 |
|---|---|---|
| `hnsw.ef_search` | 40 | 第 0 层束搜索宽度，类比 FAISS `efSearch` |

要求：**`ef_search ≥ LIMIT`（k）**；否则候选池不足，recall 差或结果行数不足。

PgBouncer 场景同 IVFFlat，优先 `SET LOCAL` 或 `ALTER DATABASE … SET`。

## 3. 建索引与内存

```sql
SET maintenance_work_mem = '8GB';   -- 图构建阶段尽量让 working set 进内存

CREATE INDEX CONCURRENTLY idx_hnsw ON items
USING hnsw (embedding vector_l2_ops) WITH (m = 16, ef_construction = 128);
```

HNSW 索引 **大于** IVFFlat（向量 + 图边），高维时仍可能 TOAST / 分页存储，但内存压力是主要运维点。

## 4. 查询路径（概念）

```
ORDER BY embedding <-> query LIMIT k
    ↓
Index AM: hnswbeginscan / hnswgettuple
    ↓
从顶层入口贪心下降到第 1 层
    ↓
第 0 层：宽度 ef_search 的束搜索，按距离输出
    ↓
返回 top-k 行（近似，非全局精确）
```

| 与 [FAISS IndexHNSWFlat](https://github.com/facebookresearch/faiss/wiki) / ANN 理论 §5.3 伪代码一致；差异在 **集成 PG 事务、MVCC、WAL**。

## 5. 与 IVFFlat 对比（在 pgvector 内）

| 维度 | HNSW | IVFFlat |
|---|---|---|
| 查询延迟 | 通常更低 | 依赖 `probes` |
| 建索引 | 慢 | 快（需先有数据） |
| 内存 | 大 | 小 |
| 空表建索引 | 可以 | 不推荐 |
| 参数旋钮 | `ef_search` | `ivfflat.probes` |
| 分布漂移 | 不依赖 k-means | 质心可能过时 |

单机、内存够、读多 → **HNSW** 是 pgvector 默认首选。

## 6. 部分索引与过滤

```sql
CREATE INDEX idx_hnsw_cat ON items
USING hnsw (embedding vector_l2_ops)
WHERE category_id = 123;

SELECT id FROM items
WHERE category_id = 123
ORDER BY embedding <-> $1
LIMIT 10;
```

过滤 + ANN 时结果可能 **少于 k**；可启用 iterative index scan 或增大 `ef_search`。

## 7. 维护

| 操作 | 行为 |
|---|---|
| `INSERT` | 在线插入节点、连边（触发索引更新） |
| `DELETE` | 逻辑删除 / tombstone，图不立即收缩 |
| `VACUUM` | 清理 dead tuple，影响可见性 |
| 大量删除后 | recall 可能降；考虑 `REINDEX` |

HNSW **删除** 与 FAISS 类似：长期 churn 后图质量退化（ANN §5.6）。

## 8. 实验模板

```sql
-- 固定 k=10，扫描 ef_search
-- recall 可用小表与 Seq Scan 结果对比

SET hnsw.ef_search = 40;
EXPLAIN (ANALYZE) SELECT id FROM items ORDER BY embedding <-> $1 LIMIT 10;

SET hnsw.ef_search = 200;
EXPLAIN (ANALYZE) SELECT id FROM items ORDER BY embedding <-> $1 LIMIT 10;
```

记录：延迟、`Buffers`、与 ground truth 的 id 交集比例。

## 9. 与 PostgreSQL 内核的衔接（后续深入）

读 pgvector 源码时可对照 PG Index AM 接口：

| 回调 | 作用 |
|---|---|
| `ambuild` | 初始建图或 bulk load |
| `aminsert` | 单行插入维护 HNSW |
| `amscan` / `amgettuple` | 按距离 ORDER BY 拉取 |
| `amcostestimate` | planner 选择是否用 HNSW |

WAL：索引页修改走 PG 缓冲池与 redo，**crash 后索引与堆一致**——这是相对单机 FAISS 的核心优势（见 ggnote `Distributed.md` / `FAISS.md` 工程层对比）。

## 10. 自检

1. 默认 `ef_search=40` 查 `LIMIT 100` 有何问题？→ 候选不足，recall 差。
2. HNSW 为何能在空表建索引？→ 无 k-means 训练依赖，随 insert 增图。
3. `m` 与 `ef_construction` 能否查询阶段修改？→ **不能**，仅建索引时固定；查询只调 `ef_search`。

## 11. 参考

- [pgvector HNSW](https://github.com/pgvector/pgvector#hnsw)
- 源码：`src/hnswbuild.c`、`src/hnswinsert.c`、`src/hnswscan.c`
