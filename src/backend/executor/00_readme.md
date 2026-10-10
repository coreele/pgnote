src/backend/executor/README

# Postgres 执行器（The Postgres Executor）

执行器处理的是一棵"计划节点"（plan node）树。计划树本质上是一条**需求驱动（demand-pull）的元组处理流水线**：每个节点被调用时，产出其输出序列中的下一个元组；若没有更多元组，则返回 NULL。如果节点不是最底层的关系扫描节点，它会有子节点，并依次调用子节点来获取输入元组。

在这一基本模型之上还有以下扩展：

- **扫描方向的选择**（正向或反向）。注意：目前对此支持得并不好。它对基础扫描节点有效，但对连接、聚合等节点效果不佳。
- **Rescan 命令**：重置一个节点，使其重新生成输出序列。
- **参数（Parameters）**：参数可以改变节点的结果。调整参数后，必须对该节点及其上方所有节点执行 rescan。系统有一套还算智能的机制来避免不必要的 rescan（例如，如果 Sort 输入的参数都没变，Sort 就不会 rescan 其输入，因为它可以直接重读已排好序的存储数据）。

对于 SELECT，只需要把顶层结果元组交付给客户端。对于 INSERT/UPDATE/DELETE/MERGE，实际的表修改操作发生在顶层的 **ModifyTable** 计划节点中。如果查询包含 RETURNING 子句，ModifyTable 节点会把计算出的 RETURNING 行作为输出交付，否则它什么也不返回。

- **INSERT** 的处理非常直接：ModifyTable 下方计划树返回的元组被插入到对应的结果关系中。
- **UPDATE**：计划树返回被更新列的新值，外加用于标识要更新哪一行的"垃圾"（junk，隐藏）列。ModifyTable 节点必须取出该行以提取未变更列的值，把这些值组合成新行，再执行更新。（对于 heap 表，行标识 junk 列是 CTID，但其他表类型可能使用别的东西。）
- **DELETE**：计划树只需交付 junk 行标识列，ModifyTable 节点逐一访问这些行并将其标记为已删除。
- **MERGE** 见下文。

XXX 这里还需要补写大量文档……

## 计划树与状态树（Plan Trees and State Trees）

规划器交付的计划树由 Plan 节点组成（由 `struct Plan` 派生的结构体类型）。在执行器启动期间，我们会构建一棵**结构完全相同的平行树**，由执行器状态节点组成 —— 一般来说，每种计划节点类型都有一种对应的执行器状态节点类型。状态树中的每个节点都持有指向计划树中对应节点的指针，以及实现该节点类型所需的执行器状态数据。

这种安排使得计划树对执行器而言**完全只读**：执行期间被修改的所有数据都在状态树中。只读的计划树让计划缓存与复用变得简单得多。

如果执行器判定某个子计划完全不需要（因为执行期分区裁剪确定那里找不到匹配记录），那么在执行器启动期间可能不会为它创建对应的状态节点。目前这只发生在 Append 和 MergeAppend 节点上。在这种情况下，不需要的子计划被忽略，执行器状态的子节点数组将与计划的子计划列表不再一一对应。

每个 Plan 节点可能关联若干表达式树，用来表示其目标列表、限定条件等。这些树对执行器同样是只读的，但表达式求值的执行器状态**并不镜像** Plan 表达式的树形结构，下文会解释。实际上每棵表达式树只有一个 ExprState 节点，不过对于某些复杂的表达式节点类型，它可能带有子节点。

总的来说，这些树中使用了四类节点：**Plan** 节点、对应的 **PlanState** 节点、**Expr** 节点和 **ExprState** 节点。（实际上还有 List 节点，在这三种树形表示中充当"胶水"。）

## 表达式树与 ExprState 节点（Expression Trees and ExprState nodes）

与计划树不同，表达式树**不会**被镜像成一棵对应的状态节点树。每棵可独立执行的表达式树（例如某个 Plan 的 qual 或 targetlist）由**一个** ExprState 节点表示。ExprState 节点包含以紧凑、线性形式对表达式求值所需的信息。这种紧凑形式以扁平数组存放在 `ExprState->steps[]` 中（是 `ExprEvalStep` 数组，而非 `ExprEvalStep *` 数组）。

