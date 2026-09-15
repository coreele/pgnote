# Freeze

# Freeze（元组冻结）

**概要**：XID 仅 32 位，用尽后会回绕。若页中老元组的 `xmin` 与当前 XID 的间隔逼近 2³¹，该元组会被误判为「未来事务插入」而不可见。freeze 在回绕临近前，将足够老的元组标记为**永久已提交**：此后判定可见性无需再查询 `pg_xact`（clog）。由此 `relfrozenxid` 得以推进，clog 得以截断。

**阅读建议**：首次阅读 §1–§4 建立整体认识，再运行 §11.1 的实验观察 infomask 位变化与 `relfrozenxid` 推进。§5–§7 为实现细节（两阶段处理、WAL、追踪器）。§8、§10–§11 分别给出防御阈值、核心函数与流程速查，可按需查阅。

---

## 1. XID wraparound

每个事务被分配一个 XID，记录于元组的 `xmin` / `xmax` 字段，作为可见性判定的依据。由于 XID 仅 32 位，约 42 亿个即告耗尽，PostgreSQL 将其视为环形计数器：分配至 2³²−1 后回绕至 3，先后关系按模 2³² 的有符号差计算：

```c
TransactionIdPrecedes(a, b) ≡ (int32)(a - b) < 0   /* 「过去」与「未来」各占 2³¹ */
```

由此产生一个问题：设某元组 `xmin = 5`（对应早已提交的事务），只要系统持续分配 XID，该值与 `nextXID` 的间隔便不断增大。当间隔逼近 2³¹ 时，`(int32)(5 - nextXID)` 的符号发生翻转，该元组将被判定为「未来事务插入」，对所有快照不可见，等价于数据丢失；且若 clog 已截断，其提交记录亦无从查证。

对策（freeze）：在间隔逼近 2³¹ 之前，将老元组的可见性判定由「依据 XID 与 clog」改为「永久可见」。一次冻结产生三项结果：

1. **可见性**：设置 `HEAP_XMIN_FROZEN` 后，任何快照无需查询 clog 即可判定该元组可见；
2. **推进 `relfrozenxid`**：该字段语义为「表中所有 `XID < relfrozenxid` 的元组均已冻结（或不存在）」，即表内仍需查询 clog 的 XID 下界；其值推进越远，后续冻结工作量越小；
3. **clog 截断**：全库各表 `relfrozenxid` 的最小值记录于 `datfrozenxid`，早于该值的 `pg_xact` 段可由 `vac_truncate_clog()` 删除。

`xmax` 与 MultiXactId 同理：未冻结的锁 / update 痕迹同样会推迟 `relfrozenxid` / `relminmxid` 的推进，因此 freeze 须连同 `xmax`（含 multi 成员）一并处理。

---

## 2. `HEAP_XMIN_FROZEN`

冻结并非改写数据，而是修改元组头 `infomask` 的两个位，合成「永久已提交」标记：

```c
#define HEAP_XMIN_COMMITTED 0x0100   /* hint bit：xmin 已提交 */
#define HEAP_XMIN_INVALID   0x0200   /* 单独出现时表示 xmin 已 abort */
#define HEAP_XMIN_FROZEN    (HEAP_XMIN_COMMITTED | HEAP_XMIN_INVALID)  /* = 0x0300：永久已提交 */
```

要点：

- **不改写 xmin**：自 PG 9.4 起，冻结仅设置 `HEAP_XMIN_FROZEN`，保留原始 xmin（便于调试与 pg_upgrade）。`HeapTupleHeaderGetXmin()` 对冻结元组返回 `FrozenTransactionId`，可见性代码无需感知该标记；
- **位的组合语义**：`COMMITTED | INVALID` 在正常事务流程中不可能同时出现；冻结后该组合表示「元组已永久提交，与 XID 环位置无关」；
- **唯一例外 `xvac`**：该字段（PG 9.0 之前 `VACUUM FULL` 的 `HEAP_MOVED_OFF/IN` 遗留）仍会写入 `FrozenTransactionId` / Invalid。现代版本中已极少出现，但代码仍需兼容。

实测（见 §11.1）：新插入行 `t_infomask = 2048`（`HEAP_XMAX_INVALID`）；`VACUUM FREEZE` 后变为 `2816 = 2048 | 0x0300`，`t_xmin` 数值不变。

---

## 3. freeze cutoff

