# tcop

> tcop = traffic cop（调度前端请求到 parser / optimizer / executor 等）

## Protocol

```c
PostgresMain(port->database_name, port->user_name);
	firstchar = ReadCommand(&input_message);
	case 'Q': exec_simple_query     /* simple query */
	/* Extended Query Protocol */
	case 'P': exec_parse_message    /* parse */
	case 'B': exec_bind_message     /* bind */
	case 'E': exec_execute_message  /* execute */
	/* ... */
```

## Command

| 字符 | 函数/处理逻辑 | 核心职责 |
| ---- | ------------- | -------- |
| `Q`  | `exec_simple_query` | Simple Query：一条 SQL 文本直接解析/规划/执行 |
| `P`  | `exec_parse_message` | Parse：解析/分析 SQL，创建（命名或未命名）预备语句 |
| `B`  | `exec_bind_message` | Bind：为预备语句绑参，创建可执行 Portal |
| `E`  | `exec_execute_message` | Execute：执行指定 Portal（可按 `max_rows` 分批取结果） |
| `F`  | `HandleFunctionRequest` | Fastpath：按 OID 直接调后端函数（非 SQL 文本） |
| `S`  | `finish_xact_command` + ReadyForQuery | Sync：收尾当前命令事务，并向前端发送 ReadyForQuery |

## Application

1. **简单查询流程**：`Q` → 直接解析/规划/执行 → 响应结果；
2. **预备语句流程**：`P`（解析）→ `B`（绑定）→ `E`（执行）→ `C`（关闭）→ `S`（同步）；
