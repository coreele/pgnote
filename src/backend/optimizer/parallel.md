# Parallel

## Case

```sql
SET parallel_leader_participation = false;

DROP TABLE IF EXISTS d;
CREATE TABLE d (id double precision, data int);
INSERT INTO d SELECT i::double precision, (random()*1000)::int FROM generate_series(1, 1000000) AS i;
ANALYZE;

SET max_parallel_workers_per_gather = 0; -- 关闭并行
EXPLAIN SELECT * FROM d WHERE id BETWEEN 1 AND 100;
                                  QUERY PLAN
-------------------------------------------------------------------------------
 Seq Scan on d  (cost=0.00..20406.00 rows=1 width=12)
   Filter: ((id >= '1'::double precision) AND (id <= '100'::double precision))


SET max_parallel_workers_per_gather = default; -- 开启并行 default=2
EXPLAIN SELECT * FROM d WHERE id BETWEEN 1 AND 100;
                                     QUERY PLAN
-------------------------------------------------------------------------------------
 Gather  (cost=1000.00..13906.10 rows=1 width=12)
   Workers Planned: 2
   ->  Parallel Seq Scan on d  (cost=0.00..12906.00 rows=1 width=12)
         Filter: ((id >= '1'::double precision) AND (id <= '100'::double precision))
```

## Plan

```c
grouping_planner
	query_planner | make_one_rel
		set_base_rel_pathlists | set_rel_pathlist
			set_plain_rel_pathlist
				create_seqscan_path
				create_plain_partial_paths
					compute_parallel_worker
						(heap_pages < min_parallel_table_scan_size &&
						 index_pages < min_parallel_index_scan_size)
					create_seqscan_path(root, rel, NULL, parallel_workers)
						pathnode->parallel_workers = parallel_workers;
						cost_seqscan
					add_partial_path /* parent_rel->partial_pathlist */
				create_index_paths
				create_tidscan_paths
	apply_scanjoin_target_to_paths
		generate_useful_gather_paths
			generate_gather_paths
				create_gather_path
					cost_gather
						/* Parallel setup and communication cost. */
						startup_cost += parallel_setup_cost;
						run_cost += parallel_tuple_cost * path->path.rows;
```

## Exec

```c
InitPlan
	ExecInitNode
		ExecInitGather
ExecutePlan
	ExecProcNode
		ExecGather
			ExecInitParallelPlan // Initialize the parallel context and workers on first execution
				ExecSerializePlan
				InitializeParallelDSM // Establish the dynamic shared memory segment
				ExecParallelSetupTupleQueues
					shm_mq_create
				ExecParallelInitializeDSM
					ExecSeqScanInitializeDSM // Set up a parallel heap scan descriptor
			LaunchParallelWorkers
				RegisterDynamicBackgroundWorker
					SendPostmasterSignal
						postmaster: do_start_bgworker
							fork_process
							StartBackgroundWorker → ParallelWorkerMain
			gather_getnext
				gather_readnext
					TupleQueueReaderNext
						shm_mq_receive
					gatherstate->nextreader++; // only if we weren't able to get a tuple from the current worker
				ExecStoreMinimalTuple
```
