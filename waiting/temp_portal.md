# Portal ≈ Cursor

Portal 是 Cursor 的执行上下文封装

- 在 PostgreSQL 内部，Cursor（游标）是 SQL 标准层面的概念，而 Portal 是内核执行层面的具体实现对象
- Portal 持有查询的执行计划（PlannedStmt），维护执行状态（如当前读取位置、已获取的行数）、内存上下文（MemoryContext）以及资源锁

生命周期：

- 隐式 Cursor：简单查询（Simple Query）会自动创建 unnamed portal，执行完即销毁。
- 显式 Cursor：通过 DECLARE CURSOR 创建 named portal，其生命周期跨越多个事务或请求，支持 FETCH/MOVE 等增量操作。
- 本质：Portal 是服务端用于管理“正在进行的查询结果集迭代”的状态机实例。

```sql
drop table if exists tb;

CREATE TABLE tb (a int);

INSERT INTO tb (a) SELECT generate_series(1, 20);

BEGIN;

DECLARE cur SCROLL CURSOR FOR SELECT * FROM tb;

FETCH FORWARD 5 FROM cur;
FETCH NEXT FROM cur;
FETCH cur;

FETCH BACKWARD 5 FROM cur;
FETCH PRIOR FROM cur;

FETCH ABSOLUTE 10 FROM cur;
FETCH FIRST FROM cur;
FETCH LAST FROM cur;

FETCH RELATIVE -2 FROM cur;
FETCH RELATIVE 3 FROM cur;

FETCH ALL FROM cur;

CLOSE cur;
COMMIT;
```


```cpp
typedef struct FetchStmt
{
	NodeTag		type;
	FetchDirection direction;	/* see above */
	long		howMany;		/* number of rows, or position argument */
	char	   *portalname;		/* name of portal (cursor) */
	bool		ismove;			/* true if MOVE */
} FetchStmt;
```
