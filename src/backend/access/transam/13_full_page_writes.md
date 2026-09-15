# Why: Full Page Writes

## 1. What is FPW

**Full Page Writes（FPW）**：在增量 WAL 之外，条件满足时把整张数据页（通常 8KB）写入 WAL。这份拷贝称 **Full Page Image（FPI）** / backup block。

- FPW：机制（GUC `full_page_writes`）
- FPI：WAL 中的整页字节

回放时若记录带可 APPLY 的 FPI，先整页覆盖，再处理后续增量。

---

## 2. 核心设计思想

- **问题**：页 8KB、扇区常 512B，崩溃可能留下新旧拼盘的半写页（torn page）；8KB ÷ 512B = **16 次扇区写（物理原子写）**
- **解法**：每个 checkpoint 周期内，页的**首次**修改附带 FPI(page 全量)，之后只记增量
- **代价**：WAL 体积增大，换崩溃后可恢复的一致页

---

## 3. 关键文件与 API

**源代码**:

- `src/backend/access/transam/xloginsert.c` — `XLogRecordAssemble` / `XLogCheckBufferNeedsBackup`
- `src/backend/access/transam/xlog.c` — `fullPageWrites` / `doPageWrites` / `GetFullPageWriteInfo` / `UpdateFullPageWrites`
- `src/backend/access/transam/xlogutils.c` — `XLogReadBufferForRedoExtended` / `RestoreBlockImage`
- `src/include/access/xlogrecord.h` — `BKPBLOCK_HAS_IMAGE` / `BKPIMAGE_APPLY`

**配置**: `full_page_writes`（默认 `on`）

**核心判定入口**（组装前）：

```c
GetFullPageWriteInfo(&RedoRecPtr, &doPageWrites);
rdt = XLogRecordAssemble(rmid, info, RedoRecPtr, doPageWrites, ...);
```

---

## 4. Why：半写页为何致命

WAL 正常路径：

```
改共享缓冲中的页 → 写增量 WAL → PageSetLSN →（稍后）刷脏页到数据文件
```

崩溃恢复从最近 checkpoint 的 `redo` 点重放。增量记录的隐含前提：

> 磁盘上该页 = 记录插入**之前**的完整、一致内容；只需按 WAL 再改一遍。

若刷脏页时 OS/磁盘只写完部分扇区：

```
理想 8KB 页:  [AAAAAAAA][AAAAAAAA][AAAAAAAA][AAAAAAAA]
半写后:       [BBBBBBBB][BBBBBBBB][AAAAAAAA][AAAAAAAA]   ← 新旧拼盘
```

此时：

1. 页校验和（若开启）会失败；
2. 更糟的是**无校验和时**：页看起来「能读」，但混了新旧字节；
3. 再套用「在干净旧页上 redo 增量」会得到**错误结果**，且可能无声损坏。

官方文档（`wal.sgml` / `full_page_writes` GUC）把这一点说死：进程中的 page write 可能只完成一部分，行级变更数据不足以完全恢复该页。

**FPW 的一句话回答 Why**：在页有机会被半写刷盘之前，先在 WAL 里留下一份完整「底片」；恢复时先整页覆盖，再（若有）应用后续增量。

---

## 5. When：何时拍整页映像

决策在 `XLogRecordAssemble`（`xloginsert.c`）：

```c
if (regbuf->flags & REGBUF_FORCE_IMAGE)
    needs_backup = true;
else if (regbuf->flags & REGBUF_NO_IMAGE)
    needs_backup = false;
else if (!doPageWrites)
    needs_backup = false;
else
{
    XLogRecPtr page_lsn = PageGetLSN(regbuf->page);
    needs_backup = (page_lsn <= RedoRecPtr);   /* 本 checkpoint 周期内首次修改 */
}
```

| 条件                     | `needs_backup` | 含义                                                         |
| ------------------------ | -------------- | ------------------------------------------------------------ |
| `REGBUF_FORCE_IMAGE`     | true           | 调用方强制 FPI（大改页时差分不划算）                         |
| `REGBUF_NO_IMAGE`        | false          | 明确不需要防半写（罕见）                                     |
| `!doPageWrites`          | false          | `full_page_writes=off` 且无在线备份                          |
| `page_lsn <= RedoRecPtr` | true           | 自上次 checkpoint redo 点以来尚未改过 → **首次修改，拍 FPI** |
| `page_lsn > RedoRecPtr`  | false          | 本周期已拍过 / 已有更新 LSN → 只写增量                       |

`doPageWrites` 定义（`xlog.c`）：

```c
doPageWrites = (Insert->fullPageWrites || Insert->runningBackups > 0);
```

即：GUC 开启 **或** 有在线备份在跑，都必须拍 FPI（备份依赖 WAL 中的完整页映像）。

