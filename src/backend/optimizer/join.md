# Join

## Nest Loop Join

## Materialized Nested Loop Join

```sql
DROP TABLE IF EXISTS tbl_a, tbl_b;

CREATE TABLE tbl_a (id int, val int);
CREATE TABLE tbl_b (id int, val int);

INSERT INTO tbl_a SELECT g, g FROM generate_series(1, 10000) g;
INSERT INTO tbl_b SELECT g, g FROM generate_series(1, 5000) g;

ANALYZE tbl_a;
ANALYZE tbl_b;

-- 关键：否则会走 Hash Join
SET enable_hashjoin = off;
SET enable_mergejoin = off;

EXPLAIN SELECT * FROM tbl_a AS a, tbl_b AS b WHERE a.id = b.id;
                              QUERY PLAN                               
-----------------------------------------------------------------------
 Nested Loop  (cost=0.00..750230.50 rows=5000 width=16)
   Join Filter: (a.id = b.id)
   ->  Seq Scan on tbl_a a  (cost=0.00..145.00 rows=10000 width=8)
   ->  Materialize  (cost=0.00..98.00 rows=5000 width=8)
         ->  Seq Scan on tbl_b b  (cost=0.00..73.00 rows=5000 width=8)
```

```c
planner / grouping_planner
	make_one_rel
		set_base_rel_pathlists / set_rel_pathlist / set_plain_rel_pathlist
		    create_seqscan_path(tbl_a)          → cost=0..145
		        cost_seqscan()
		    create_seqscan_path(tbl_b)          → cost=0..73
		        cost_seqscan()
		populate_joinrel_with_paths
			add_paths_to_joinrel(rel1, rel2)
			    match_unsorted_outer(...)           // joinpath.c
				    create_material_path(tbl_b SeqScan)
				        cost_material()                 → cost=0..98
				        // 含 input 73 + 2 * cpu_operator_cost * 5000
				    try_nestloop_path(a SeqScan, Materialize(b))
				        initial_cost_nestloop()
					        cost_rescan(Materialize)      // 估第2次及以后扫内表
				        add_path_precheck(...)
				        create_nestloop_path(...)
					        final_cost_nestloop()         → cost=0..750230.50
				            cost_qual_eval(Join Filter: a.id=b.id)
				            // ntuples = 10000 * 5000
				            // run += (cpu_tuple_cost + qual) * ntuples
			add_paths_to_joinrel(rel2, rel1)
```

## Indexed Nested Loop Join

## Merge Join

## Hash Join