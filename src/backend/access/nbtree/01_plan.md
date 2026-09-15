# INDEX plan

```sql
drop table if exists tb;
create table tb (a int, b bigint);
insert into tb select n, n from generate_series(1, 100000) as n;
ANALYZE tb;
```

## sequence scan

```sql
explain select * from tb where a = 5432;
                      QUERY PLAN
------------------------------------------------------
 Seq Scan on tb  (cost=0.00..1791.00 rows=1 width=12)
   Filter: (a = 5432)
```

## index scan

```sql
create index idx on tb(a);
ANALYZE tb;

explain select * from tb where a = 5432;
                          QUERY PLAN
---------------------------------------------------------------
 Index Scan using idx on tb  (cost=0.29..8.31 rows=1 width=12)
   Index Cond: (a = 5432)
```

why width = 12?

```sql
select attname, avg_width from pg_stats where tablename='tb';
 attname | avg_width
---------+-----------
 a       |         4
 b       |         8
```

## Index Only Scan

```sql
explain select a from tb where a = 5432;
                            QUERY PLAN
-------------------------------------------------------------------
 Index Only Scan using idx on tb  (cost=0.29..4.31 rows=1 width=4)
   Index Cond: (a = 5432)
```

## Bitmap Index Scan

```sql
explain select * from tb where a = 5000 or a = 8000;
                               QUERY PLAN
------------------------------------------------------------------------
 Bitmap Heap Scan on tb  (cost=8.60..16.27 rows=2 width=12)
   Recheck Cond: ((a = 5000) OR (a = 8000))
   ->  BitmapOr  (cost=8.60..8.60 rows=2 width=0)
         ->  Bitmap Index Scan on idx  (cost=0.00..4.30 rows=1 width=0)
               Index Cond: (a = 5000)
         ->  Bitmap Index Scan on idx  (cost=0.00..4.30 rows=1 width=0)
               Index Cond: (a = 8000)
```

```sql
explain select * from tb where a in (5000, 8000);
                           QUERY PLAN
----------------------------------------------------------------
 Index Scan using idx on tb  (cost=0.29..12.62 rows=2 width=12)
   Index Cond: (a = ANY ('{5000,8000}'::integer[]))
```

`OR` 两个等值：两次 Bitmap Index Scan，再 `BitmapOr` + Bitmap Heap Scan。  
`IN` / `= ANY`：收成一个 `ScalarArrayOpExpr`，B-Tree **一次** Index Scan 内多键下跳（skip array keys），不必拆成 Bitmap。
