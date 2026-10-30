# Cost

参考文档: [https://www.interdb.jp/pg/pgsql03/02.html](https://www.interdb.jp/pg/pgsql03/02.html)

```sql
DROP TABLE IF EXISTS tbl;
CREATE TABLE tbl (id int PRIMARY KEY, data int);
CREATE INDEX tbl_data_idx ON tbl (data);
INSERT INTO tbl SELECT generate_series(1,10000),generate_series(1,10000);
ANALYZE tbl;
\d tbl
      Table "public.tbl"
 Column |  Type   | Modifiers
--------+---------+-----------
 id     | integer | not null
 data   | integer |
Indexes:
    "tbl_pkey" PRIMARY KEY, btree (id)
    "tbl_data_idx" btree (data)
```

## SeqScan

```sql
EXPLAIN SELECT * FROM tbl WHERE id <= 8000;
                       QUERY PLAN                       
--------------------------------------------------------
 Seq Scan on tbl  (cost=0.00..170.00 rows=8000 width=8)
   Filter: (id <= 8000)
```

```c
pg_plan_query | planner | standard_planner | subquery_planner
    grouping_planner | query_planner
        make_one_rel | set_base_rel_pathlists | set_rel_pathlist
            create_seqscan_path
                Path *pathnode = makeNode(Path);
                pathnode->pathtype = T_SeqScan;
                cost_seqscan
	                path->total_cost = startup_cost + cpu_run_cost + disk_run_cost;
```

## IndexScan

```sql
EXPLAIN SELECT id, data FROM tbl WHERE data <= 240;
                                QUERY PLAN                                 
---------------------------------------------------------------------------
 Index Scan using tbl_data_idx on tbl  (cost=0.29..13.49 rows=240 width=8)
   Index Cond: (data <= 240)
```

## QualCost

> src/include/nodes/pathnodes.h

```c
/*
 * The cost estimate produced by cost_qual_eval() includes both a one-time
 * (startup) cost, and a per-tuple cost.
 */
typedef struct QualCost
{
	Cost		startup;		/* one-time cost */
	Cost		per_tuple;		/* per-evaluation cost */
} QualCost;
```


```sql
postgres=# EXPLAIN SELECT data + 1 FROM tbl
WHERE id <= 8000 AND now() > '1990-01-01';
                                   QUERY PLAN                                    
---------------------------------------------------------------------------------
 Result  (cost=0.01..190.00 rows=8000 width=4)
   One-Time Filter: (now() > '1990-01-01 00:00:00+08'::timestamp with time zone)
   ->  Seq Scan on tbl  (cost=0.01..170.00 rows=8000 width=4)
         Filter: (id <= 8000)
```