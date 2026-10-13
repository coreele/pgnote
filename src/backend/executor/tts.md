# TupleTableSlot

> src/include/executor/tuptable.h

```c
/* base tuple table slot type */
typedef struct TupleTableSlot
{
	NodeTag		type;
#define FIELDNO_TUPLETABLESLOT_FLAGS 1
	uint16		tts_flags;		/* Boolean states */
#define FIELDNO_TUPLETABLESLOT_NVALID 2
	AttrNumber	tts_nvalid;		/* # of valid values in tts_values */
	const TupleTableSlotOps *const tts_ops; /* implementation of slot */
#define FIELDNO_TUPLETABLESLOT_TUPLEDESCRIPTOR 4
	TupleDesc	tts_tupleDescriptor;	/* slot's tuple descriptor */
#define FIELDNO_TUPLETABLESLOT_VALUES 5
	Datum	   *tts_values;		/* current per-attribute values */
#define FIELDNO_TUPLETABLESLOT_ISNULL 6
	bool	   *tts_isnull;		/* current per-attribute isnull flags */
	MemoryContext tts_mcxt;		/* slot itself is in this context */
	ItemPointerData tts_tid;	/* stored tuple's tid */
	Oid			tts_tableOid;	/* table oid of tuple */
} TupleTableSlot;
```

## Slots

```c
VirtualTupleTableSlot
HeapTupleTableSlot
BufferHeapTupleTableSlot
MinimalTupleTableSlot
```

```c
const TupleTableSlotOps TTSOpsHeapTuple = {
	.base_slot_size = sizeof(HeapTupleTableSlot),
	.init = tts_heap_init,
	.release = tts_heap_release,
	.clear = tts_heap_clear,
	.getsomeattrs = tts_heap_getsomeattrs,
	.getsysattr = tts_heap_getsysattr,
	.materialize = tts_heap_materialize,
	.copyslot = tts_heap_copyslot,
	.get_heap_tuple = tts_heap_get_heap_tuple,

	/* A heap tuple table slot can not "own" a minimal tuple. */
	.get_minimal_tuple = NULL,
	.copy_heap_tuple = tts_heap_copy_heap_tuple,
	.copy_minimal_tuple = tts_heap_copy_minimal_tuple
};
```

## call stack

```c
exec_simple_query
    PortalStart | ExecutorStart | standard_ExecutorStart
        InitPlan | ExecInitNode
            ExecInitSeqScan
                ExecAssignExprContext
                    planstate->ps_ExprContext = CreateExprContext(estate);
                ExecInitScanTupleSlot
                    scanstate->ss_ScanTupleSlot = ExecAllocTableSlot()
                        MakeTupleTableSlot
                ExecAssignScanProjectionInfo | ExecConditionalAssignProjectionInfo
                    ExecInitResultSlot
                        planstate->ps_ResultTupleSlot = ExecAllocTableSlot()
                    ExecAssignProjectionInfo
```
