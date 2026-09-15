# Recovery

## crash recovery

https://www.interdb.jp/pg/pgsql09/08.html

```sql
create table crash_test (id int, payload text);
begin;
insert into crash_test values (1, 'test_data');
commit;
\! kill -9 $(head -n 1 /home/gangjie/pgdata/postmaster.pid)
select 1;
```

```sh
# 1. 进入你的 wal 目录
cd /home/gangjie/pgdata/pg_wal/

# 2. 找到最新修改的那个 16mb 的 wal 文件（按时间排序最新的一个）
ls -lt | head -n 2

# 3. 用 waldump 强行解剖它，看看 commit 到底在不在
pg_waldump /home/gangjie/pgdata/pg_wal/00000001000000000000000x | grep -e "heap/insert|transaction/commit"
```

```sh
➜  bin ./pg_ctl restart -D ~/pgdata -l ~/pgdebug.log
➜  bin tail -n 17  ~/pgdebug.log
2026-06-02 15:04:14.642 CST [129136] LOG:  statement: create table crash_test (id int, payload text);
2026-06-02 15:04:20.789 CST [129136] LOG:  statement: begin;
2026-06-02 15:05:01.236 CST [129136] LOG:  statement: insert into crash_test values (1, 'test_data');
2026-06-02 15:05:01.244 CST [129136] LOG:  statement: commit;
2026-06-02 15:05:01.246 CST [129136] FATAL:  terminating connection due to unexpected postmaster exit
2026-06-02 15:16:21.874 CST [134084] LOG:  starting PostgreSQL 16.10 on x86_64-pc-linux-gnu, compiled by gcc (Ubuntu 11.4.0-1ubuntu1~22.04.2) 11.4.0, 64-bit
2026-06-02 15:16:21.874 CST [134084] LOG:  listening on IPv4 address "0.0.0.0", port 5432
2026-06-02 15:16:21.874 CST [134084] LOG:  listening on IPv6 address "::", port 5432
2026-06-02 15:16:21.875 CST [134084] LOG:  listening on Unix socket "/tmp/.s.PGSQL.5432"
2026-06-02 15:16:21.877 CST [134087] LOG:  database system was interrupted; last known up at 2026-06-02 15:03:16 CST
2026-06-02 15:16:21.883 CST [134087] LOG:  database system was not properly shut down; automatic recovery in progress
2026-06-02 15:16:21.884 CST [134087] LOG:  redo starts at 0/373A450
2026-06-02 15:16:21.884 CST [134087] LOG:  invalid record length at 0/37598A0: expected at least 24, got 0
2026-06-02 15:16:21.884 CST [134087] LOG:  redo done at 0/3759878 system usage: CPU: user: 0.00 s, system: 0.00 s, elapsed: 0.00 s
2026-06-02 15:16:21.885 CST [134085] LOG:  checkpoint starting: end-of-recovery immediate wait
2026-06-02 15:16:21.888 CST [134085] LOG:  checkpoint complete: wrote 29 buffers (0.2%); 0 WAL file(s) added, 0 removed, 0 recycled; write=0.002 s, sync=0.001 s, total=0.003 s; sync files=25, longest=0.001 s, average=0.001 s; distance=125 kB, estimate=125 kB; lsn=0/37598A0, redo lsn=0/37598A0
2026-06-02 15:16:21.889 CST [134084] LOG:  database system is ready to accept connections
```

## PITR

...