选择这种表示的原因包括：

- 通常，求值一个 Expr 类型节点所需的工作量很小，因此求值期间遍历树的开销就显得很可观。
- 扁平表示可以在单个函数内非递归地求值，减少栈深度和函数调用开销。
- 这种表示既可用于快速的解释执行，也可用于编译成本地代码（JIT）。

表达式的 Plan 树表示由 `ExecInitExpr()` 编译成 ExprState 节点。应当尽可能把复杂性放在 `ExecInitExpr()`（及其辅助函数）中处理，而不是放在执行期 —— 否则解释执行和编译执行两个版本都得处理这些复杂性。除了在两种执行方式间重复劳动之外，运行时的初始化检查在每次表达式求值时也会带来虽小但可察觉的开销。

因此，我们允许 `ExecInitExpr()` 预先计算那些在单个查询执行期间不会变化的信息，例如要应用于某个域类型的 CHECK 约束表达式集合。这类信息无法在规划期完成，否则会大大增加需要使计划失效的事件数量。（以前，部分此类信息会在每次表达式求值时重新检查，但这似乎是不必要的开销。）

## 表达式初始化（Expression Initialization）

在 `ExecInitExpr()` 及类似例程执行期间，Expr 树被转换为扁平表示。每个 Expr 节点可能由零个、一个或多个 ExprEvalStep 表示。

每个 ExprEvalStep 的工作由其操作码（`enum ExprEvalOp`）决定，它把结果存入 `ExprEvalStep->resvalue/resnull` 所指向的 Datum 变量和布尔 null 标志变量中。复杂的表达式通过把多个 step 串联起来完成。

例如，`"a + b"`（一个 OpExpr，带两个 Var 表达式）会被表示为：两个获取 Var 值的 step，加上一个对 `+` 运算符底层函数求值的 step。两个 Var step 的 `resvalue/resnull` 直接指向函数求值 step 所用的 `FunctionCallInfoBaseData` 结构体中对应的 `args[].value / .isnull` 元素，从而避免了来回复制结果值的额外工作。

一个完整的 `ExprState->steps` 数组的最后一项总是 `EEOP_DONE` step，这样迭代时就无需检测是否到达数组末尾。另外，如果表达式包含任何变量引用（引用 ExprContext 的 INNER、OUTER 或 SCAN 元组中的用户列），steps 数组会以 `EEOP_*_FETCHSOME` step 开头，确保相关元组已被解构（deform），所需列可直接访问（参见 `slot_getsomeattrs()`）。这样每个获取 Var 的 step 就几乎只是一次数组查找。

`ExecInitExpr()` 的大部分工作由递归函数 `ExecInitExprRec()` 及其子例程完成。`ExecInitExprRec()` 把一个 Expr 节点映射为执行所需的 step，并按需对子表达式递归。

每次调用 `ExecInitExprRec()` 都必须指定该子表达式结果的存放位置（通过 `resv/resnull` 参数）。这使得上述"直接把（子）表达式求值到 `fcinfo->args[].value/isnull`"的做法成为可能，但也需要小心：目标 Datum/isnull 变量不能与另一个 `ExecInitExprRec()` 共享，除非其结果只被那些在该目标变量下一次被使用之前执行的 step 所需要。由于 ExprEvalStep 表示是非递归的，这一点通常很容易保证。

`ExecInitExprRec()` 使用 `ExprEvalPushStep()` 把新操作压入 `ExprState->steps` 数组。为了让 steps 保持为连续布局的数组，当空间不足时 `ExprEvalPushStep()` 必须 repalloc 整个数组。因此，在表达式初始化期间**不允许直接指向任何 step**。所以子表达式的 `resv/resnull` 通常指向与 steps 数组分开 palloc 的存储。例如，函数调用 step 的 `FunctionCallInfoBaseData` 是单独分配的，而不是 ExprEvalStep 数组的一部分。整个表达式的最终结果通常返回到 ExprState 节点自身的 `resvalue/resnull` 字段中。

