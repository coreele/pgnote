# TupleTableSlot

## Overview

```c
typedef struct TableAmRoutine
{
     /* Return slot implementation suitable for storing a tuple of this AM. */
	const TupleTableSlotOps *(*slot_callbacks) (Relation rel);

	/* Return next tuple from `scan`, store in slot. */
	bool		(*scan_getnextslot) (TableScanDesc scan,
									 ScanDirection direction,
									 TupleTableSlot *slot);
    
    /* ... */
}
```

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
/* ...
 * 1. physical tuple in a disk buffer page (TTSOpsBufferHeapTuple)
 * 2. physical tuple constructed in palloc'ed memory (TTSOpsHeapTuple)
 * 3. "minimal" physical tuple constructed in palloc'ed memory
 *    (TTSOpsMinimalTuple)
 * 4. "virtual" tuple consisting of Datum/isnull arrays (TTSOpsVirtual)
 * ...
 */
```

```c
/*
 * Predefined TupleTableSlotOps for various types of TupleTableSlotOps. The
 * same are used to identify the type of a given slot.
 */
extern PGDLLIMPORT const TupleTableSlotOps TTSOpsVirtual;
extern PGDLLIMPORT const TupleTableSlotOps TTSOpsHeapTuple;
extern PGDLLIMPORT const TupleTableSlotOps TTSOpsMinimalTuple;
extern PGDLLIMPORT const TupleTableSlotOps TTSOpsBufferHeapTuple;
```

Virtual functions

```c
/* routines for a TupleTableSlot implementation */
struct TupleTableSlotOps
```

## BufferHeapTupleTableSlot

```c
const TupleTableSlotOps TTSOpsBufferHeapTuple = {
	.base_slot_size = sizeof(BufferHeapTupleTableSlot),
	.init = tts_buffer_heap_init,
	.release = tts_buffer_heap_release,
	.clear = tts_buffer_heap_clear,
	.getsomeattrs = tts_buffer_heap_getsomeattrs,
	.getsysattr = tts_buffer_heap_getsysattr,
	.materialize = tts_buffer_heap_materialize,
	.copyslot = tts_buffer_heap_copyslot,
	.get_heap_tuple = tts_buffer_heap_get_heap_tuple,

	/* A buffer heap tuple table slot can not "own" a minimal tuple. */
	.get_minimal_tuple = NULL,
	.copy_heap_tuple = tts_buffer_heap_copy_heap_tuple,
	.copy_minimal_tuple = tts_buffer_heap_copy_minimal_tuple
};
```

## call stack

`select * from tb;`

```c
exec_simple_query
    PortalStart | ExecutorStart | standard_ExecutorStart
        InitPlan | ExecInitNode
            ExecInitSeqScan
                scanstate->ss.ps.ExecProcNode = ExecSeqScan;
                ExecInitScanTupleSlot
                    scanstate->ss_ScanTupleSlot = ExecAllocTableSlot()
                        MakeTupleTableSlot
                            [ BufferHeapTupleTableSlot | Datum ... | Bool ... ]
    PortalRun
        PortalRunSelect
            ExecutorRun | standard_ExecutorRun
                ExecutePlan
                    ExecProcNode /* Execute the plan and obtain a tuple */
                        ExecSeqScan | ExecScan /* execScan.c */
                            ExecScanFetch
                                SeqNext
                                    table_scan_getnextslot | TableAmRoutine::scan_getnextslot
                                        heap_getnextslot
                                            heapgettup_pagemode
                                                HeapTuple	tuple = &(scan->rs_ctup);
                                                tuple->t_data = (HeapTupleHeader) PageGetItem(page, lpp);
			                                    tuple->t_len = ItemIdGetLength(lpp);
                                            ExecStoreBufferHeapTuple(&scan->rs_ctup, slot, scan->rs_cbuf)
                                                bslot->base.tuple = tuple;
                    dest->receiveSlot = printtup
                        slot_getallattrs /* forces all the entries of the slot's Datum/isnull arrays to be valid */
                            slot_getsomeattrs |  slot_getsomeattrs_int
                                slot->tts_ops->getsomeattrs
                                    tts_buffer_heap_getsomeattrs
                                        slot_deform_heap_tuple /* extract data from the slot's physical tuple */
                                            fetch_att
                        /* send the attributes of this tuple */
```
