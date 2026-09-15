# How: CLOG (pg_xact)

## 1. 定义

Heap tuple 头部保存的是创建/删除该版本的 **XID**（`xmin` / `xmax`），并不保存该事务的提交结果。提交结果集中存放在 **CLOG**（Commit Log）中，磁盘路径为 `$PGDATA/pg_xact`。

每个已分配 XID 占用 **2 bit**，对应四种状态：

| 状态 | 含义 |
| ---- | ---- |
| in progress | 尚未写入终态（事务仍在执行，或状态尚未落盘） |
| committed | 已提交 |
| aborted | 已中止 |
| subcommitted | 子事务过渡态：子事务自身已结束，其祖先尚未完成整棵事务树的最终提交标记 |

可见性判定通过 `TransactionIdDidCommit` / `TransactionIdDidAbort` 查询 CLOG；若元组上已设置相应 hint bit，则可省略本次 CLOG 查找。

CLOG 不是 undo log：它不保存旧行镜像，仅记录事务结局。未提交事务所造成的堆修改在恢复后仍可能留在页面上，对快照不可见，随后由 VACUUM 回收。

---

## 2. 独立存储的原因

若将 committed / aborted 直接写在每一行上，提交时需要更新该 XID 触及的全部页面，代价过高。按 XID 集中索引后：

- 提交路径只需更新 CLOG 中少量状态位（以及子事务树）
- 读路径根据 XID 定位到对应 SLRU 页中的 2 bit

因此 CLOG 的空间开销很小（每 XID 2 bit）。XID 相关的主要约束来自 **32-bit 编号空间** 及 wraparound，需通过 freeze 等机制处理，与 CLOG 位图体积无关。

---

## 3. 源码入口

| 层次 | 位置 |
| ---- | ---- |
| CLOG 读写 | `src/backend/access/transam/clog.c` |
| 状态查询与提交标记 | `transam.c`：`TransactionIdDidCommit`、`TransactionIdAbortTree`、`TransactionIdCommitTree` 等 |
| SLRU 缓冲 | `slru.c`（`pg_xact` 与 `pg_subtrans` 共用） |
| 持久化目录 | `$PGDATA/pg_xact/` |

`TransactionIdCommitTree` 将顶级 XID 及其子 XID 标记为 committed。当事务状态跨越多个 CLOG 页时，采用 README 所述的子提交协议，以保证外部观察不会看到「部分已提交」的中间状态。

---

## 4. 提交路径中的位置

参见 [Process](./02_process.md) 中的 COMMIT 流程：

1. 事务执行期间，堆/索引修改及其 WAL 已按多次 MTR 写入。
2. COMMIT 写入 commit 记录；是否立即 `XLogFlush` 由 `synchronous_commit` 决定。
3. 调用 `TransactionIdCommitTree` 等将 CLOG 标记为 committed。
4. 此后，其他事务的快照与可见性逻辑可将该 XID 视为已提交。

**持久化顺序**：在将某一 CLOG 页写出之前，影响该页的 commit WAL 必须先达到安全位点（与关系页的 WAL-before-data 规则同类）。异步提交允许 commit 记录延迟 flush，但写出 CLOG 页时仍须满足上述约束。实现上，每个 clog 缓冲页缓存若干 LSN，用于记录「写出该页前 WAL 至少需推进到的位置」（详见 `transam/README` 异步提交一节）。

崩溃恢复时：

- 已 flush 的 WAL 经 redo 后，页面上可能仍保留未提交 XID 的修改；
- 仅当恢复后的 CLOG 中该 XID 为 committed 时，快照才视其效果为可见；
- redo 不会依据「未提交」回滚或擦除堆修改。

---

## 5. Hint bit

频繁访问 CLOG 存在开销。Heap 元组上的 hint（如 `HEAP_XMIN_COMMITTED`）缓存「xmin 已确认提交」的判定结果。

设置 hint 受 WAL / CLOG 进度约束：在对应 commit 尚未安全持久化之前，不得将「已提交」hint 随数据页写出。异步提交场景下，通常对照 clog 页上缓存的 LSN 决定是否允许设置 hint；若不允许，则下次可见性检查仍查询 CLOG。

Hint 为性能优化；权威状态仍以 CLOG（含恢复后的 CLOG）为准。

---

## 6. 子事务与 subcommitted

子事务可拥有独立 XID。父事务提交时，须将整棵 XID 树一并标记为 committed。

若相关状态位位于同一 CLOG 页，可一次完成标记。若跨越多个 CLOG 页，则采用两阶段协议：

1. 先将子事务标记为 `subcommitted`
2. 再将顶级事务及整树标记为 `committed`

子事务中止时通常立即标记为 `aborted`。`subcommitted` 在读路径上窗口极短；跨页提交协议的细节见 [README: pg_xact](./00_readme.md)。

父子 XID 关系保存在 `pg_subtrans`，不属于 CLOG。

---

## 7. 与相关模块的关系

| 模块 | 关系 |
| ---- | ---- |
| [XID](./05_xid.md) | 分配事务标识；CLOG 按标识存储提交状态 |
| [Snapshot](./07_mvcc_snapshot.md) / [Visibility](./08_mvcc_visibility.md) | 结合 DidCommit/DidAbort 与快照判定可见性 |
| [MTR](./12_mini_transaction.md) | 物理原子性由单条 WAL 保证；逻辑提交结果由 top XID 的 CLOG 状态决定 |
| [Crash redo](./15_crash_recovery_redo.md) | 使数据页与已 flush 的 WAL 一致；对外可见性仍取决于 CLOG |

组提交、CLOG 截断以及与 freeze / wraparound 的交界，见 XID wraparound 与 VACUUM 相关笔记。
