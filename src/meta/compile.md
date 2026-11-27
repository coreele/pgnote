# Compile

> 基于 macOS 15.4.1

## Clone

- pg 官方仓库：https://git.postgresql.org/git/postgresql.git
- github 仓库：https://github.com/postgres/postgres.git
- gitee 仓库：https://gitee.com/mirrors/PostgreSQL.git

```sh
git clone https://gitee.com/mirrors/PostgreSQL.git
cd postgresql
git checkout REL_16_11
```

## Version

- PG 版本维护规则：https://www.postgresql.org/support/versioning/
- 发布版命名规则：`REL_<主版本>_<维护版本>`
- REL_16_11 处于 16 主版本的「稳定维护阶段」
- 更新频率：每年发布一个主版本（15→16→17→18），每 1-2 个月发布一个维护版本（如 16_1→16_2→…→16_11）

## Make

```sh
cd postgres
mkdir build && cd build
CFLAGS="-O0 -g3 -fno-inline -fno-omit-frame-pointer" \
../configure  --prefix=$HOME/app/pgdebug --without-icu --with-libxml --enable-debug --enable-cassert
make -j4
make install
# make distclean
# cp ./src/backend/postgres ~/app/pgdebug/bin/postgres
```

## Init

```sh
cd ~/app/pgdebug/bin
./initdb -D ~/pgdata
```

- PostgreSQL 中初始化数据库集群（Database Cluster） 的核心命令
- 在指定目录 `~/pgdata` 中创建 PostgreSQL 运行所需的基础目录结构、系统表、配置文件

## Control

```sh
cd ~/app/pgdebug/bin

./pg_ctl start -D ~/pgdata -l ~/pgdebug.log

./pg_ctl stop -D ~/pgdata -l ~/pgdebug.log

./pg_ctl restart -D ~/pgdata -l ~/pgdebug.log
```

## Connect

配置客户端访问 `pg_hba.conf`

```conf
# TYPE  DATABASE        USER            ADDRESS                 METHOD

# "local" is for Unix domain socket connections only
local   all             all                                     trust
# IPv4 local connections:
host    all             all             127.0.0.1/32            trust
```

连接

```sh
psql -U postgres -d postgres -h 127.0.0.1 -p 5432
```

查询当前 pid

```sql
// 查询当前pid
select pg_backend_pid();
```

## Debug

vscode 配置调试

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Attach PG",
      "type": "cppdbg",
      "request": "attach",
      "program": "~/SourceCodes/postgres/src/backend/postgres", // PostgreSQL 主程序路径
      "processId": "${command:pickProcess}", // 允许手动选择进程ID
      "MIMode": "lldb", // 使用 GDB 调试器
      "setupCommands": [
        {
          "description": "Enable pretty-printing for gdb",
          "text": "-enable-pretty-printing",
          "ignoreFailures": true
        }
      ],
      "logging": {
        "moduleLoad": false,
        "trace": true
      }
    }
  ]
}
```
