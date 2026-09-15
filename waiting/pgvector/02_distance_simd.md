# pgvector：距离函数与 SIMD

## 1. 查询怎么写

pgvector 用 **operator** 表达距离；`ORDER BY … LIMIT k` 即 top-k 近邻：

```sql
-- L2（欧氏距离，越小越近）
SELECT id, embedding <-> '[0.1,0.2,...]' AS dist
FROM items
ORDER BY embedding <-> '[0.1,0.2,...]'
LIMIT 10;

-- 余弦距离（越小越近；向量未归一化时与「夹角」相关）
SELECT id, embedding <=> query_vec AS dist FROM items
ORDER BY embedding <=> query_vec LIMIT 10;

-- 内积（负号：PG 索引仅支持 ASC 排序，故用 negative inner product）
SELECT id, embedding <#> query_vec AS neg_ip FROM items
ORDER BY embedding <#> query_vec LIMIT 10;
```

| 运算符 | 度量 | 说明 |
|---|---|---|
| `<->` | L2 | 欧氏距离 |
| `<=>` | cosine distance | $1 - \cos\theta$（与归一化后 L2 单调相关） |
| `<#>` | negative inner product | $-\sum a_i b_i$，升序 = 内积降序 |
| `<+>` | L1 |  taxicab 距离（0.7.0+） |

函数形式：`l2_distance(a,b)`、`cosine_distance(a,b)`、`inner_product(a,b)` 等，与运算符一致。

## 2. Operator Class 与索引

索引必须声明 **operator class**，使 Index AM 知道用哪种距离：

```sql
-- 每种距离各建一类（ excerpt ）
CREATE INDEX idx_l2    ON items USING hnsw (embedding vector_l2_ops);
CREATE INDEX idx_cos   ON items USING hnsw (embedding vector_cosine_ops);
CREATE INDEX idx_ip    ON items USING hnsw (embedding vector_ip_ops);
```

| operator class | 排序运算符 | 典型场景 |
|---|---|---|
| `vector_l2_ops` | `<->` | 图像、通用 L2 |
| `vector_cosine_ops` | `<=>` | 文本 embedding（常配合归一化） |
| `vector_ip_ops` | `<#>` | MIPS、推荐 |

**查询中的运算符必须与索引 operator class 一致**，否则无法走 ANN 索引（或语义错误）。

`halfvec_*_ops`、`sparsevec_*_ops`、`bit_*_ops` 同理。

## 3. 精确扫描 vs ANN 索引

```sql
-- 无索引或 planner 选 Seq Scan：全表 brute-force，100% recall
EXPLAIN (ANALYZE, BUFFERS)
SELECT id FROM items ORDER BY embedding <-> $1 LIMIT 10;

-- 有 hnsw / ivfflat 且 ORDER BY 匹配：近似最近邻
```

无索引时 pgvector 仍可用运算符，本质是对每行调用距离函数——与 FAISS `IndexFlat` 同类。

## 4. SIMD 实现（源码层）

距离热点在 **C 扩展** 中对 float 数组做点积 / L2。pgvector 编译时启用 **SIMD**（Single Instruction Multiple Data，单指令多数据）：

| 机制 | 说明 |
|---|---|
| 编译标志 | Makefile / CI 按平台加 `-mavx2`、`-mfma` 等 |
| 运行时 | 距离例程用 SIMD 一次处理多个 float（如 8 个 float32 / AVX256） |
| 回退 | 无 SIMD 的 CPU 走标量 loop |

阅读路径（[pgvector 仓库](https://github.com/pgvector/pgvector)）：

```
src/vector.c          -- vector 类型、距离函数入口
src/halfvec.c         -- half 精度
src/hnsw*.c           -- 建图 / 扫描时反复调距离
src/ivf*.c            -- 质心比较、list 内扫描
```

关注模式：**同一 `l2_distance` / `inner_product` 内核** 被 Seq Scan、IVFFlat、HNSW 共用；SIMD 加速的是 **单次距离**，不是索引结构本身。

与 ANN 理论（IVF 簇内扫描 vs HNSW 图遍历）：SIMD 加速 **单次距离**；HNSW 仍有图跳转开销。

## 5. 归一化与度量选型

```sql
-- 余弦检索常见写法：库内预归一化
UPDATE items SET embedding = l2_normalize(embedding);

CREATE INDEX ON items USING hnsw (embedding vector_cosine_ops);
-- 或归一化后用 vector_l2_ops，排序等价
```

| 目标 | 建议 |
|---|---|
| 仅方向 | `l2_normalize` + cosine 或 L2 |
| MIPS | `vector_ip_ops`，注意 magnitude bias |
| 与训练度量一致 | **建索引与查询同一 operator class** |

## 6. EXPLAIN 看什么

```sql
EXPLAIN (VERBOSE, COSTS OFF)
SELECT id FROM items ORDER BY embedding <-> $1 LIMIT 10;
```

- `Index Scan using idx_... on items` + `Order By: (embedding <-> …)` → 走 ANN
- `Seq Scan` + `Sort` → 暴力；数据量大时延迟高
- `Filter` / `WHERE` 与向量 ORDER 组合 → 可能降低 recall 或触发 iterative scan（见各索引文档）

## 7. 自检

1. 建了 `vector_l2_ops` 索引，查询用 `<=>` 会怎样？→ 通常不走该索引或语义不匹配。
2. SIMD 加速的是 IVFFlat 还是只加速 Flat？→ **距离内核**；IVF/HNSW 每次比较都调用，但 HNSW 还有图跳转开销。
3. `<#>` 为何是 negative inner product？→ PG 索引扫描只支持 **升序** 距离。

## 8. 参考

- [pgvector Distance Functions](https://github.com/pgvector/pgvector#distance-functions)
- PostgreSQL：`CREATE OPERATOR CLASS`、Index AM 与 opclass 绑定
