## 核心问题速记

| 问题          | 解决方案             | 代码位置       |
| ----------- | ---------------- | ---------- |
| 如何保证修改的原子性？ | XID + TransState | xact.c     |
| 如何保证数据的持久性？ | WAL + XLogFlush  | xlog.c     |
| 如何处理并发读写？   | MVCC + 快照        | snapmgr.c  |
| 如何避免写写冲突？   | 锁                | lock.c     |
| 如何处理死锁？     | 死锁检测器            | deadlock.c |
| 如何支持部分回滚？   | 子事务 + SavePoint  | xact.c     |
| 如何跨库保证原子性？  | 两阶段提交            | twophase.c |
# PostgreSQL 事务管理源码学习问题集

## 第一层：基础事务模型（问题1-3）

### 问题1：事务状态转换

**用例：** `BEGIN; INSERT INTO tb VALUES(1); COMMIT;`

1. PostgreSQL 中有哪些事务状态？分别对应什么含义？ **[trans_state](../docs/Transaction/trans_2_state.md)**
2. BEGIN;INSERT;COMMIT; 命令执行时，事务状态如何转移？何时分配 XID？为什么？ [trans_vxid](../docs/Transaction/trans_3_vxid.md) [trans_xid](../docs/Transaction/trans_4_xid.md)

### 问题2：事务提交流程 [trans_commit](./trans_commit.md)

**用例：** `BEGIN; INSERT INTO tb VALUES(1); COMMIT;`

1. CommitTransaction() 函数的整体执行流程是什么？
2. WAL 日志在提交中的作用是什么？何时写入？何时刷盘？
3. XLogFlush() 函数的作用是什么？为什么必须等待它完成？
4. TransactionIdCommitTree() 函数做了什么？为什么这一步很关键？
5. 提交后资源如何清理？内存、锁、文件描述符分别如何处理？
6. synchronous_commit 参数如何影响提交流程？

### 问题3：事务回滚处理 TODO

**用例：** `BEGIN; INSERT INTO tb VALUES(1/0); COMMIT;`

1. 错误是如何被捕获的？ereport() 函数与 siglongjmp() 的关系是什么？
2. AbortCurrentTransaction() 与 AbortTransaction() 的区别是什么？
3. 事务回滚时需要撤销哪些修改？磁盘上的脏页如何处理？
4. LockReleaseAll() 函数如何释放所有锁？为什么需要唤醒等待队列？
5. 内存上下文在回滚时如何清理？
6. 子事务回滚与主事务回滚的流程有何不同？

---

## 第二层：MVCC 与隔离（问题4-6）

### 问题4：MVCC 快照机制 [mvcc_snapshot](../docs/Transaction/mvcc_snapshot.md)

1. Snapshot 数据结构包含哪些关键字段？各有什么含义？
2. xmin、xmax、xip[] 数组如何决定行的可见性？
3. GetTransactionSnapshot() 何时被调用？每个事务级别的隔离级别下是否每条语句都获取新快照？
4. GetOldestXmin() 函数的作用是什么？它如何影响 VACUUM？
5. 在 REPEATABLE_READ 隔离级别下，为什么同一事务中的多条 SELECT 结果一致？
6. 活跃事务数组（ProcArray）的作用是什么？如何维护？

### 问题5：隔离级别实现 [trans_iso](../docs/Transaction/trans_5_iso.md)

1. PostgreSQL 实现了哪些隔离级别？哪些可能出现脏读、不可重复读、幻读？
2. READ_COMMITTED 与 REPEATABLE_READ 在快照获取上的区别是什么？
3. SERIALIZABLE 隔离级别基于什么算法实现？SSI（Serializable Snapshot Isolation）的核心思想是什么？
4. 如何检测序列化冲突？什么时候抛出 SERIALIZATION_FAILURE 错误？
5. deferrable 事务的作用是什么？

### 问题6：事务可见性判断 [mvcc_visibility](../docs/Transaction/mvcc_visibility.md)