冻结前需分别判定两个问题，各对应一个 cutoff：

| 问题 | cutoff | 规则 |
| --- | --- | --- |
| ① 本页是否存在回卷风险？ | `FreezeLimit` | `xmin < FreezeLimit` ⇒ 必须冻结，VACUUM 不得跳过 |
| ② 可将冻结范围扩展至多老？ | `OldestXmin` | 事务已结束于 `OldestXmin` 之前者，可一并冻结，以尽量推进 `relfrozenxid` |

- ② 的范围包含 ①：`FreezeLimit` 被 clamp 至 ≤ `OldestXmin`。① 为防止回卷的安全底线；② 为减少后续冻结工作量的成本优化。
- MultiXact 对应一对 cutoff：`MultiXactCutoff`（必须冻结）与 `OldestMxact`（可扩展范围）。

**示例**（数值为示意）：设 `nextXID = 1000`、`vacuum_freeze_min_age = 100` ⇒ `FreezeLimit = 900`；`OldestXmin ≈ 998`。则页内 `xmin = 850` 的元组必须冻结；`xmin = 950` 的元组非强制（> 900），但可一并冻结；`xmin = 999` 对应事务可能仍在运行（≥ `OldestXmin`），不可冻结。

cutoff 的计算来源（`vacuum_get_cutoffs()`；默认参数见括号）：

| cutoff            | 计算                                                                        |
| ----------------- | ------------------------------------------------------------------------- |
| `FreezeLimit`     | `nextXID − vacuum_freeze_min_age`（5000 万），再 clamp ≤ `OldestXmin`          |
| `OldestXmin`      | `GetOldestNonRemovableTransactionId()`：仍可能被某快照引用的最老事务                     |
| `MultiXactCutoff` | `nextMXID − vacuum_multixact_freeze_min_age`（500 万），clamp ≤ `OldestMxact` |
| `OldestMxact`     | `GetOldestMultiXactId()`                                                  |

防止 anti-wraparound 触发过频的 GUC 约束：`freeze_min_age ≤ autovacuum_freeze_max_age / 2`；`freeze_table_age ≤ 0.95 × autovacuum_freeze_max_age`。

---

## 4. freeze time

freeze 无独立命令入口，作为 lazy `VACUUM` 扫描页面的一部分在 `lazy_scan_prune()` 中执行。是否实际执行冻结取决于触发路径：

| 入口 | 触发条件 |
| --- | --- |
| 普通 `VACUUM` / autovacuum | 页内存在 < `FreezeLimit` 的 XID 时强制冻结；否则是否附带冻结由 VACUUM 依据成本决定 |
| anti-wraparound autovacuum | 表 `relfrozenxid` 年龄超过 `autovacuum_freeze_max_age`（默认 2 亿）时自动发起，可绕过多数成本限制；空表同样处理（避免其 `relfrozenxid` 成为全库最老） |
| `VACUUM FREEZE` | 将四个 freeze age 全部置 0，尽量全冻 |
| `CLUSTER` / `VACUUM FULL` | `rewriteheap.c` 重写新堆时调用 `heap_freeze_tuple()`；不单独写 WAL，随整体重写落盘 |
| WAL replay | `heap_xlog_freeze_page()` 应用 `XLOG_HEAP2_FREEZE_PAGE` |

**aggressive 模式**：当 `relfrozenxid ≤ nextXID − freeze_table_age`（默认 1.5 亿；`VACUUM FREEZE` 因 age 置 0 必然触发）时，VACUUM 进入 aggressive 模式，目标为「至少将 `relfrozenxid` 推进至 `FreezeLimit`」。因此：

- 页面跳过条件收紧：普通 VACUUM 可跳过连续 ≥ 32 页的 all-visible 区间；aggressive 仅可跳过 all-frozen 页——all-visible 页内仍可能残留 < `FreezeLimit` 的未冻结 XID；
- 未能取得 cleanup lock 的页：普通 VACUUM 直接跳过；aggressive 由 `lazy_scan_noprune()` 仅收集 LP_DEAD 后返回 false，等待并重试 `lazy_scan_prune()`；
- `VACUUM (DISABLE_PAGE_SKIPPING)` 强制 aggressive，且连 all-frozen 页也不跳过。

> 注意：手工 `VACUUM` 不读取表级 reloption 的 `autovacuum_freeze_*`（仅 autovacuum 使用），手工路径通过 GUC 控制：`SET vacuum_freeze_table_age = 0` 可触发 aggressive。

