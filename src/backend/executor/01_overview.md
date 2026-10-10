# Executor

## 数据流转路径

`Client<---->TCop<---->Portal<---->Executor<---->Access<---->[ Buffer/WAL ]<---->Storage`

- **`Storage --> Access`**：数据从 **磁盘 Page**（二进制块）转换成了 **HeapTuple**（原始行）。
- **`Access --> Executor`**：数据从 **物理行** 被包装进了 **TupleTableSlot**（统一的槽位，屏蔽了是索引行还是表行的差异）。
- **`Executor --> Portal`**：数据经过计算，变成了 **最终结果行**。
- **`Portal --> Client`**：数据被 `DestReceiver` 序列化为 **网络字节流**。

## Portal 生命周期

## 执行器生命周期

| 阶段   | 核心函数         | 关键动作                                           | 节点操作                                        |
| :----- | :--------------- | :------------------------------------------------- | :---------------------------------------------- |
| Init   | `ExecutorStart`  | 解析计划树，构建运行时状态树，打开表，编译表达式。 | `ExecInitNode`: `Plan` -> `PlanState`<br>       |
| Run    | `ExecutorRun`    | 循环拉取数据，逐行处理，发送给客户端               | `ExecProcNode`: `TupleTableSlot`, `ExprContext` |
| Finish | `ExecutorFinish` | 执行排队的 AFTER 触发器，更新统计信息              | `AfterTriggerEndQuery`                          |
| End    | `ExecutorEnd`    | 关闭文件/扫描描述符，销毁临时占用资源              | `ExecEndNode`                                   |


```cpp
CreatePortal /* Create unnamed portal to run the query or queries in */
    portal->status = PORTAL_NEW;

PortalDefineQuery /* A simple subroutine to establish a portal's query */
    portal->stmts = stmts
    portal->status = PORTAL_DEFINED;

PortalStart /* Prepare a portal for execution */
	CreateQueryDesc /* Create QueryDesc in portal's context */
        qd->plannedstmt = plannedstmt
        qd->snapshot = RegisterSnapshot(snapshot);	/* snapshot */
    ExecutorStart
        standard_ExecutorStart
            CreateExecutorState
            InitPlan
                planstate = ExecInitNode(plan, estate, eflags);
                    ExecInitSeqScan
                        scanstate->ss.ps.plan = (Plan *) node;
                        scanstate->ss.ps.ExecProcNode = ExecSeqScan;
                tupType = ExecGetResultType(planstate);
                queryDesc->tupDesc = tupType;
	            queryDesc->planstate = planstate;
    portal->queryDesc = queryDesc
    portal->tupDesc = queryDesc->tupDesc;
    receiver = CreateDestReceiver(dest);
    portal->status = PORTAL_READY;

PortalRun /* Run a portal's query or queries */
    MarkPortalActive
        portal->status = PORTAL_ACTIVE;
    PortalRunSelect
        ExecutorRun - tandard_ExecutorRun - ExecutePlan
         /* It accepts the query descriptor from the traffic cop and executes the query plan */
    portal->status = PORTAL_READY;

PortalDrop /* PORTAL_DEFINED */
    PortalCleanup
        ExecutorFinish
            standard_ExecutorFinish
        ExecutorEnd
            standard_ExecutorEnd
                FreeExecutorState
```

## `ExecutePlan`

Processes the query plan until we have retrieved 'numberTuples' tuples, moving in the specified direction.

```cpp
/* Loop until we've processed the proper number of tuples from the plan. */
for (;;)
{
    /* Reset the per-output-tuple exprcontext */
    ResetPerTupleExprContext(estate);

    /* Execute the plan and obtain a tuple */
    slot = ExecProcNode(planstate);

    /* send the tuple somewhere */
    dest->receiveSlot(slot, dest)

    /*
     * check our tuple count.. if we've processed the proper number then
     * quit, else loop again and process more tuples.  Zero numberTuples
     * means no limit.
     */
    current_tuple_count++;
    if (numberTuples && numberTuples == current_tuple_count)
        break;
}
```

## `ExecProcNode`

```cpp
ExecProcNode - ExecSeqScan
	ExecScan - ExecScanFetch - SeqNext // executor module
		/* Access + Storage*/
		table_scan_getnextslot - heap_getnextslot - heapgettup_pagemode
			heapgetpage
				ReadBufferExtended | ReadBuffer_common
				LockBuffer(buffer, BUFFER_LOCK_SHARE);

				BufferGetPage - BufferGetBlock
					return (Block) (BufferBlocks + ((Size) (buffer - 1)) * BLCKSZ);

				for (lineoff = FirstOffsetNumber; lineoff <= lines; lineoff++)
					PageGetItemId // Returns an item identifier of a page.
						return &((PageHeader) page)->pd_linp[offsetNumber - 1];
					PageGetItem // Retrieves an item on the given page.
						return (Item) (((char *) page) + ItemIdGetOffset(itemId));

					// True if heap tuple satisfies a time qual
					HeapTupleSatisfiesVisibility - HeapTupleSatisfiesMVCC
					HeapCheckForSerializableConflictOut
					scan->rs_vistuples[ntup++] = lineoff;

				LockBuffer(buffer, BUFFER_LOCK_UNLOCK);
```