某些 step（例如布尔表达式）允许跳过某些子表达式的求值。在扁平表示中，这相当于跳转到后面的某个 step，而不是继续顺序执行下一个 step。跳转目标用下一个要执行的 step 在 `ExprState->steps` 数组中的整数下标表示。（对照 `execExprInterp.c` 中的 `EEO_NEXT` 和 `EEO_JUMP` 宏。）

通常，`ExecInitExprRec()` 需要先向 steps 数组压入一个跳转 step，然后递归生成可能被跳过的子表达式的 step，最后再回头用子表达式 step 的已知长度修正跳转目标下标。这由 `execExpr.c` 中的 `adjust_jumps` 列表处理。

构造 ExprState 的最后一步是调用 `ExecReadyExpr()`，它根据所选的执行方式让表达式进入可执行状态。

## 表达式求值（Expression Evaluation）

为了支持不同的表达式求值方法，并获得更好的分支/跳转目标预测，表达式通过调用 `ExprState->evalfunc` 来求值（经由 `ExecEvalExpr()` 等函数）。

`ExecReadyExpr()` 可以通过设置 `evalfunc` 为合适的函数来选择解释方式。默认的执行函数 `ExecInterpExpr` 实现于 `execExprInterp.c`，详见其头部注释。对某些特别简单的表达式会使用专门的 evalfunc。

注意，许多较复杂的表达式求值 step（其性能不如简单 step 那么关键）被实现为表达式执行快速路径之外的独立函数，从而让解释执行和编译执行共享这些实现。这意味着这些辅助函数**不允许自己做表达式 step 分派**，因为分派方式随调用方而变化。因此辅助函数不能调用子表达式的执行；它们需要的所有子表达式结果都必须由更早的 step 计算好。对下一个表达式 step 的分派必须在辅助函数返回之后进行。

## 目标列表求值（Targetlist Evaluation）

`ExecBuildProjectionInfo` 构建一个 ExprState，其效果是把 targetlist 求值到 `ExprState->resultslot` 中。通用的 targetlist 表达式按上述方式求值（结果存入 ExprState 的 `resvalue/resnull` 字段），然后用一个 `EEOP_ASSIGN_TMP` step 把结果移动到结果 slot 中对应的 `tts_values[]` 和 `tts_isnull[]` 数组元素里。对于只是简单 Var 的 targetlist 项，有专门的快速路径 step 类型（`EEOP_ASSIGN_*_VAR`），只用一个 step 而不是两个。

## MERGE

MERGE 是一个**多表、多动作**的命令：它指定一张目标表和一个源关系，并可包含多个 WHEN MATCHED 和 WHEN NOT MATCHED 子句，每个子句指定一个 UPDATE、INSERT、DELETE 或 DO NOTHING 动作。目标表被 MERGE 修改，源关系为这些动作提供额外数据。每个动作可选地指定一个限定表达式，对每个元组求值。

在规划器中，`transform_MERGE_to_join` 在目标表和源关系之间构造一个连接，并带上来自目标表的行标识 junk 列。如果 MERGE 命令包含任何 WHEN NOT MATCHED 子句，这个连接就是外连接；ModifyTable 节点从该连接的计划树中取元组。

- 如果取出元组中的行标识列为 NULL，说明源关系中这个元组在目标表中没有匹配，于是对该计划返回的元组依次求值每个 WHEN NOT MATCHED 子句的限定表达式。若表达式返回 true，就执行该子句指定的动作，不再求值后续子句。
- 反之，如果行标识列不为 NULL，就可以取出目标表中匹配的元组；然后结合取出的元组和计划返回的元组，求值每个 WHEN MATCHED 子句的限定表达式。

如果没有 WHEN NOT MATCHED 子句，规划器构造的连接就是内连接，行标识 junk 列总是非 NULL。

