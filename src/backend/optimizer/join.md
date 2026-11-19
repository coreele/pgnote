# Join

## JoinType

```c
typedef enum JoinType
{
	/*
	 * The canonical kinds of joins according to the SQL JOIN syntax. Only
	 * these codes can appear in parser output (e.g., JoinExpr nodes).
	 */
	JOIN_INNER,					/* matching tuple pairs only */
	JOIN_LEFT,					/* pairs + unmatched LHS tuples */
	JOIN_FULL,					/* pairs + unmatched LHS + unmatched RHS */
	JOIN_RIGHT,					/* pairs + unmatched RHS tuples */

	/*
	 * Semijoins and anti-semijoins (as defined in relational theory) do not
	 * appear in the SQL JOIN syntax, but there are standard idioms for
	 * representing them (e.g., using EXISTS).  The planner recognizes these
	 * cases and converts them to joins.  So the planner and executor must
	 * support these codes.  NOTE: in JOIN_SEMI output, it is unspecified
	 * which matching RHS row is joined to.  In JOIN_ANTI output, the row is
	 * guaranteed to be null-extended.
	 */
	JOIN_SEMI,					/* 1 copy of each LHS row that has match(es) */
	JOIN_ANTI,					/* 1 copy of each LHS row that has no match */
	JOIN_RIGHT_ANTI,			/* 1 copy of each RHS row that has no match */

	/*
	 * These codes are used internally in the planner, but are not supported
	 * by the executor (nor, indeed, by most of the planner).
	 */
	JOIN_UNIQUE_OUTER,			/* LHS path must be made unique */
	JOIN_UNIQUE_INNER			/* RHS path must be made unique */

	/*
	 * We might need additional join types someday.
	 */
} JoinType;
```

```sql
DROP TABLE IF EXISTS tbl_a, tbl_b, tbl_c;
CREATE TABLE tbl_a (id int, val int);
CREATE TABLE tbl_b (id int, val int);
CREATE TABLE tbl_c (id integer PRIMARY KEY, val integer);

INSERT INTO tbl_a SELECT g, g FROM generate_series(1, 10000) g;
INSERT INTO tbl_b SELECT g, g FROM generate_series(1, 5000) g;
INSERT INTO tbl_c SELECT id, val FROM tbl_a;

ANALYZE tbl_a;
ANALYZE tbl_b;
ANALYZE tbl_c;
```
## Nest Loop Join

### Materialized Nested Loop Join

```sql
SET enable_nestloop = on;
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
			add_paths_to_joinrel(tbl_a, tbl_b)
			    match_unsorted_outer(...)
				    create_material_path
				        cost_material                   //  → cost=0..98
				    try_nestloop_path
				        initial_cost_nestloop
					        cost_rescan
				        add_path_precheck
				        create_nestloop_path
					        final_cost_nestloop        // → cost=0..750230.50
					            cost_qual_eval
			add_paths_to_joinrel(tbl_b, tbl_a)
```

### Indexed Nested Loop Join

```sql
EXPLAIN SELECT * FROM tbl_c AS c, tbl_b AS b WHERE c.id = b.id;
                                   QUERY PLAN                                   
--------------------------------------------------------------------------------
 Nested Loop  (cost=0.29..1885.50 rows=5000 width=16)
   ->  Seq Scan on tbl_b b  (cost=0.00..73.00 rows=5000 width=8)
   ->  Index Scan using tbl_c_pkey on tbl_c c  (cost=0.29..0.36 rows=1 width=8)
         Index Cond: (id = b.id)
```

## Merge Join

```sql
SET enable_mergejoin = on;
SET enable_hashjoin = off;
SET enable_nestloop = off;

EXPLAIN SELECT * FROM tbl_a AS a, tbl_b AS b WHERE a.id = b.id AND b.id < 1000;
                               QUERY PLAN                                
-------------------------------------------------------------------------
 Merge Join  (cost=944.66..984.64 rows=999 width=16)
   Merge Cond: (a.id = b.id)
   ->  Sort  (cost=809.39..834.39 rows=10000 width=8)
         Sort Key: a.id
         ->  Seq Scan on tbl_a a  (cost=0.00..145.00 rows=10000 width=8)
   ->  Sort  (cost=135.27..137.77 rows=999 width=8)
         Sort Key: b.id
         ->  Seq Scan on tbl_b b  (cost=0.00..85.50 rows=999 width=8)
               Filter: (id < 1000)
```

```sql
DROP TABLE IF EXISTS tbl_x, tbl_y;
CREATE TABLE tbl_x (id int, payload char(1024));
CREATE TABLE tbl_y (id int, payload char(1024));
INSERT INTO tbl_x
SELECT g, rpad('x', 1024, 'x') FROM generate_series(1, 10000) g;
INSERT INTO tbl_y
SELECT g, rpad('y', 1024, 'y') FROM generate_series(1, 5000) g;
ANALYZE tbl_x, tbl_y;
SET max_parallel_workers_per_gather = 0;  -- 避免 Gather/并行
SET enable_hashjoin = off;
SET enable_nestloop = off;
SET enable_mergejoin = on;   

EXPLAIN SELECT * FROM tbl_x AS x, tbl_y AS y WHERE x.id = y.id;
                                   QUERY PLAN                                    
---------------------------------------------------------------------------------
 Merge Join  (cost=10038.08..10150.58 rows=5000 width=2064)
   Merge Cond: (x.id = y.id)
   ->  Sort  (cost=6708.39..6733.39 rows=10000 width=1032)
         Sort Key: x.id
         ->  Seq Scan on tbl_x x  (cost=0.00..1529.00 rows=10000 width=1032)
   ->  Materialize  (cost=3329.69..3354.69 rows=5000 width=1032)
         ->  Sort  (cost=3329.69..3342.19 rows=5000 width=1032)
               Sort Key: y.id
               ->  Seq Scan on tbl_y y  (cost=0.00..765.00 rows=5000 width=1032)
```
## Hash Join

