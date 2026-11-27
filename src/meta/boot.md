# Boot

## PostgresMain

```cpp
main
    PostmasterMain
        InitProcessGlobals()
        CreateDataDirLockFile()
        ServerLoop
            BackendStartup
                fork_process
                BackendRun
                    PostgresMain(port->database_name, port->user_name);
	                    firstchar = ReadCommand(&input_message);
```

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