---

## 5. freeze process

冻结实现分为两阶段
- prepare 可能读取 clog / multixact（代价较高），在临界区外执行；
- execute 改写 tuple 头并写入 WAL，在临界区内原子完成，以尽量缩短持锁时间。

### 5.1 prepare

prune 之后，对每个 `LP_NORMAL` 元组先用 `HeapTupleSatisfiesVacuum` 确认其存活（DEAD 元组在 prune 阶段已被移除，不会进入冻结流程），再调用 `heap_prepare_freeze_tuple()`，在内存中构造 `HeapTupleFreeze` 计划（目标 xmax / infomask / frzflags / checkflags），同时维护页级 `HeapPageFreeze` 状态。各字段的判定如下：

| 字段 | 冻结条件 | 动作 |
| --- | --- | --- |
| `xmin` | `< OldestXmin` | `infomask \|= HEAP_XMIN_FROZEN`；执行时复核 committed |
| `xmax`（普通） | `< OldestXmin` | 清空 xmax、置 `HEAP_XMAX_INVALID`；非 lock-only 则复核 aborted |
| `xmax`（multi） | `FreezeMultiXactId()` | 四种处理结果，见下 |
| `xvac` | 存在即冻结 | 写入 `FrozenTransactionId` / Invalid |

两点说明：

- 已提交 updater 的 xmax 不可能 < `OldestXmin`（否则整个元组早已 DEAD 并被移除），因此进入 freeze_xmax 路径的仅有 **lock-only 与 aborted updater**；
- **不信任 hint bit**：checkflags（如 `HEAP_FREEZE_CHECK_XMIN_COMMITTED`）要求在执行阶段的临界区之外复核 clog（代价高，不能反复执行），复核失败即报 `DATA_CORRUPTED`。

`FreezeMultiXactId()` 的四种处理结果（除 NOOP 外均强制 `freeze_required`）：

| flags | 场景 | 动作 |
| --- | --- | --- |
| `FRM_NOOP` | multi 尚新（成员可能 in-progress） | 原样保留，仅回退 NoFreeze 追踪器 |
| `FRM_INVALIDATE_XMAX` | 旧 multi 且 lock-only / 成员均可弃 | 直接清空 xmax |
| `FRM_RETURN_IS_XID` | 仅剩一个 updater 成员 | 以普通 XID 替换 multi（可附 `FRM_MARK_COMMITTED`） |
| `FRM_RETURN_IS_MULTI` | ≥ 2 个存活成员 | 分配仅含存活成员的新 multi（尽量避免） |

处理 multi 的目的：避免旧 multi 推迟 `relminmxid` 的推进，并减少对 SLRU 的重复访问。

### 5.2 execute

按页决策，满足下列任一条件即进入 freeze path：

```text
pagefrz.freeze_required                             -- 页内含 < FreezeLimit 的 XID，必须冻结
OR tuples_frozen == 0                               -- 无任何冻结计划，执行代价可忽略；且页面因此可标记 all-frozen
OR (all_visible && all_frozen && prune 已产生 FPI)   -- 页面因 prune 已生成 FPI、必然写 WAL，可一并完成冻结
```

- **freeze path**：`heap_freeze_execute_prepared()` 在临界区内逐元组调用 `heap_execute_freeze_tuple()` 并写 WAL（§6）；页级追踪器采用 `FreezePageRelfrozenXid/RelminMxid`；
- **no-freeze path**：追踪器采用 `NoFreezePage*`（回退至页内仍残留的最老 XID），并强制 `all_frozen = false`——仅执行 freeze path 的页面才可能被标记为 VM all-frozen。

当各存活元组的 xmin/xmax 均已（或将）冻结（`totally_frozen`）时，页级 `all_frozen` 成立；其与 `all_visible` 共同决定 `lazy_scan_heap` 是否调用 `visibilitymap_set(..., ALL_VISIBLE | ALL_FROZEN)`。

---

## 6. WAL

冻结修改并非 hint bit，不能丢失。原因：若 `relfrozenxid` 已推进、clog 已按 `datfrozenxid` 截断，此后发生崩溃并丢失冻结记录，则元组 xmin 的真实提交状态将无从查询。因此每次冻结均写入 `XLOG_HEAP2_FREEZE_PAGE`：

