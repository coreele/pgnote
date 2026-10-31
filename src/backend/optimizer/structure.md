# Structure

## Level

| 层       | 顶层类型                              | 消费        | 文件         |
| -------- | ------------------------------------- | ----------- | ------------ |
| Query    | `Query`                               | optimizer   | parsenodes.h |
| **Path** | `PlannerInfo` / `RelOptInfo` / `Path` | create_plan | pathnodes.h  |
| Plan     | `PlannedStmt` / `Plan`                | executor    | plannodes.h  |

## `PlannerInfo`

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

## `RelOptInfo`

PostgreSQL 查询优化的核心数据结构，用于表示查询规划过程中出现的所有类型的关系。

- 基础关系：表示 FROM 子句中的单表、子查询或函数
- 连接关系：表示两个或多个基础关系连接后的结果
- 其他关系：表示追加关系成员这类特殊关系类型
- 上层关系：表示扫描/连接之后的处理步骤，例如聚合、排序等

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

scan/join 之后不是"一串算子"，而是逐层叠加的 upper relation：

```text
    UPPERREL_FINAL                LIMIT / FOR UPDATE
	UPPERREL_ORDERED              ORDER BY
	UPPERREL_DISTINCT             DISTINCT
	UPPERREL_WINDOW               窗口函数
	UPPERREL_GROUP_AGG            GROUP BY / 聚合
	UPPERREL_PARTIAL_GROUP_AGG    并行部分聚合
	        │
base/join relation
```

## `Path`

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

`Path` 只描述「怎么取数、多少行、多少钱」，**不含表达式**；表达式在 `pathtarget` 和子类的 qual 字段里。

```text
Path(used as-is for sequential-scan)
├── IndexPath
├── BitmapHeapPath
│   └── BitmapAndPath / BitmapOrPath（子节点是 BitmapIndexPath）
├── TidPath / SubqueryPath / ForeignPath / CustomPath
├── JoinPath
│   ├── NestPath
│   ├── MergePath
│   └── HashPath
├── AggPath / GroupingSetsPath
├── SortPath / IncrementalSortPath
├── AppendPath / MergeAppendPath
├── GatherPath / GatherMergePath
└── MaterialPath / MemoizePath / ResultPath / ProjectSetPath
```
