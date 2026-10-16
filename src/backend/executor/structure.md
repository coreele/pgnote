# Structure

| 结构体         | 存在的层级 | 生命周期        | 核心协同作用                           |
| -------------- | ---------- | --------------- | -------------------------------------- |
| _Portal_       | 顶层       | 会话级/Cursor级 | 管理查询执行的任务流                   |
| QueryDesc      | 执行前     | 执行周期级      | 封装执行器所需的全部入参、计划和快照   |
| EState         | 执行期间   | 执行周期级      | 管理全局内存上下文、元组槽表和事务快照 |
| PlanState      | 执行期间   | 执行周期级      | 算子执行算子，负责递归计算和状态维护   |
| TupleTableSlot | 算子间     | 算子执行级      | 算子间数据传递的容器，减少拷贝开销     |

## QueryDesc

```c
typedef struct QueryDesc // a QueryDesc encapsulates everything that the executor needs to execute the query

	PlannedStmt *plannedstmt;  /* planner's output (could be utility, too) */
		struct Plan *planTree;     /* tree of Plan nodes */
			struct Plan *lefttree;     /* input plan tree(s) */
			struct Plan *righttree;

	Snapshot   snapshot;       /* snapshot to use for query */
	DestReceiver *dest;            /* the destination for tuple output */
	TupleDesc	tupDesc;		/* descriptor for result tuples */
	EState	   *estate;			/* executor's query-wide state */
		List *es_range_table; /* List of RangeTblEntry */
		Relation *es_relations; /* Array of per-range-table-entry Relation pointers */
		MemoryContext es_query_cxt; /* per-query context in which EState lives */
		List      *es_tupleTable;  /* List of TupleTableSlots */
		ExprContext *es_per_tuple_exprcontext; /* for per-output-tuple operations, reset for each output tuple*/

	PlanState  *planstate;		/* tree of per-plan-node state */
		ExecProcNodeMtd ExecProcNode;  /* function to return next tuple */
		struct PlanState *lefttree
		struct PlanState *righttree;
```

## SeqScanState

SeqScanState 继承关系

```c
typedef struct SeqScanState
    ScanState	ss;
        PlanState	ps;
        Relation	ss_currentRelation; /* relation being scanned (NULL if none) */
        struct TableScanDescData *ss_currentScanDesc; /* current scan descriptor for scan */
        TupleTableSlot *ss_ScanTupleSlot; /* pointer to slot in tuple table holding scan tuple */
```

## Call Stack

```
exec_simple_query
    PortalStart
        ExecutorStart
            standard_ExecutorStart
                estate = CreateExecutorState();
                    estate->es_query_cxt = qcontext;
                queryDesc->estate = estate; /* Build EState, switch into per-query memory context for startup */
                InitPlan
                    ExecInitNode
                        ExecInitSeqScan
                            scanstate = makeNode(SeqScanState);
                            scanstate->ss.ps.plan = (Plan *) node;
                            scanstate->ss.ps.state = estate;
                            scanstate->ss.ps.ExecProcNode = ExecSeqScan;
                            ExecInitScanTupleSlot /* create slot with the appropriate rowtype */
```