如果 WHEN MATCHED 处理的行被并发更新或删除，就使用 EvalPlanQual（见下文）找到该行的最新版本并重新取出；如果它仍存在，就从头开始重新寻找匹配的 WHEN MATCHED 子句。

MERGE 没有自己的触发器类型，而是触发 UPDATE、DELETE 和 INSERT 触发器：行级触发器在对某行执行动作时针对该行触发；语句级触发器总是触发，无论是否有行匹配对应子句。

## 内存管理（Memory Management）

`CreateExecutorState()` 期间会创建一个 **"per query"（每查询）内存上下文**；一次执行器调用期间分配的所有存储都分配在该上下文或其子上下文中。这样执行器关闭时就能轻松回收存储 —— 不必逐个 pfree、也不必担心可能的存储泄漏，直接销毁这个内存上下文即可。

特别地，前文所述的计划状态树和表达式状态树都分配在 per-query 内存上下文中。

为避免查询内部的内存泄漏，查询运行期间的大部分处理都在 **"per tuple"（每元组）内存上下文**中完成，之所以这么叫，是因为它们通常每处理一个元组就重置为空。per-tuple 上下文通常与 ExprContext 关联，并且通常每个 PlanState 节点都有自己的 ExprContext，用于求值其 qual 和 targetlist 表达式。

## 查询处理控制流（Query Processing Control Flow）

以下是完整查询处理的控制流概要：

```text
CreateQueryDesc

ExecutorStart
	CreateExecutorState
		creates per-query context
	switch to per-query context to run ExecInitNode
	AfterTriggerBeginQuery
	ExecInitNode --- recursively scans plan tree
		ExecInitNode
			recurse into subsidiary nodes
		CreateExprContext
			creates per-tuple context
		ExecInitExpr

ExecutorRun
	ExecProcNode --- recursively called in per-query context
		ExecEvalExpr --- called in per-tuple context
		ResetExprContext --- to free memory

ExecutorFinish
	ExecPostprocessPlan --- run any unfinished ModifyTable nodes
	AfterTriggerEndQuery

ExecutorEnd
	ExecEndNode --- recursively releases resources
	FreeExecutorState
		frees per-query context and child contexts

FreeQueryDesc
```

如上所述，`ExecEndNode` 释放内存并不是关键，因为在 `FreeExecutorState` 中这些内存终究都会被释放。但我们确实需要小心地关闭关系、释放 buffer pin 等，所以仍然需要扫描计划状态树来找到这类资源。

执行器也可以用于在没有 Plan 树的情况下求值简单表达式（"简单"指"没有聚合、没有子查询"，尽管它们可能隐藏在函数调用内部）。这种情况的控制流如下：

```text
CreateExecutorState
	creates per-query context

CreateExprContext	-- or use GetPerTupleExprContext(estate)
	creates per-tuple context

ExecPrepareExpr
	temporarily switch to per-query context
	run the expression through expression_planner
	ExecInitExpr

Repeatedly do:
	ExecEvalExprSwitchContext
		ExecEvalExpr --- called in per-tuple context
	ResetExprContext --- to free memory

FreeExecutorState
	frees per-query context, as well as ExprContext
	(a separate FreeExprContext call is not necessary)
```

## EvalPlanQual（READ COMMITTED 下的更新检查）

对于简单的 SELECT，执行器只需关注那些按当前事务所见快照有效的元组（即：由先前已提交的事务插入，且未被任何先前已提交的事务删除）。但对于 UPDATE、DELETE 和 MERGE，去修改或删除一个已被某个未结束的、或并发提交的事务修改过的元组是不行的。如果运行在 SERIALIZABLE 隔离级别，发现这种情况时直接报错即可。在 READ COMMITTED 隔离级别下，我们必须做更多的工作。

READ COMMITTED 模式下的基本思路是：取出并发事务提交的那个已修改元组（必要时先等待该事务提交），然后**重新求值查询的限定条件**，看它是否仍满足条件。如果满足，就基于这个已修改元组重新生成更新后的元组（如果是 UPDATE），最后对这个已修改元组执行更新/删除。SELECT FOR UPDATE/SHARE 的行为类似，只不过它的动作仅仅是锁住已修改元组，并基于该版本的元组返回结果。

