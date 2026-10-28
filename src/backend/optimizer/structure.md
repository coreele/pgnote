# Structure

## Overview

| 层    | 顶层类型                              | 谁产出              | 谁消费   | 生命周期                       |
| ----- | ------------------------------------- | ------------------- | -------- | ------------------------------ |
| Query | `Query`                               | analyzer + rewriter | planner  | 整个规划期                     |
| Path  | `PlannerInfo` / `RelOptInfo` / `Path` | planner             | planner  | 整个规划期，出 plan 后丢弃     |
| Plan  | `PlannedStmt` / `Plan`                | `create_plan`       | executor | 出 plan 后长期持有（计划缓存） |

## Explain

```sql
drop table if exists tb;
create table tb (a int, b bigint);
insert into tb select n, n from generate_series(1, 100000) as n;
create index idx on tb(a);
analyze tb;

explain select * from tb where a = 5432;
```

```text
 Index Scan using idx on tb  (cost=0.29..8.31 rows=1 width=12)
   Index Cond: (a = 5432)
```

| EXPLAIN 片段      | 结构体字段                                        |
| ----------------- | ------------------------------------------------- |
| `tb`              | `RelOptInfo`（`RELOPT_BASEREL`）/ `RangeTblEntry` |
| `using idx`       | `IndexPath.indexinfo` → `IndexOptInfo.indexoid`   |
| `cost=0.29..8.31` | `Path.startup_cost` / `Path.total_cost`           |
| `rows=1`          | `Path.rows`                                       |
| `width=12`        | `Path.pathtarget->width` ← `RelOptInfo.reltarget` |
| `Index Cond`      | `IndexPath.indexquals` → `IndexScan.indexqual`    |
| `Index Scan`      | `Path.pathtype = T_IndexScan` → `Plan.type`       |

## `PlannerInfo`

一条查询一个，`standard_planner()` 里创建。

```c
typedef struct PlannerInfo
{
    Query          *parse;             /* 输入 */
    PlannerGlobal  *glob;              /* 子查询共用 */
    Index           query_level;       /* 1 = 顶层 */

    /* 关系：按 RT index 索引 */
    struct RelOptInfo **simple_rel_array;
    RangeTblEntry     **simple_rte_array;

    /* 等价类 */
    List           *eq_classes;

    /* join 结果缓存 */
    List           *join_rel_list;
    struct HTAB    *join_rel_hash;

    /* join 之后逐层叠加的 upper rel */
    RelOptInfo     *upper_rels[UPPERREL_FINAL + 1];

    double          tuple_fraction;    /* LIMIT / cursor 的期望取行比例 */
    double          limit_tuples;
} PlannerInfo;
```

upper relation

join 之后不是"一串算子"，而是逐层叠加的 upper relation：

```text
base rel ──join──> join rel
                      │
    UPPERREL_PARTIAL_GROUP_AGG    并行部分聚合
    UPPERREL_GROUP_AGG            GROUP BY / 聚合
    UPPERREL_WINDOW               窗口函数
    UPPERREL_DISTINCT             DISTINCT
    UPPERREL_ORDERED              ORDER BY
    UPPERREL_FINAL                LIMIT / FOR UPDATE
```

`fetch_upper_rel(root, UPPERREL_FINAL, NULL)` 取最后一层，`get_cheapest_fractional_path()` 在它上面选路径。

## `RelOptInfo`

「一个关系 + 它的全部候选路径」。base rel 和 join rel 都是它。

```c
typedef struct RelOptInfo
{
    RelOptKind   reloptkind;    /* BASEREL / JOINREL / UPPERREL / OTHER_MEMBER_REL */
    Relids       relids;        /* 覆盖哪些 RT index */
    double       rows;          /* 估算输出行数 */
    PathTarget  *reltarget;     /* 需要输出的列（含 width） */

    List        *pathlist;              /* 候选路径，按 total_cost 升序 */
    struct Path *cheapest_startup_path;
    struct Path *cheapest_total_path;

    List        *baserestrictinfo;      /* WHERE 中只涉及本 rel 的条件 */
    List        *joininfo;              /* 涉及其他 rel 的条件 */

    bool         consider_startup;      /* 是否在意 startup cost */
    bool         consider_param_startup;
    bool         consider_parallel;
} RelOptInfo;
```

## `Path`

```text
Path
├── IndexPath
├── BitmapHeapPath
│   └── BitmapAndPath / BitmapOrPath（子节点是 BitmapIndexPath）
├── TidPath / SubqueryPath / ForeignPath / CustomPath
│
├── JoinPath
│   ├── NestPath
│   ├── MergePath
│   └── HashPath
│
├── AggPath / GroupingSetsPath
├── SortPath / IncrementalSortPath
├── AppendPath / MergeAppendPath
├── GatherPath / GatherMergePath
└── MaterialPath / MemoizePath / ResultPath / ProjectSetPath
```

`Path` 只描述「怎么取数、多少行、多少钱」，**不含表达式**；表达式在 `pathtarget` 和子类的 qual 字段里。

```c
typedef struct Path
{
    NodeTag      type;
    NodeTag      pathtype;      /* T_SeqScan / T_IndexScan / T_NestLoop ... */
    RelOptInfo  *parent;
    PathTarget  *pathtarget;    /* 输出列 */
    ParamPathInfo *param_info;  /* 参数化路径（NestLoop 内表） */
    bool         parallel_safe;

    double       rows;
    Cost         startup_cost;
    Cost         total_cost;
    List        *pathkeys;      /* 输出排序 */
} Path;
```

## 关键结构对照

| 结构          | 回答什么问题       | 定义位置            |
| ------------- | ------------------ | ------------------- |
| `PlannerInfo` | 这条查询规划到哪了 | `nodes/pathnodes.h` |
| `RelOptInfo`  | 这个关系有哪些走法 | `nodes/pathnodes.h` |
| `Path`        | 一种走法多少钱     | `nodes/pathnodes.h` |

## 待补

- [ ] `PathTarget` 为什么挂在 path 上，而不是 rel 上
- [ ] `ParamPathInfo`：参数化路径怎么表示
- [ ] `PlannerGlobal` vs `PlannerInfo` 的分工（子查询为何共用 glob）
- [ ] `RELOPT_OTHER_MEMBER_REL`：继承 / 分区场景
