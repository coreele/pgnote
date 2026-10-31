# Planner

```text
SQL ---- Query  ---- Path(s)  ---- Plan ---- PlanState
```

```c
exec_simple_query
	pg_parse_query /* SQL -> Query */
	pg_analyze_and_rewrite_fixedparams /* Analyze Query */
	pg_plan_queries
		pg_plan_query
			standard_planner /* Query -> Plan */
	PortalStart
		ExecutorStart | standard_ExecutorStart
			InitPlan /* Plan -> PlanState */
	PortalRun
		PortalRunSelect
			ExecutorRun | standard_ExecutorRun
				ExecutePlan /* PlanState */
```

## Planner

```c
standard_planner
    makeNode(PlannerGlobal)
    makeNode(PlannerInfo)
        root->parse = parse
    subquery_planner /* primary planning entry point (may recurse for subqueries) */
        grouping_planner
	        /* Generate the best unsorted and presorted paths for the scan/join */
            query_planner /* FROM/WHERE clauses */
	            /* ... */
                make_one_rel
                    make_rel_from_joinlist /* Generate access paths for each base rel */
            create_grouping_paths
            create_window_paths
            create_distinct_paths
            create_ordered_paths
        set_cheapest
	fetch_upper_rel               /* UPPERREL_FINAL */
    get_cheapest_fractional_path  /* Find the cheapest path */
    create_plan -> top_plan       /* Creates the access plan */
    result = makeNode(PlannedStmt);
    result->planTree = top_plan;
```
