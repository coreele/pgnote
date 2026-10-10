# WHERE

只追 `WHERE`。同一条条件从 Parse 到 Exec 换了三次形态：语法树、带类型的表达式、隐式 AND 列表。Init 把列表编译成 step，Run 对每一行解释执行。

## Case

没有索引，计划落到 `SeqScan`。

```sql
DROP TABLE IF EXISTS tb;
CREATE TABLE tb (a int, b int);

INSERT INTO tb (a, b) VALUES
    (20, 1),    -- 两条 qual 都为 true，选中
    (3,  1),    -- 第一条为 false，EEOP_QUAL 跳到 DONE，不再看 b
    (20, NULL), -- 第一条为 true，第二条为 false
    (NULL, 1);  -- 第一条为 NULL，EEOP_QUAL 同样跳到 DONE

SELECT * FROM tb WHERE a + 1 > 10 AND b IS NOT NULL;
-- 只返回一行：(20, 1)
```

## 调用链

`exec_simple_query`（postgres.c）：

```text
pg_parse_query
    raw_parser                          -- gram.y
pg_analyze_and_rewrite_fixedparams
    parse_analyze                       -- transformSelectStmt
    pg_rewrite_query                    -- 本例没有视图和规则，原样返回
pg_plan_query
    planner
        subquery_planner
PortalStart
    ExecutorStart
        ExecInitSeqScan
            ExecInitQual
ExecutorRun
    ExecScan
        ExecQual
```

## 节点形态

```text
Parse     SelectStmt.whereClause
            BoolExpr AND
              A_Expr ">"
                A_Expr "+" (ColumnRef a, A_Const 1)
                A_Const 10
              NullTest IS_NOT_NULL (ColumnRef b)

Analyze   Query.jointree->quals          仍是一棵 BoolExpr
            BoolExpr AND
              OpExpr int4gt
                OpExpr int4pl (Var a, Const 1)
                Const 10
              NullTest (Var b)

Plan      jointree->quals                展成 List
            [ OpExpr int4gt ..., NullTest ... ]
          RelOptInfo.baserestrictinfo    每条包成 RestrictInfo
          SeqScan.plan.qual              还是这个 List

Exec      ExprState.steps
            FETCHSOME
            VAR(a) → CONST(1) → FUNCEXPR(+) → CONST(10) → FUNCEXPR(>) → QUAL
            VAR(b) → NULLTEST → QUAL
            DONE
```

## Parse

`where_clause`（gram.y:13699）取的就是一个 `a_expr`。

- `a AND b` → `makeAndExpr` → `BoolExpr(AND_EXPR)`（gram.y:14475）
- `a + 1`、`> 10` 都是 `A_Expr`，列名是 `ColumnRef`，数字是 `A_Const`
- `b IS NOT NULL` 是 `NullTest`（gram.y:14605）

产物在 `RawStmt.stmt`，类型 `SelectStmt`，条件在 `whereClause`。

## Analyze

`transformSelectStmt`（analyze.c）里：

```text
transformWhereClause          parse_clause.c:1848
    transformExpr             parse_expr.c
    coerce_to_boolean
makeFromExpr(..., qual)       放进 Query.jointree->quals
```

`transformExpr` 第一遍只看这几个 case：

| case          | 大约行           | 变成                                       |
| ------------- | ---------------- | ------------------------------------------ |
| `T_ColumnRef` | parse_expr.c:136 | `Var`                                      |
| `T_A_Const`   | :144             | `Const`                                    |
| `T_A_Expr`    | :165             | `OpExpr`（`+` → `int4pl`，`>` → `int4gt`） |
| `T_BoolExpr`  | :210             | 仍是 `BoolExpr`，递归变换参数              |
| `T_NullTest`  | :268             | 仍是 `NullTest`                            |

这一阶段 AND 还没拆开。

## Plan

`preprocess_qual_conditions`（planner.c:1233）对 `FromExpr.quals` 调 `preprocess_expression(..., EXPRKIND_QUAL)`。和本例有关的两步：

1. `canonicalize_qual`（planner.c:1184）：`pull_ands` 把嵌套 AND 摊平
2. `make_ands_implicit`（planner.c:1222）：顶层 AND 换成 `List`，两条子表达式各占一项

之后 `deconstruct_jointree` → `distribute_qual_to_rels`（initsplan.c:2155）给每条建一个 `RestrictInfo`，挂到 `RelOptInfo.baserestrictinfo`。生成 `SeqScan` 时这份列表抄进 `plan.qual`。

`ExecInitSeqScan`（nodeSeqscan.c:172）把 `plan.qual` 交给 `ExecInitQual`。

