# pgvector：vector 类型与 Typmod

## 1. 基本用法

```sql
CREATE TABLE items (
    id    bigserial PRIMARY KEY,
    embedding vector(3)   -- typmod = 3，固定 3 维
);

INSERT INTO items (embedding) VALUES ('[1,2,3]'), ('[4,5,6]');

-- 不声明维度（typmod = -1）
CREATE TABLE loose (v vector);
INSERT INTO loose VALUES ('[1,2,3]'), ('[1,2]');  -- 允许不同维，但不利于约束
```

文本输入格式：`[1,2,3]`（float32 字面量，逗号分隔）。

## 2. Typmod 是什么

PostgreSQL **type modifier（类型修饰符）** 在列定义时固定元数据。对 `vector(n)`：


| 项目  | 说明                                                   |
| --- | ---------------------------------------------------- |
| 声明  | `vector(768)` 表示列必须是 768 维                           |
| 存储  | typmod 存维度 $d$，写入时 `CheckExpectedDim()` 校验           |
| 未限定 | `vector` 无 typmod（-1），仅校验 `1 ≤ dim ≤ VECTOR_MAX_DIM` |


源码入口（pgvector）：

- `vector_typmod_in`：解析 `(768)` → typmod
- `CheckExpectedDim`：插入 / 索引与列 typmod 不一致则报错



## 3. 类型族与维度上限


| 类型          | 元素         | 每维存储      | 列最大维度                | 索引最大维度（HNSW / IVFFlat） |
| ----------- | ---------- | --------- | -------------------- | ---------------------- |
| `vector`    | float32    | 4 B       | 16,000               | **2,000**              |
| `halfvec`   | float16    | 2 B       | 16,000               | **4,000**              |
| `sparsevec` | 稀疏 float32 | 8 B × nnz | 10⁹ 维声明，nnz ≤ 16,000 | nnz ≤ 1,000            |
| `bit`       | 二值         | 1 bit     | 64,000               | 64,000                 |


索引维度上限 **小于** 类型上限，主要受 PostgreSQL **8KB 页面** 与索引元组布局约束（高维需 `halfvec` / 量化 / 表达式索引）。

常见 embedding 模型维度：384、768、1536、3072——超过 2000 时需 `halfvec(3072)` 或量化方案（见官方 README *Halfvec* / *Binary Quantization*）。

## 4. 内存布局（概念）

`vector` 在磁盘 / 内存中为 **变长类型（varlena）**：

```
┌──────────────┬─────────────────────────┐
│  dim (int16) │  float32 × dim          │ 
└──────────────┴─────────────────────────┘
```

- 与 PG `float4[]` 不同：`vector` 是单一标量类型，自带维度头，便于索引 AM 按固定 stride 做 SIMD 距离。
- TOAST：极大向量可能 TOAST，但常规 embedding 维度通常 inline。



## 5. 与 embedding 管道对齐

```sql
-- 模型输出 1536 维 float32
ALTER TABLE docs ADD COLUMN emb vector(1536);

-- 应用写入前确保维度一致；typmod 在 DB 层兜底
```

**实践规则**：

1. 生产列 **始终** `vector(d)` / `halfvec(d)` 带 typmod，与模型 `d` 一致。
2. 换模型改维度 → `ALTER COLUMN TYPE vector(new_d)` + **重建索引**。
3. 同一表多种模型 → 分表或 `(model_id, embedding)` + 部分索引（`WHERE model_id = …`）。



## 6. 自检

1. `vector(768)` 插入 512 维向量会怎样？→ typmod 校验失败。
2. 为何索引限制 2000 维而类型支持 16000 维？→ 索引页内存储与 AM 设计，非类型本身。
3. `halfvec` 相对 `vector` 的核心 trade-off？→ 一半存储、更高可索引维度，精度略降。



## 7. 参考

- [pgvector Vector Types](https://github.com/pgvector/pgvector#vector-type)
- 源码：`src/vector.c`（`vector_in` / `CheckExpectedDim` / `vector_typmod_in`）