1. `HeapTupleSatisfiesMVCC()` 函数如何判断一个行对当前事务是否可见？
2. 事务的 xmin 和 xmax 是如何计算的？
3. 为什么需要检查事务是否已提交、已回滚或仍在进行？

---

## 第三层：WAL 与持久化（问题7-9）

### 问题7：WAL 日志结构

1. XLogRecord 的关键字段有哪些？各有什么作用？
2. xl_rmgr（资源管理器 ID）有多少种？各管理什么资源的日志？
3. XLOG_XACT_COMMIT 记录包含哪些信息？
4. 为什么要记录 xl_prev（前一条记录的位置）？
5. WAL 记录如何分页存储？一个 WAL 文件大小是多少？

### 问题8：WAL 写入与刷盘

1. XLogInsert() 函数的执行流程是什么？
2. WAL 缓冲区的大小是多少？如何管理？
3. XLogFlush() 与 XLogWrite() 的区别是什么？
4. 什么情况下会触发 WAL 缓冲区的刷新？
5. wal_sync_method 参数如何影响持久化性能？

### 问题9：崩溃恢复流程

1. PostgreSQL 启动时如何检查是否需要进行恢复？
2. pg_control 文件记录了什么关键信息？
3. 恢复从哪个日志位置开始？lastCheckpoint 的作用是什么？
4. 恢复时如何重放日志？对于已提交、已回滚、不确定的事务如何处理？
5. 恢复完成后需要进行哪些清理操作？

---

## 第四层：并发控制（问题10-12）

### 问题10：锁管理机制

1. PostgreSQL 支持哪些锁模式？各适用于什么场景？
2. PROCLOCK 结构如何组织？一个进程如何追踪自己持有的所有锁？
3. LockMethodData 数组的作用是什么？
4. 获取锁时的冲突检查如何进行？
5. 为什么 COMMIT 时要释放所有锁？

### 问题11：死锁检测

1. 死锁检测器（DeadlockCheck）何时运行？
2. 等待图（wait-for graph）如何构建？
3. 如何检测等待图中的环？
4. 选择牺牲者（victim selection）的标准是什么？
5. 被选中的事务如何回滚？

### 问题12：冲突解决

1. 什么时候两个事务会产生冲突？
2. 在 REPEATABLE_READ 下，幻读冲突如何被检测？
3. 在 SERIALIZABLE 下，哪些冲突会导致序列化失败？
4. 冲突检测的性能成本有多高？

---

## 第五层：子事务与保存点（问题13-15）

### 问题13：子事务模型

1. SavePoint 的作用是什么？在源码中如何表示？
2. 子事务与主事务的关系是什么？事务栈如何管理？
3. 子事务的 XID 如何分配？与主事务 XID 的关系？
4. 子事务提交时，修改是否立即可见？

### 问题14：保存点回滚

1. ROLLBACK TO SAVEPOINT 的执行流程是什么？
2. 回滚时如何恢复快照信息？
3. 子事务的资源（锁、内存）如何清理？
4. 嵌套保存点下的回滚如何处理？

### 问题15：子事务的代价

1. 为什么子事务会影响性能？
2. 子事务与快照管理的关系是什么？
3. 过多的子事务会导致什么问题？

---

## 第六层：事务与其他模块的交互（问题16-18）

### 问题16：事务与缓存失效

1. 元数据修改时，如何通知其他事务？
2. InvalidateSystemCaches() 函数在什么时候被调用？
3. Inval Message 如何跨进程传播？
4. 缓存失效与事务提交的同步关系是什么？

### 问题17：事务与触发器

1. BEFORE/AFTER 触发器在事务流程中的执行位置？
2. 触发器中的事务修改是否参与主事务的提交？
3. 触发器中的错误如何影响事务状态？
4. DEFERRABLE 与触发器的关系是什么？

### 问题18：事务与复制

1. synchronous_commit 参数与流复制的关系？
2. 主库事务提交时，如何等待从库应答？
3. 同步复制失败时的降级策略？
4. 级联复制中的事务一致性保证？

---

## 第七层：性能与优化（问题19-21）

### 问题19：事务启动优化

