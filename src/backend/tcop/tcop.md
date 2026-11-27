# tcop

```
client (libpq / JDBC)
        │
        ▼
   postgres.c                 ← main loop: read messages, dispatch
     ├─ Q → exec_simple_query → parse / plan / execute
     ├─ P / B / E → parse / bind / execute (extended protocol)
     ├─ F → fastpath.c
     └─ utility (DDL, etc.) → utility.c
              │
              ▼
           pquery.c           ← Portal: run planned queries, fetch results
              │
              ▼
           dest.c             ← destination
```