## Exec：Init

`ExecInitQual`（execExpr.c:213）：

1. 空列表返回 NULL，`ExecQual` 直接当 true
2. `makeNode(ExprState)`，置 `EEO_FLAG_IS_QUAL`
3. `ExecCreateExprSetupSteps`：头部放 `EEOP_SCAN_FETCHSOME`
4. 每条子表达式 `ExecInitExprRec` 之后压一个 `EEOP_QUAL`
5. 把每个 `jumpdone` 补成数组末尾，追加 `EEOP_DONE`，`ExecReadyExpr`

`EEOP_QUAL` 在结果为 false 或 NULL 时跳到 `DONE`。

`ExecInitExprRec` 第一遍只看：

| case         | 大约行            | 会变成什么                                    |
| ------------ | -------------- | ---------------------------------------- |
| `T_Var`      | execExpr.c:905 | `EEOP_SCAN_VAR`                          |
| `T_Const`    | :961           | `EEOP_CONST`                             |
| `T_OpExpr`   | :1132          | `EEOP_FUNCEXPR*`，参数直接写进 `fcinfo->args[]` |
| `T_NullTest` | :2394          | `EEOP_NULLTEST_ISNOTNULL`                |

## Exec：Run

`ExecScan`（execScan.c:165）每次被上层拉取时：

1. `ResetExprContext`，清掉上一行留下的 per-tuple 内存
2. 循环 `ExecScanFetch` 取 slot，放进 `econtext->ecxt_scantuple`
3. `ExecQual`（executor.h:416）为 false 就丢弃，继续取下一行；为 true 才把这行交出去

`ExecQual` 本身很短：`state == NULL` 直接返回 true；否则 `ExecEvalExprSwitchContext` 切到 per-tuple 上下文，调用 `state->evalfunc`。默认是 `ExecInterpExpr`（execExprInterp.c:395），从 `steps[0]` 派发，`EEO_NEXT` 顺序走到下一步，`EEO_JUMP` 跳到下标。

和本例有关的 case：

| opcode                    | 大约行               | 做什么                                                                          |
| ------------------------- | -------------------- | ------------------------------------------------------------------------------- |
| `EEOP_SCAN_FETCHSOME`     | execExprInterp.c:550 | 把 `ecxt_scantuple` 里用到的列 deform 出来                                      |
| `EEOP_SCAN_VAR`           | :589                 | 按下标取列，写入 `resvalue` / `resnull`                                         |
| `EEOP_CONST`              | :705                 | 写入常量                                                                        |
| `EEOP_FUNCEXPR_STRICT`    | :741                 | 参数有 NULL 则结果为 NULL，不调用函数；否则调用 `int4pl` / `int4gt`             |
| `EEOP_NULLTEST_ISNOTNULL` | :992                 | 结果是 `!resnull`，本身不为 NULL                                                |
| `EEOP_QUAL`               | :929                 | `resnull` 或 false 时把结果改成 false，`EEO_JUMP` 到 `DONE`；true 则 `EEO_NEXT` |
| `EEOP_DONE`               | :527                 | 返回。`ExecQual` 对 `resvalue` 做 `DatumGetBool`                                |

四行数据走到的位置：

| 行           | 第一条 `QUAL`                                                         | 第二条 `QUAL`                       | `ExecQual` |
| ------------ | --------------------------------------------------------------------- | ----------------------------------- | ---------- |
| `(20, 1)`    | true，继续                                                            | true，继续                          | true       |
| `(3, 1)`     | `4 > 10` 不成立，跳到 `DONE`                                          | 不执行                              | false      |
| `(20, NULL)` | true，继续                                                            | `IS NOT NULL` 为 false，跳到 `DONE` | false      |
| `(NULL, 1)`  | `int4pl` 因 NULL 短路，比较结果为 NULL，`QUAL` 当成 false 跳到 `DONE` | 不执行                              | false      |

## 先别看

常量折叠、等价类、索引条件下推、JIT。`execExprInterp.c` 后半的 JSON、数组、SRF 也先跳过。

## 看完应能回答

- Parse 结束时 AND 是什么节点？Analyze 之后它还在吗？
- `List` 是在哪一步出现的，出现之前 AND 长什么样？
- `SeqScan.plan.qual` 里有几项，和 `EEOP_QUAL` 的个数是什么关系？
- `(3, 1)` 和 `(NULL, 1)` 分别是在哪个 opcode 上离开 step 数组的？
- `ExecQual` 返回的 bool 是哪个 step 写进 `resvalue` 的？
