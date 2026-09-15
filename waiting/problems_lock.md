# PostgreSQL 锁机制源码研习路线图

## 第一阶段：锁模式与映射 (基础)

1. PostgreSQL 支持哪些锁模式？各适用于什么 SQL 场景？
   - _源码提示：`src/include/storage/lockdefs.h` (LOCK_MODE 定义), `src/backend/catalog/heap.c` (DDL 锁调用)_
2. 行级锁（SELECT FOR UPDATE）与表级锁在代码入口上有何区别？
   - _源码提示：`heap_lock_tuple` vs `LockRelation`_
3. 锁模式兼容矩阵存储在何处？如何被查询？
   - _源码提示：`lock_compat_table` 数组_

## 第二阶段：内存结构与组织 (核心)

4. `LOCK`, `PROCLOCK`, `LOCALLOCK` 三者存储位置、作用域与生命周期有何不同？
   - _源码提示：`src/include/storage/lock.h` 结构体定义_
5. 共享内存中的锁表（LockTable）如何初始化？哈希键（TAG）如何构造？
   - _源码提示：`CreateLockTables`, `LOCKTAG` 结构_
6. 后端进程如何快速追踪自己持有的所有锁？
   - _源码提示：`local_lock_table` 哈希表，`ProcLockQueue`_
7. `LockMethodData` 数组的作用是什么？为何需要抽象层？
   - _源码提示：`lock_methods` 数组，区分默认锁与建议锁_

## 第三阶段：获取与冲突逻辑 (算法)

8. 获取锁时的冲突检查具体如何进行？关键判断代码在哪？
   - _源码提示：`LockAcquire` 函数中的冲突循环_
9. 为什么 COMMIT 时要释放所有锁？触发函数是什么？
   - _源码提示：`AtCommit_Locks`, `ResourceOwner`_
10. 获取锁失败时，进程状态如何变更？如何进入等待？
    - _源码提示：`LOCK_WAIT`, `ProcSleep`_

## 第四阶段：等待与死锁 (并发)

11. 等待队列（waitQueue）如何组织？唤醒机制如何实现？
    - _源码提示：`ProcQueue`, `ProcWakeup`_
12. 死锁检测进程何时启动？等待图（Wait Graph）如何构建？
    - _源码提示：`DeadlockCheck`, `lock_wait_timeout`_
13. 如何区分“死锁”与“锁超时”？错误码有何不同？
    - _源码提示：`ERRCODE_DEADLOCK_DETECTED` vs `ERRCODE_LOCK_NOT_AVAILABLE`_

## 第五阶段：进阶与差异 (深入)

14. LWLock 与 Heavy Lock 在实现上有何本质区别？适用场景分别是什么？
    - _源码提示：`src/include/storage/lwlock.h` vs `lock.h`_
15. 行锁（Tuple Lock）为何不存储在共享锁表中？如何持久化？
    - _源码提示：`t_infomask` (HEAP_XMAX_LOCK_ONLY), WAL 记录_
16. 保存点（SAVEPOINT）回滚时，锁如何处理？为何不释放？
    - _源码提示：`AtSubAbort_Locks`_
17. Advisory Lock 如何实现且不与事务绑定？
    - _源码提示：`pg_advisory_lock`, `LOCK_METHOD_DEFAULT` vs `LOCK_METHOD_ADVISORY`_

---

**学习建议：**

- **每回答完一个阶段的问题，输出一期视频。**
- **重点突破：** 第二阶段（数据结构）和第三阶段（冲突逻辑）是源码最复杂的部分，建议配合画图理解。
- **调试手段：** 使用 `gdb` 断点 `LockAcquire` 和 `ProcSleep`，观察共享内存变化。
