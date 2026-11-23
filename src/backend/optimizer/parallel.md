```sql
SET max_parallel_workers_per_gather = default;
CREATE TABLE d (id double precision, data int);
INSERT INTO d SELECT i::double precision, (random()*1000)::int FROM generate_series(1, 1000000) AS i;
ANALYZE;
```

```c
ExecParallelInitializeDSM
ExecSerializePlan
ExecInitParallelPlan
```