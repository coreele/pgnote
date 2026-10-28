# Parser

相关函数: `pg_parse_query`

核心结构

`RawStmt`: container for any one statement's raw parse tree

```cpp
stmtmulti /* list */
	toplevel_stmt /* aka: RawStmt */
		Stmt /* regular SQL statement: START TRANSACTION; */
			SelectStmt
			InsertStmt
			DeleteStmt
			UpdateStmt
			MergeStmt
			/*...*/
		TransactionStmtLegacy /* Legacy transaction statement (BEGIN) for PG compatibility */
```

```cpp
typedef struct RawStmt
{
	pg_node_attr(no_query_jumble)

	NodeTag		type;
	Node	   *stmt;			/* raw parse tree */
	int			stmt_location;	/* start location, or -1 if unknown */
	int			stmt_len;		/* length in bytes; 0 means "rest of string" */
} RawStmt;
```

`SelectStmt`

```cpp
SelectStmt
	select_no_parens
		simple_select
			SELECT opt_all_clause opt_target_list
			into_clause from_clause where_clause
			group_clause having_clause window_clause
				{
					SelectStmt *n = makeNode(SelectStmt);
					n->targetList = $3;
					n->intoClause = $4;
					n->fromClause = $5;
					n->whereClause = $6;
					n->groupClause = ($7)->list;
					n->groupDistinct = ($7)->distinct;
					n->havingClause = $8;
					n->windowClause = $9;
					$$ = (Node *) n;
				}
```

```cpp
typedef struct SelectStmt
{
	NodeTag		type;

	/* These fields are used only in "leaf" SelectStmts. */
	List	   *distinctClause; /* NULL, list of DISTINCT ON exprs, or lcons(NIL,NIL) for all (SELECT DISTINCT) */
	IntoClause *intoClause;		/* target for SELECT INTO */
	List	   *targetList;		/* the target list (of ResTarget) */
	List	   *fromClause;		/* the FROM clause */
	Node	   *whereClause;	/* WHERE qualification */
	List	   *groupClause;	/* GROUP BY clauses */
	bool		groupDistinct;	/* Is this GROUP BY DISTINCT? */
	Node	   *havingClause;	/* HAVING conditional-expression */
	List	   *windowClause;	/* WINDOW window_name AS (...), ... */

	List	   *valuesLists;	/* untransformed list of expression lists */

	/* These fields are used in both "leaf" SelectStmts and upper-level SelectStmts. */
	List	   *sortClause;		/* sort clause (a list of SortBy's) */
	Node	   *limitOffset;	/* # of result tuples to skip */
	Node	   *limitCount;		/* # of result tuples to return */
	LimitOption limitOption;	/* limit type */
	List	   *lockingClause;	/* FOR UPDATE (list of LockingClause's) */
	WithClause *withClause;		/* WITH clause */

	/* These fields are used only in upper-level SelectStmts. */
	SetOperation op;			/* type of set op */
	bool		all;			/* ALL specified? */
	struct SelectStmt *larg;	/* left child */
	struct SelectStmt *rarg;	/* right child */
} SelectStmt;
```

`select a, b from tb where a = 2;` ----------> `gram.y(bison) `----------> `struct SelectStmt`

```cpp
simple_select
	SELECT opt_all_clause opt_target_list /* optional */
	into_clause from_clause where_clause
	group_clause having_clause window_clause
		{
			SelectStmt *n = makeNode(SelectStmt);
			n->targetList = $3;
			n->intoClause = $4;
			n->fromClause = $5;
			n->whereClause = $6;
			n->groupClause = ($7)->list;
			n->groupDistinct = ($7)->distinct;
			n->havingClause = $8;
			n->windowClause = $9;
			$$ = (Node *) n;
		}
```

> NB: opt_tartget_list is optional!!!

```sql
select a from tb;
select all a, b from tb;
select from tb;
```

涉及的其他子句：`from_clause`, `opt_target_list`, `where_clause`, ...
