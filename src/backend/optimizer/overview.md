# Planner

参考文档: https://www.interdb.jp/pg/pgsql03/index.html

```sql
drop table if exists tb;
create table tb (id bigint primary key, payload text);
insert into tb select g, md5(g::text) from generate_series(1, 200000) g;

analyze tb;

EXPLAIN (ANALYZE, VERBOSE, BUFFERS)
select * from tb where id = 12345;
```

## 函数调用基本逻辑

```cpp
pg_plan_queries
	pg_plan_query: commandType != CMD_UTILITY
		planner
			standard_planner: PlannerGlobal
				/* primary planning entry point (may recurse for subqueries) */
				root = subquery_planner(glob, parse, NULL, false, tuple_fraction);

				/* Select best Path and turn it into a Plan */
				final_rel = fetch_upper_rel(root, UPPERREL_FINAL, NULL);
				best_path = get_cheapest_fractional_path(final_rel, tuple_fraction);

				top_plan = create_plan(root, best_path);
```

