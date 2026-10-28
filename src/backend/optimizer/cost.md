# Cost

参考文档: https://www.interdb.jp/pg/pgsql03/index.html

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
```

## IndexScan

```sql
EXPLAIN SELECT id, data FROM tbl WHERE data <= 240;
                                QUERY PLAN                                 
---------------------------------------------------------------------------
 Index Scan using tbl_data_idx on tbl  (cost=0.29..13.49 rows=240 width=8)
   Index Cond: (data <= 240)
```