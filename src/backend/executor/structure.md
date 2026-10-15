# Structure

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
		MemoryContext es_query_cxt; /* per-query context in which EState lives */
		List      *es_tupleTable;  /* List of TupleTableSlots */
		ExprContext *es_per_tuple_exprcontext; /* for per-output-tuple operations, reset for each output tuple*/
	
	PlanState  *planstate;		/* tree of per-plan-node state */
		ExecProcNodeMtd ExecProcNode;  /* function to return next tuple */
		struct PlanState *lefttree
		struct PlanState *righttree;
```

## PlanState

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