1. 为什么要延迟分配 XID？
2. 只读事务是否需要分配 XID？如何优化？
3. 自动提交模式与显式事务的性能差异？
4. CommitTransactionCommand() 与 CommitTransaction() 的关系？

### 问题20：提交性能瓶颈

1. WAL 刷盘通常是最大的性能瓶颈吗？
2. synchronous_commit 的不同设置对性能的影响量化？
3. 批量提交（group commit）如何实现？
4. full_page_writes 参数对性能的影响？

### 问题21：事务吞吐量

1. 什么是"连接效应（connection effect）"？
2. 如何监控事务的平均响应时间？
3. 长事务对其他事务的影响？
4. 如何识别和优化慢事务？

---

## 第八层：故障与恢复（问题22-24）

### 问题22：部分故障场景

1. 事务提交时磁盘写入失败，如何处理？
2. WAL 缓冲区溢出时的降级策略？
3. OOM（内存不足）时事务如何清理？
4. 网络中断导致同步复制超时，是否回滚？

### 问题23：长事务的影响

1. 长事务为什么会导致 VACUUM 无法清理？
2. 长事务对 xmin horizon 的影响？
3. 长事务如何被识别和警告？
4. 如何强制终止长事务？

### 问题24：事务日志维护

1. clog（Commit Log）的作用是什么？
2. pg_xact 目录中的文件如何组织？
3. 事务状态如何从 xact.c 中的数组写入 clog？
4. clog 的自动清理策略是什么？

---

## 第九层：高级特性（问题25-27）

### 问题25：分布式事务（两阶段提交）

1. PREPARE TRANSACTION 做了什么？
2. Prepared Transaction 的状态如何存储？
3. COMMIT PREPARED 与常规 COMMIT 的区别？
4. 如何恢复未完成的 Prepared Transaction？

### 问题26：逻辑复制中的事务

1. 逻辑解码如何追踪事务的开始和结束？
2. DecodeTransaction 函数的作用？
3. 大事务如何分段传输？
4. 逻辑槽（logical slot）与事务的关系？

### 问题27：事务快照导出

1. 什么是"事务快照导出（txid_snapshot）"？
2. txid_snapshot_xmin() 等函数有什么用途？
3. 如何用快照导出来实现跨会话的一致性读？

---

## 第十层：源码细节（问题28-30）

### 问题28：全局变量与进程本地存储

1. CurrentTransactionState 的作用？
2. MyProc 结构体记录了什么信息？
3. TransactionId 如何在全局范围内保持唯一性？
4. 为什么需要 procArray（活跃事务数组）？

### 问题29：内存上下文与事务生命周期

1. TopMemoryContext、CurTransactionContext、MessageContext 各的作用？
2. 为什么每个事务需要独立的内存上下文？
3. 内存溢出时如何清理？
4. pfree() 与 MemoryContextDelete() 的区别？

### 问题30：边界条件与异常处理

1. 事务 ID 溢出（XID wraparound）如何处理？
2. 进程意外终止时，事务资源如何清理？
3. 客户端连接突然断开，事务如何回滚？
4. 递归事务调用的限制是什么？

---

## 快速索引

| 问题范围       | 问题编号 | 核心源文件                     |
| -------------- | -------- | ------------------------------ |
| 基础事务模型   | 1-3      | xact.c                         |
| MVCC 与隔离    | 4-6      | snapmgr.c, procarray.c         |
| WAL 与持久化   | 7-9      | xlog.c, xloginsert.c           |
| 并发控制       | 10-12    | lock.c, deadlock.c             |
| 子事务与保存点 | 13-15    | xact.c                         |
| 事务交互       | 16-18    | sinval.c, trigger.c, syncrep.c |
| 性能与优化     | 19-21    | xact.c, xlog.c                 |
| 故障与恢复     | 22-24    | xlog.c, clog.c                 |
| 高级特性       | 25-27    | twophase.c, logical.c          |
| 源码细节       | 28-30    | proc.c, mmgr.c, miscadmin.c    |

---

**建议学习顺序：** 1→2→3→4→7→10→19→25→28，然后根据兴趣深入具体方向。
