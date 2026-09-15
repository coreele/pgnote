# SQL cases

## 单表扫描方式

1. 堆表直接扫描（无索引依赖，最基础）
   1. Seq Scan（Sequential Scan，全表顺序扫描）
   2. Sample Scan（Table Sample Scan，表采样扫描）
2. 索引相关扫描（补充你提到的，进阶高效）
   1. Index Only Scan（仅索引扫描，效率天花板）
   2. Partial Index Scan（部分索引扫描）
   3. Bitmap Heap Scan（位图堆扫描，配套 Bitmap Index Scan）
3. 特殊扫描方式（小众但实用，适合源码拓展学习）
   1. Tid Scan（CTID Scan，物理位置扫描）
   2. Function Scan（函数扫描）
   3. Values Scan（值列表扫描）
   4. Subquery Scan（子查询扫描）

| 扫描类型                 | 依赖资源      | 核心特点                | 适用场景                           |
| -------------------- | --------- | ------------------- | ------------------------------ |
| `Seq Scan`           | 堆表（无索引）   | 顺序遍历全表，兜底选择         | 表极小、匹配行数极多、无可用索引               |
| `Sample Scan`        | 堆表（无索引）   | 随机采样部分数据，无需全表扫描     | 大数据量表的快速统计分析（无需精确结果）           |
| `Index Scan`         | 完整索引      | 索引 → 堆表一对一串行遍历，边查边取 | 匹配行数极少（如主键查询）、需按索引排序           |
| `Index Only Scan`    | 覆盖索引+VM   | 无需访问堆表，直接从索引提取所有列   | 查询列全在索引中、VM 可确认可见性             |
| `Partial Index Scan` | 部分索引      | 仅遍历索引的部分数据，减少索引 IO  | 查询条件与部分索引创建条件匹配                |
| `Bitmap Index Scan`  | 索引        | 先收集所有匹配位置生成位图，不访问堆表 | 匹配行数中等、需多索引合并                  |
| `Bitmap Heap Scan`   | 堆表+位图     | 批量访问堆表，重校验条件和可见性    | 配套`Bitmap Index Scan`，批量处理中等行数 |
| `Tid Scan`           | 行 ctid    | 直接定位物理位置，无需索引       | 调试场景、已知行的 ctid                 |
| `Function Scan`      | 表函数       | 扫描函数返回的表类型结果集       | 调用内置/自定义表函数                    |
| `Values Scan`        | VALUES 子句 | 扫描临时值列表，作为虚拟表       | 查询/连接 VALUES 生成的临时数据           |
| `Subquery Scan`      | 子查询结果集    | 扫描子查询返回的结果集，作为虚拟表   | FROM 子句包含子查询                   |

## SQL seqScan

```sql
SET debug_print_parse = on;

DROP TABLE IF EXISTS tb;

CREATE TABLE tb (a int, b  int, c int);

INSERT INTO tb (a, b, c) SELECT n, n * 10, n * 100 FROM generate_series(1, 5) AS n;

-- 查询所有
select * from tb;

-- 带过滤查询
select * from tb where a < 3;

-- 带投影查询
SELECT a, b FROM tb WHERE a = 5;

-- 带排序查询
SELECT a, b FROM tb WHERE a = 5 order by a;
```

## SQL indexScan

```sql
truncate table tb;
INSERT INTO tb (a, b) SELECT DISTINCT (random() * 2000)::int, (random() * 10000)::int FROM generate_series(1, 10000) AS n LIMIT 10000;
create index idx on tb(a);

SELECT * FROM tb WHERE a = 2;
```

## SQL hashScan

```sql
-- 先删除之前的B-Tree索引
DROP INDEX IF EXISTS idx;

-- 创建Hash索引（PG支持的索引类型之一，适用于等值查询）
CREATE INDEX idx_hash ON tb USING hash (a);

-- 等值查询（触发Hash索引扫描）
SELECT * FROM tb WHERE a = 2;

-- 查看执行计划（确认Hash Scan）
EXPLAIN SELECT * FROM tb WHERE a = 2;
```

## rewrite

```sql
CREATE VIEW vu AS SELECT * FROM tb;

SELECT * FROM vu WHERE a = 2;
```

## 隐式事务

```sql
SELECT * FROM tb;
```

## 子事务

```sql
-- 回滚
SELECT 1 / 0;

SELECT 1;
```

## Extended Query（P/B/E）

```sql
PREPARE stmt(int) AS
SELECT * FROM tb WHERE a = $1;

EXECUTE stmt(2);
```

## Portal 的多次执行

```sql
PREPARE stmt(int) AS
SELECT * FROM tb WHERE a > $1;

EXECUTE stmt(1);
EXECUTE stmt(2);
```

## Full Select

```sql
-- 创建订单表
CREATE TABLE orders (
    order_id serial PRIMARY KEY,
    customer_id int,
    region text,
    amount numeric,
    order_date date
);

-- 填充模拟数据：3个区域，100个客户，共1000条订单
INSERT INTO orders (customer_id, region, amount, order_date)
SELECT 
    (floor(random() * 100) + 1)::int,          -- 100个随机客户
    (ARRAY['North', 'South', 'East'])[floor(random() * 3) + 1], -- 3个区域
    (random() * 500)::numeric(10,2),           -- 随机金额
    '2025-01-01'::date + (random() * 365)::int -- 2025年内的随机日期
FROM generate_series(1, 1000);

-- 建立一个索引，观察优化器是否会利用它来“加速水流”
CREATE INDEX idx_orders_region_customer ON orders(region, customer_id);
```