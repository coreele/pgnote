# vacuum lazy

```sql
DROP TABLE IF EXISTS tb;

CREATE TABLE tb (id int PRIMARY KEY, val int)
WITH (autovacuum_enabled = off, fillfactor = 100);

INSERT INTO tb values (1, 1), (2, 2), (3, 3);

-- HOT 更新，产生 dead heap-only tuple（不增索引项）
UPDATE tb SET val = val * 10 WHERE id = 2;

DELETE from tb where id = 3;

VACUUM freeze tb;
```

```c
ExecVacuum | vacuum /* vacuum relations or all releated tables */
    vacuum_rel
        /* or cluster_rel for vacuum full */
        table_relation_vacuum | heap_vacuum_rel /* perform VACUUM for one heap relation */
            lazy_scan_heap      /* heap pruning + index vac + heap vac */
                lazy_scan_prune /* prune heap pages */
                    heap_page_prune /* prune one page */
                        heap_prune_satisfies_vacuum /* tuple visibility checks */
                        heap_prune_chain /* process all line pointer */
                        heap_page_prune_execute
                            ItemIdSetRedirect /* Update all redirected line pointers */
          		            ItemIdSetDead     /* Update all now-dead line pointers */
          		            ItemIdSetUnused   /* Update all now-unused line pointers */
          		            PageRepairFragmentation
         			            compactify_tuples
                        PageClearFull
                        MarkBufferDirty
                        XLogInsert(RM_HEAP2_ID, XLOG_HEAP2_PRUNE)
                    heap_prepare_freeze_tuple
                    heap_freeze_execute_prepared /* freeze heap tuples */
                        heap_execute_freeze_tuple /* Execute the prepared freezing of a tuple with caller's freeze plan */
                        MarkBufferDirty
                        XLogInsert(RM_HEAP2_ID, XLOG_HEAP2_FREEZE_PAGE);
                lazy_vacuum     /* index vacuuming */
                    lazy_vacuum_all_indexes
                        lazy_vacuum_one_index | vac_bulkdel_one_index /* vacuum index relation */
                            index_bulk_delete | IndexAmRoutine::ambulkdelete
                                btbulkdelete
                                    _bt_start_vacuum
                                    btvacuumscan
                                        btvacuumpage
                                    _bt_end_vacuum
                    lazy_vacuum_heap_rel /* LP_DEAD -> LP_UNUSED */
                        lazy_vacuum_heap_page
                            ItemIdSetUnused
                            PageTruncateLinePointerArray
                            MarkBufferDirty
                            XLogInsert(RM_HEAP2_ID, XLOG_HEAP2_VACUUM);
                FreeSpaceMapVacuumRange
                    lazy_cleanup_one_index
                        vac_cleanup_one_index
                            index_vacuum_cleanup | IndexAmRoutine::amvacuumcleanup
                                btvacuumcleanup
            lazy_truncate_heap
            vac_update_relstats /* update stats */
    vac_update_datfrozenxid
```

```c
/* Result codes for HeapTupleSatisfiesVacuum */
typedef enum
{
	HEAPTUPLE_DEAD,				/* tuple is dead and deletable */
	HEAPTUPLE_LIVE,				/* tuple is live (committed, no deleter) */
	HEAPTUPLE_RECENTLY_DEAD,	/* tuple is dead, but not deletable yet */
	HEAPTUPLE_INSERT_IN_PROGRESS,	/* inserting xact is still in progress */
	HEAPTUPLE_DELETE_IN_PROGRESS	/* deleting xact is still in progress */
} HTSV_Result;
```
