# Overview

- [A Comprehensive Overview of PostgreSQL Query Processing Stages](https://www.highgo.ca/2024/01/26/a-comprehensive-overview-of-postgresql-query-processing-stages/)
- [The Internals of PostgreSQL: 3 Query Processing](https://www.interdb.jp/pg/pgsql03/01.html)
- [postgres.c](https://github.com/postgres/postgres/blob/master/src/backend/tcop/postgres.c)

## exec_simple_query

```c
/* parse */
pg_parse_query
    raw_parser

/* analyze and rewrite */
pg_analyze_and_rewrite_fixedparams
    parse_analyze_fixedparams
    pg_rewrite_query

/* plan */
pg_plan_queries

/* execute */
PortalStart
    ExecutorStart
PortalRun - PortalRunSelect
    ExecutorRun
PortalDrop
	ExecutorFinish
    ExecutorEnd
```

## call stack

```cpp

/* 1. Parse */
pg_parse_query // Parse by Bison(gram.y), support multi queries
	raw_parser

/* 2. Analyze & Rewrite */
pg_analyze_and_rewrite_fixedparams // analyze and rewrite RawStmt, RawStmt -> Query
	query = parse_analyze_fixedparams // Perform parse analysis. RawStmt -> Query
		transformTopLevelStmt - transformOptionalSelectInto - transformStmt
			transformSelectStmt
				Query	   *qry = makeNode(Query);
				transform***Clause
	querytree_list = pg_rewrite_query // Rewrite the queries, as necessary. Query -> List(Query)
		QueryRewrite // don't rewrite utilities

/* 3. Plan */
pg_plan_queries // querytree_list -> plantree_list(PlannedStmt), plan just for dml(select, insert, update, delete, merge)
	pg_plan_query - planner - standard_planner - subquery_planner
		/* primary planning entry point (may recurse for subqueries) */
		root = subquery_planner(glob, parse, NULL, false, tuple_fraction);
		/* Select best Path and turn it into a Plan */
		final_rel = fetch_upper_rel(root, UPPERREL_FINAL, NULL);
		best_path = get_cheapest_fractional_path(final_rel, tuple_fraction);
		PlannedStmt.planTree = create_plan(root, best_path);

/* 4. Portal */
CreatePortal
PortalDefineQuery // portal->stmts = plantree_list;
PortalStart // Prepare a portal for execution. params, strategy, queryDesc
	queryDesc = CreateQueryDesc
	ExecutorStart(queryDesc, myeflags); // prepare the plan for execution
		standard_ExecutorStart
	portal->queryDesc = queryDesc;
	portal->status = PORTAL_READY;
PortalSetResultFormat
PortalRun - PortalRunSelect

	/* 5. Executor */
	ExecutorRun - tandard_ExecutorRun - ExecutePlan // Processes the query plan until retrieved 'numberTuples' tuples
		ExecProcNode - ExecSeqScan
			ExecScan - ExecScanFetch - SeqNext // executor module
				/* Access + Storage*/
				table_scan_getnextslot - heap_getnextslot - heapgettup_pagemode
					heapgetpage
						ReadBufferExtended
							ReadBuffer_common
								BufferAlloc
									InitBufferTag
									LWLockAcquire(newPartitionLock, LW_SHARED);
								    existing_buf_id = BufTableLookup(&newTag, newHash);

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
				return slot;
			ExecProject
PortalDrop
```