```text
xl_heap_freeze_page { snapshotConflictHorizon, isCatalogRel, nplans }
plans[]   /* 去重后的冻结计划: xmax / infomask / infomask2 / frzflags / ntuples */
offsets[] /* 按 plan 分组的元组偏移 */
```

- **计划去重**（`heap_log_freeze_plan`）：同页多数元组共享相同的冻结动作，排序合并后每条 plan 只记录一份，并附带元组偏移序列；
- **`snapshotConflictHorizon`**：页面即将标记 all-frozen 时取 `visibility_cutoff_xid`（该值随即清空，之后的 `visibilitymap_set` 可传 Invalid）；否则保守取 `OldestXmin − 1`，避免与 hot standby 快照冲突；
- **redo**（`heap_xlog_freeze_page`）：hot standby 先执行 `ResolveRecoveryConflictWithSnapshot`，再按 plan / offset 重放 `heap_execute_freeze_tuple`。

---

## 7. VM

**NewRelfrozenXid 追踪器**：`vacrel->NewRelfrozenXid` 初始化为 `OldestXmin`（乐观上界），扫描中每遇未冻结而残留的老 XID（含 multi 成员）即回退；该值不会低于表原有的 `relfrozenxid`（即本次扫描的安全下界）。每页按 §5.2 的决策，择一提交 FreezePage* 或 NoFreezePage* 两套追踪器。收尾规则：

- **aggressive**：最终值必须 ≥ `FreezeLimit`（有断言保证）；若因跳过页面（如 `skippedallvis`）无法证明该下界，则保留原 `relfrozenxid`；
- **非 aggressive**：可推进任意幅度，也可不推进；
- `vac_update_relstats()` 将结果写回 `pg_class.relfrozenxid` / `relminmxid`；全库各数据库 `datfrozenxid` 的最小值驱动 `vac_truncate_clog()`。

**VM all-frozen**：置位条件为「页面执行 freeze path、`all_visible` 与 `all_frozen` 均成立、且无 LP_DEAD」。`lazy_scan_heap` 持堆页锁设置 `PD_ALL_VISIBLE` 并调用 `visibilitymap_set`（WAL：`log_heap_visible`）。DML / tuple lock 破坏页内状态时相应清除标记（见 [VM](./06_vm.md)）。收益：all-frozen 页不再包含 < `FreezeLimit` 的 XID，aggressive VACUUM 亦可跳过，后续无需重复冻结。

---

## 8. failsafe

`SetTransactionIdLimit()`（`varsup.c`）以全库最老 `datfrozenxid` 为基准设置四级阈值：

| 阈值 | 取值（默认） | 动作 |
| --- | --- | --- |
| autovacuum | `oldest + autovacuum_freeze_max_age`（2 亿） | 触发 anti-wraparound autovacuum（并逐库连续处理） |
| WARNING | `wrapLimit − 4000 万` | 输出日志 "database must be vacuumed within N transactions" |
| 停止分配 | `wrapLimit − 300 万` | 拒绝分配新 XID（只读不受影响；单用户模式供 DBA 恢复） |
| wrapLimit | `oldest + 2³¹` | 理论回绕点，不可越过 |

**failsafe**（PG 12+）：表 `relfrozenxid` 老于 `max(vacuum_failsafe_age, 1.05 × autovacuum_freeze_max_age)`（默认 16 亿）时，正在进行的 aggressive VACUUM 放弃索引清理与表截断，仅以尽快推进 `relfrozenxid` 为目标。

---

## 10. call stack

```text
ExecVacuum | vacuum
    vacuum_rel | table_relation_vacuum
        heap_vacuum_rel | lazy_scan_heap
            vacuum_get_cutoffs        /* OldestXmin, FreezeLimit, MultiXactCutoff; aggressive? */
            lazy_scan_skip            /* aggressive 只能跳 all-frozen 页 */
            lazy_scan_prune           /* Prune, freeze, and count tuples */
                heap_page_prune       /* 先回收 HOT 死版本 */
                HeapTupleSatisfiesVacuum          /* DEAD 元组已被 prune，不会进入冻结 */
                heap_prepare_freeze_tuple         /* 每个 LP_NORMAL：在内存中构造计划 */
                    heap_tuple_should_freeze      /* 页内存在 < FreezeLimit 的 XID? */
                    FreezeMultiXactId             /* xmax 为 multi 时 */
                [decide: freeze_required || tuples_frozen==0 || FPI]
                heap_freeze_execute_prepared      /* 临界区内原子执行 */
                    heap_execute_freeze_tuple     /* 改写 tuple 头 */
                    XLogInsert(RM_HEAP2_ID, XLOG_HEAP2_FREEZE_PAGE)
                visibilitymap_set                 /* ALL_VISIBLE | ALL_FROZEN */
            vac_update_relstats       /* 推进 pg_class.relfrozenxid / relminmxid */
    vac_truncate_clog                /* 按全库最老 datfrozenxid 截断 clog */
```

