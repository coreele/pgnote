DROP VIEW if EXISTS v_cols;

DROP VIEW if EXISTS v_cons;

DROP VIEW if EXISTS v_idxs;

CREATE OR REPLACE VIEW v_cols AS
SELECT
	n.nspname AS schema_name,
	c.relname AS table_name,
	a.attnum AS column_no,
	a.attname AS column_name,
	pg_catalog.format_type (a.atttypid, a.atttypmod) AS data_type,
	a.attnotnull AS not_null,
	pg_catalog.pg_get_expr (ad.adbin, ad.adrelid) AS default_value,
	COL_DESCRIPTION(a.attrelid, a.attnum) AS column_comment
FROM
	pg_catalog.pg_class c
	JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
	JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid
	LEFT JOIN pg_catalog.pg_attrdef ad ON ad.adrelid = a.attrelid
	AND ad.adnum = a.attnum
WHERE
	c.relkind = 'r' -- 普通表
	AND a.attnum > 0 -- 排除系统列
	AND NOT a.attisdropped -- 排除已删除列
	AND n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY
	n.nspname,
	c.relname,
	a.attnum;

CREATE OR REPLACE VIEW v_idxs AS
SELECT
	n.nspname AS schema_name,
	t.relname AS table_name,
	i.relname AS index_name,
	am.amname AS index_method,
	ix.indisunique AS is_unique,
	ix.indisprimary AS is_primary,
	ARRAY_TO_STRING(
		ARRAY(
			SELECT
				CASE
					WHEN a.attname IS NOT NULL THEN a.attname
					ELSE pg_catalog.pg_get_indexdef (ix.indexrelid, k + 1, TRUE)
				END
			FROM
				GENERATE_SUBSCRIPTS(ix.indkey, 1) AS k
				LEFT JOIN pg_catalog.pg_attribute a ON a.attrelid = t.oid
				AND a.attnum = ix.indkey[k]
			ORDER BY
				k
		),
		', '
	) AS index_columns,
	pg_catalog.pg_get_expr (ix.indpred, ix.indrelid) AS index_predicate,
	pg_catalog.pg_get_expr (ix.indexprs, ix.indrelid) AS index_expressions,
	pg_catalog.pg_get_indexdef (ix.indexrelid) AS index_definition
FROM
	pg_catalog.pg_class t
	JOIN pg_catalog.pg_namespace n ON n.oid = t.relnamespace
	JOIN pg_catalog.pg_index ix ON ix.indrelid = t.oid
	JOIN pg_catalog.pg_class i ON i.oid = ix.indexrelid
	JOIN pg_catalog.pg_am am ON am.oid = i.relam
WHERE
	t.relkind = 'r' -- 普通表
	AND n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY
	n.nspname,
	t.relname,
	i.relname;

CREATE OR REPLACE VIEW v_cons AS
SELECT
	n.nspname AS schema_name,
	t.relname AS table_name,
	c.conname AS constraint_name,
	c.contype AS constraint_type,
	CASE c.contype
		WHEN 'p' THEN 'PRIMARY KEY'
		WHEN 'u' THEN 'UNIQUE'
		WHEN 'f' THEN 'FOREIGN KEY'
		WHEN 'c' THEN 'CHECK'
		WHEN 'x' THEN 'EXCLUDE'
	END AS constraint_type_name,
	/* 约束涉及的列（按顺序） */
	ARRAY_TO_STRING(
		ARRAY(
			SELECT
				a.attname
			FROM
				UNNEST(c.conkey) WITH ORDINALITY AS k (attnum, ord)
				JOIN pg_catalog.pg_attribute a ON a.attrelid = t.oid
				AND a.attnum = k.attnum
			ORDER BY
				k.ord
		),
		', '
	) AS constraint_columns,
	/* CHECK 约束表达式 */
	pg_catalog.pg_get_expr (c.conbin, c.conrelid) AS check_expression,
	/* 外键相关信息 */
	fn.nspname AS referenced_schema,
	ft.relname AS referenced_table,
	ARRAY_TO_STRING(
		ARRAY(
			SELECT
				fa.attname
			FROM
				UNNEST(c.confkey) WITH ORDINALITY AS k (attnum, ord)
				JOIN pg_catalog.pg_attribute fa ON fa.attrelid = ft.oid
				AND fa.attnum = k.attnum
			ORDER BY
				k.ord
		),
		', '
	) AS referenced_columns,
	c.confupdtype AS on_update_action,
	c.confdeltype AS on_delete_action,
	c.confmatchtype AS match_type,
	/* DEFERRABLE */
	c.condeferrable AS is_deferrable,
	c.condeferred AS is_deferred
FROM
	pg_catalog.pg_constraint c
	JOIN pg_catalog.pg_class t ON t.oid = c.conrelid
	JOIN pg_catalog.pg_namespace n ON n.oid = t.relnamespace
	LEFT JOIN pg_catalog.pg_class ft ON ft.oid = c.confrelid
	LEFT JOIN pg_catalog.pg_namespace fn ON fn.oid = ft.relnamespace
WHERE
	t.relkind = 'r' -- 普通表
	AND n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY
	n.nspname,
	t.relname,
	c.conname;