有 FPI 时，默认**省略** `XLogRegisterBufData`（除非 `REGBUF_KEEP_DATA`）：

```c
needs_data = !needs_backup;   /* 有整页映像则增量 buf data 可省 */
```

---

## 6. How：如何使用 image

### 6.1 写入侧

`include_image = needs_backup || (info & XLR_CHECK_CONSISTENCY)`：

- 真正需要备份时置 `BKPIMAGE_APPLY`（回放必须覆盖）；
- 仅一致性检查时也可能带映像，但不一定 APPLY。

标准页（`REGBUF_STANDARD`）可挖「洞」：`pd_lower`～`pd_upper` 之间的空闲区不写入 WAL；可选 `wal_compression` 再压一档。

组装后的 block 布局（有 FPI 时）：

```
[Block Header | BKPBLOCK_HAS_IMAGE]
[Image Header | length / hole / compress flags]
[Full-Page Image 字节（可跳洞、可压缩）]
[可选 Buffer Data | 仅 KEEP_DATA]
```

### 6.2 回放侧

`XLogReadBufferForRedoExtended`：

```c
if (XLogRecBlockImageApply(record, block_id))
{
    /* 读入缓冲 → RestoreBlockImage 整页覆盖 → PageSetLSN → dirty */
    return BLK_RESTORED;   /* 调用方通常不必再套增量 redo */
}
else if (lsn <= PageGetLSN(page))
    return BLK_DONE;       /* 页已更新到此 LSN 之后，跳过 */
else
    return BLK_NEEDS_REDO; /* 在现有页上应用增量 */
```

崩溃恢复时：若磁盘页已半写，FPI 直接盖掉；若页完好且 LSN 已够新，跳过。

### 6.3 与 `WILL_INIT` / `INSERT+INIT` 的关系

`REGBUF_WILL_INIT` / `BKPBLOCK_WILL_INIT`：**不拍 FPI**，但 redo 必须用 `RBM_ZERO_*` 从零重建页。

空表首插的 `INSERT+INIT`（见 traces / L001）走的是「整页重建」路径，效果上同样避开「在半写旧页上套增量」——与 FPW 是两类互斥手段：

| 手段            | 何时               | 基线从哪来            |
| --------------- | ------------------ | --------------------- |
| Full Page Image | 本周期首次改已有页 | WAL 里的整页底片      |
| WILL_INIT       | 新建 / 重初始化页  | redo 清零后按记录重建 |

---

## 7. 与 Hint Bits / Checksum 的边角(略)

普通 hint bit 更新默认不记 WAL。但若开了 **data checksums** 或 `wal_log_hints`：

```c
#define XLogHintBitIsNeeded() (DataChecksumsEnabled() || wal_log_hints)
```

半写会让「任意 bit 组合都逻辑自洽、但校验和错乱」。于是通过 `XLogSaveBufferForHint` 在本 checkpoint 周期内对该页补一次 FPI（`XLOG_FPI_FOR_HINT`），保护校验和语义。

---

## 8. 性能与运维要点

| 点                   | 说明                                                                                 |
| -------------------- | ------------------------------------------------------------------------------------ |
| WAL 膨胀             | 每个页每 checkpoint 周期最多一次 ~8KB 映像（可挖洞/压缩）                            |
| 降低代价             | 拉长 `checkpoint_timeout` / `max_wal_size` → 单位时间 FPI 次数下降                   |
| 何时可关             | 文件系统保证无 partial page write（如部分 ZFS 场景）；风险类似关 `fsync`，需同等谨慎 |
| 在线备份             | 备份期间强制 FPI                                                                     |
| 与 MySQL Doublewrite | 同为防半写；PG 把底片放进 WAL，不另建 doublewrite buffer                             |

---

## 9. 判定速查

```
改页且要写 WAL？
  ├─ REGBUF_WILL_INIT        → 不拍 FPI，redo 清零重建
  ├─ REGBUF_FORCE_IMAGE      → 必拍 FPI
  ├─ REGBUF_NO_IMAGE         → 不拍
  ├─ !doPageWrites           → 不拍（配置关且无备份）
  └─ page_lsn <= RedoRecPtr  → 拍 FPI（本周期首次）
       else                  → 只写增量 BufData / MainData
```

---

## 10. 总结

1. **Why**：8KB 页可能半写；增量 WAL 不能在「拼盘页」上安全 redo。
2. **What**：checkpoint 后每页第一次修改附带 Full Page Image。
3. **How**：`XLogRecordAssemble` 用 `doPageWrites` + `page_lsn <= RedoRecPtr` 判定；redo 走 `RestoreBlockImage`。
4. **Trade-off**：WAL 变大 ↔ 崩溃后页可重建；拉长 checkpoint 或压缩是常见降本手段。
