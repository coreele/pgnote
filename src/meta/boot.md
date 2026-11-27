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
                        exec_simple_query
```
