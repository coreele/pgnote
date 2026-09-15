# What & Why: Atomic Action (Mini-Transaction)

## 1. 是什么

**MTR（Mini-Transaction）** 在源码里叫 **atomic action**：比 SQL 事务更小的物理原子单元。一次 atomic action = 临界区里「改（多）页 + 写一条 WAL + 给相关页设 `pd_lsn`」。崩溃恢复时，这条 WAL 要么整段 redo，要么整段跳过。

```text
pin + exclusive lock
  -> (临界区外：空间检查等，ERROR 可接受)
START_CRIT_SECTION()
  -> 改共享缓冲 -> MarkBufferDirty
  -> XLogBeginInsert / Register* / XLogInsert
  -> PageSetLSN(EndRecPtr)
END_CRIT_SECTION()   // 区内 ERROR → PANIC
unlock / unpin
```

临界区内 ERROR 必须 PANIC：页已脏但 WAL 未记全时，若仅 ERROR 回滚，bgwriter 可能按旧 LSN 刷脏，造成静默损坏。

与用户事务的关系：一次 `BEGIN…COMMIT` 含多条 atomic action；COMMIT 前崩溃，已写 WAL 仍会 redo，未提交 XID 靠 MVCC 不可见。子事务回滚只改逻辑可见性，不撤销已落盘的 WAL 物理原子性。

---

## 2. 判定标准

**Redo 的原子边界 = 一条 WAL 记录。**

哪些页改动若只应用一半，读者/后续插入会看到**结构上不可搜索或不可修复**的状态？这些必须同记一条 WAL，包在同一临界区里。

---

## 3. 以 B-tree 页分裂为例

B-tree split 是理解 atomic action 最典型、也最复杂的多页场景。nbtree README 原话：`A single WAL entry is effectively an atomic action`；一次完整插入可能由多个 atomic action 串成。

### 3.1 本层 split：一条 WAL

`XLOG_BTREE_SPLIT` 必须同进同退的改动（本层一体）：

| 页       | 改动                                  |
| -------- | ------------------------------------- |
| 左页     | 收缩、high key、设 `INCOMPLETE_SPLIT` |
| 右页     | 新页 + 挪过去的元组                   |
| 原右兄弟 | 更新 left-link（若有）                |

**不在这一条里**：往父页插 downlink——缺 downlink 时树仍可搜索，靠 flag + 后续插入可补完。

```c
XLogBeginInsert();
XLogRegisterBuffer(0, leftbuf, REGBUF_STANDARD);
XLogRegisterBuffer(1, rightbuf, REGBUF_STANDARD);
/* 兄弟页 buffer、BufData / MainData ... */
XLogInsert(RM_BTREE_ID, XLOG_BTREE_SPLIT);
```

### 3.2 父页 downlink：下一条 WAL

```text
MTR-1  XLOG_BTREE_SPLIT
         left / right / sibling left-link
         (downlink 缺失；左页 INCOMPLETE_SPLIT)

MTR-2  父页插 downlink，清除 incomplete flag
         (父页满则可能继续 split，再产生更多 WAL)
```

两步之间的中间态是**设计允许的**：

- 读者靠 right-link 继续搜索，忽略 incomplete flag
- 插入者看到 flag 会 lazy finish split
- 正常运行时子页写锁跨过 MTR-1→MTR-2，防第二个 writer 重复补完
- 崩溃后 incomplete 由后续插入修复，不在 end-of-recovery 强行补完

### 3.3 对比：单页 heap insert

普通 `heap insert`：一页 + 一条 `XLOG_HEAP_INSERT`，是最简单的 atomic action。split 说明「一条 WAL 可覆盖多页」，以及「哪些多页必须一体、哪些可以拆成下一步」。

---

## 4. 速查

| 问题                             | 答案                                                     |
| -------------------------------- | -------------------------------------------------------- |
| 原子边界是什么？                 | 一条 WAL 记录（可含多 block）                            |
| split 几个 MTR？                 | 本层 split 一条；父级 downlink（及可能的上层 split）另算 |
| 为何 critical section 内 PANIC？ | 改页与记 WAL 之间失败会留下未记录脏页                    |
| 与 InnoDB MTR？                  | 借用 ARIES 叫法；PG 源码几乎只用 atomic action           |

---

## 5. 关键源码

| 概念          | 位置                                                          |
| ------------- | ------------------------------------------------------------- |
| 临界区        | `src/include/miscadmin.h` — `START_CRIT_SECTION`              |
| 多页 WAL 注册 | `src/backend/access/transam/xloginsert.c`                     |
| split 语义    | `src/backend/access/nbtree/README`；`nbtxlog.c` / `_bt_split` |

`_bt_split` / `XLOG_BTREE_SPLIT` 的逐页字段与实验对照，见 nbtree 写路径笔记。