为了实现这种检查，我们实际上会针对每个被修改的元组（或者对 SELECT FOR UPDATE 而言，每组元组）**从头重新运行查询**，同时调整关系扫描节点，使其只返回当前元组 —— 要么是原来的那些，要么是被修改（且现已加锁）的元组的更新版本。如果这次查询返回了元组，说明被修改的元组通过了限定条件（如果是 UPDATE，查询输出就是相应修改后的更新元组）。如果没有返回元组，说明被修改的元组未通过限定条件，于是我们忽略当前结果元组，继续原查询。

在 UPDATE/DELETE/MERGE 中，只有目标关系需要这样处理。在 SELECT FOR UPDATE 中，可能有多个关系被标记为 FOR UPDATE，因此在执行重检之前，我们要对每个这样的关系中的当前元组版本加锁。

查询中也可能存在不需要加锁的关系（它们既不是 UPDATE/DELETE/MERGE 的目标，也没有在 SELECT FOR UPDATE/SHARE 中被指定加锁）。重新运行测试查询时，我们希望从这些关系中使用与被锁定行连接过的同一批行。对于普通关系，这可以较廉价地实现：在连接输出中包含行的 TID，然后按 TID 重新获取。（重新获取代价较高，但我们优化的目标是不需要重检的常规情况。）我们还必须考虑非表关系，例如 ValuesScan 或 FunctionScan。由于它们没有等价于 TID 的东西，唯一可行的方案似乎是在连接输出行中包含整行值。

我们禁止在 SELECT FOR UPDATE 的 targetlist 中使用返回集合的函数（SRF），以确保对于任意一组特定的扫描元组，最多只返回一个元组。否则，原查询多次返回同一组扫描元组时会产生重复。同样，UPDATE 的 targetlist 中也禁止使用 SRF：那会导致同一行被更新多次，这没什么用 —— 而且第一次之后的更新反正也不会生效。

## 异步执行（Asynchronous Execution）

当某个节点在等待数据库系统之外的事件时（例如 ForeignScan 在等待网络 I/O），我们希望该节点能表示"现在无法立即返回任何元组，但稍后也许可以"。发现这种情况的进程总可以简单地阻塞等待，但这可能浪费时间 —— 这些时间本可以用来执行计划树中能立即取得进展的其他部分。当计划树中包含 Append 节点时，这种情况尤其容易出现。异步执行让 Append 节点的多个部分**并发**而不是串行地运行，以提升性能。

对于异步执行，Append 节点必须先用 `ExecAsyncRequest` 向一个支持异步的子节点请求元组。接着，它必须用 `ExecAppendAsyncEventWait` 执行异步事件循环。最终，当某个被发出异步请求的子节点产出元组时，Append 节点会通过 `ExecAsyncResponse` 从事件循环中收到它。在当前的异步执行实现中，唯一会向支持异步的子节点请求元组的节点类型是 Append，而唯一可能支持异步的节点类型是 ForeignScan。

通常，对于希望异步请求元组的节点，`ExecAsyncResponse` 回调是唯一需要的。另一方面，支持异步的节点一般需要实现三个方法：

1. 发出异步请求时，会调用节点的 `ExecAsyncRequest` 回调；它应使用 `ExecAsyncRequestPending` 表示该请求处于挂起状态，等待下文所述的回调。或者，如果结果可以立即得到，也可以改用 `ExecAsyncRequestDone`。
2. 当事件循环希望等待或轮询文件描述符事件时，会调用节点的 `ExecAsyncConfigureWait` 回调，用于配置该节点希望等待的文件描述符事件。
3. 当文件描述符就绪时，会调用节点的 `ExecAsyncNotify` 回调；与第 1 条类似，它应使用 `ExecAsyncRequestPending` 等待下一次回调，或用 `ExecAsyncRequestDone` 立即返回结果。
