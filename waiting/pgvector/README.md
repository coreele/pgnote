# pgvector 学习笔记

> 理论背景：IVF / HNSW / 距离度量（可参考 ggnote `Software/AI/ANN.md`）。

## 学习顺序


| #   | 文档                                           | 主题                           |
| --- | -------------------------------------------- | ---------------------------- |
| 1   | [01_type_typmod.md](./01_type_typmod.md)     | `vector` 类型、typmod、存储格式      |
| 2   | [02_distance_simd.md](./02_distance_simd.md) | 距离算子、operator class、SIMD     |
| 3   | [03_ivfflat.md](./03_ivfflat.md)             | IVFFlat 索引与 `ivfflat.probes` |
| 4   | [04_hnsw.md](./04_hnsw.md)                   | HNSW 索引与 `hnsw.ef_search`    |


## 环境准备

```sql
CREATE EXTENSION IF NOT EXISTS vector;

-- 验证
SELECT extversion FROM pg_extension WHERE extname = 'vector';
```

源码：[pgvector/pgvector](https://github.com/pgvector/pgvector)（C 扩展，挂接 PostgreSQL Index AM）。

## 与 PostgreSQL 内核的关系（读源码前）

```
SQL: CREATE INDEX ... USING hnsw / ivfflat
         ↓
Index AM（access method）回调：build / insert / scan
         ↓
距离计算：vector 类型 + operator class（vector_l2_ops 等）
         ↓
ANN 算法：IVFFlat（k-means 分 list）或 HNSW（分层图）
```

后续读 PG 源码时可对照：`src/backend/access/index/`、`nbtree` 的 Index AM 模式；pgvector 在独立 extension 里实现 `hnsw` / `ivfflat` AM。