---

## 11. case

- 基础：观察 infomask 变化、relfrozenxid 推进与 VM 标记

```sql
CREATE EXTENSION IF NOT EXISTS pageinspect;
CREATE EXTENSION IF NOT EXISTS pg_visibility;

DROP TABLE IF EXISTS test_freeze;
CREATE TABLE test_freeze (id int PRIMARY KEY, val int)
  WITH (autovacuum_enabled = off);

INSERT INTO test_freeze VALUES (1, 1), (2, 2), (3, 3);

-- 冻结前：t_infomask = 2048 (HEAP_XMAX_INVALID)，尚无 xmin hint
SELECT lp, t_xmin, t_xmax, t_infomask, to_hex(t_infomask)
FROM heap_page_items(get_raw_page('test_freeze', 0));

SELECT relfrozenxid, age(relfrozenxid) FROM pg_class WHERE relname = 'test_freeze';

VACUUM FREEZE test_freeze;

-- 冻结后：t_xmin 不变；t_infomask = 2816 = 2048 | 0x0300 (HEAP_XMIN_FROZEN)
SELECT lp, t_xmin, t_xmax, t_infomask, to_hex(t_infomask)
FROM heap_page_items(get_raw_page('test_freeze', 0));

SELECT relfrozenxid, age(relfrozenxid) FROM pg_class WHERE relname = 'test_freeze';

-- VM：页面已标记 all-visible + all-frozen
SELECT blkno, all_visible, all_frozen FROM pg_visibility_map('test_freeze');
```

- lock-only xmax 被冻结清除

```sql
BEGIN; SELECT * FROM test_freeze WHERE id = 1 FOR SHARE; COMMIT;

-- lp1: t_xmax = 加锁事务 XID（lock-only）
SELECT lp, t_xmin, t_xmax, t_infomask
FROM heap_page_items(get_raw_page('test_freeze', 0));

VACUUM FREEZE test_freeze;

-- lp1: t_xmax = 0 —— freeze_xmax 路径清除了 lock-only xmax
SELECT lp, t_xmin, t_xmax, t_infomask
FROM heap_page_items(get_raw_page('test_freeze', 0));
```

（若要观察真正的 multi xmax，需两个并发会话先后执行 `FOR SHARE` / `FOR UPDATE` 后提交。）

- aggressive 模式与 VACUUM VERBOSE 输出

```sql
SET vacuum_freeze_table_age = 0;
VACUUM VERBOSE test_freeze;
-- INFO:  aggressively vacuuming ...
-- new relfrozenxid: 14661, which is N XIDs ahead of previous value
-- frozen: 0 pages ... had 0 tuples frozen   <- 已冻结的表再次 FREEZE，通常无元组可冻
```

- pg_waldump：观察 FREEZE_PAGE 记录

```sql
SELECT pg_current_wal_lsn();          -- 记录起点
UPDATE test_freeze SET val = val + 1 WHERE id = 2;  -- 产生新版本（HOT）
VACUUM FREEZE test_freeze;
SELECT pg_current_wal_lsn();          -- 记录终点
```

```text
$ pg_waldump -p $PGDATA -s <起点> -e <终点> | grep -E 'PRUNE|FREEZE'
rmgr: Heap2  ... desc: PRUNE  snapshotConflictHorizon: 14661, nredirected: 1, ... redirected: [2->4] ...
rmgr: Heap2  ... desc: FREEZE_PAGE snapshotConflictHorizon: 14661, nplans: 1,
                 plans: [{ xmax: 0, infomask: 11008, infomask2: 32770, ntuples: 1, offsets: [4] }], ...
```

HOT 新版本（offset 4）由一条**去重后的 plan** 冻结：`infomask 11008 = 0x2B00`（`HEAP_XMIN_FROZEN | HEAP_XMAX_INVALID | HEAP_UPDATED`）。
