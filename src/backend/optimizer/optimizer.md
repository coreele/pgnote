# optimizer

`optimizer/` 把 `Query` 变成可执行的 `PlannedStmt`。

|子目录|责任|
|---|---|
|prep/|规划前预处理：规范化 qual、改写 jointree、展开 UNION/继承、聚合预处理、目标列整理等|
|path/|生成/比较 Path：基表扫描、join 枚举、代价与选择率、等价类、pathkeys|
|geqo/|表很多时用遗传算法搜 join 顺序（替代穷举 DP）；具体某种 join 仍交给 path 估代价|
|plan/|总控与落地：`planner`/`planmain` 驱动流程，`createplan` 把最优 Path 收成 Plan，还有子查询、setrefs、join 消除等|
|util/|共用基础设施：RelOptInfo/Path 节点构造、RestrictInfo、表达式工具、tlist、继承/append 映射等|
