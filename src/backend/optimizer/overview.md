# Planner

## Call Stack

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
	fetch_upper_rel               /* upper rel */
    get_cheapest_fractional_path
    create_plan -> top_plan
    result = makeNode(PlannedStmt);
    result->planTree = top_plan;
```

