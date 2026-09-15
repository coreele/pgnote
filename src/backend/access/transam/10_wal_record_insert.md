# How: WAL Record Structure & Insertion

## 1. 定义

一条 WAL 记录在插入前于后端本地组装：先用 `XLogRegister*` 登记缓冲区与载荷，再由 `XLogInsert` → `XLogRecordAssemble` 链成可写入 WAL 缓冲的 `XLogRecData` 链表。实现主要在 `xloginsert.c`。

构造原则：

- **零拷贝**：`XLogRecData` 只保存指向调用方缓冲的指针，组装时改 `next`，不搬数据
- **两阶段**：注册收集；组装按磁盘记录布局链接（含可选 FPI）
- **对象池**：`XLogRecData` / `registered_buffer` 预分配，插入结束后重置计数，避免频繁 malloc

## 2. 关键文件与 API

- 实现：`src/backend/access/transam/xloginsert.c`
- 头文件：`src/include/access/xloginsert.h`、`xlog_internal.h`

```c
void XLogBeginInsert(void);
void XLogRegisterData(char *data, uint32 len);           /* main data */
void XLogRegisterBuffer(uint8 block_id, Buffer buffer, uint8 flags);
void XLogRegisterBufData(uint8 block_id, char *data, uint32 len); /* per-buffer data */
XLogRecPtr XLogInsert(RmgrId rmid, uint8 info);
```

须先 `XLogBeginInsert`，再 Register，最后 `XLogInsert`。对某一 `block_id` 调用 `XLogRegisterBufData` 之前，必须已对该 id 调用过 `XLogRegisterBuffer`。

## 3. 数据结构（简化）

```c
typedef struct XLogRecData {
    struct XLogRecData *next;
    char       *data;
    uint32      len;
} XLogRecData;
```

后端静态状态（概念视图）：

```c
/* Main data：XLogRegisterData */
static XLogRecData *rdatas;
static int num_rdatas;
static XLogRecData *mainrdata_head;
static uint64 mainrdata_len;

/* 每个已注册 buffer */
typedef struct {
    bool        in_use;
    uint8       flags;
    RelFileLocator rlocator;
    BlockNumber block;
    Page        page;
    XLogRecData *rdata_head;
    uint32      rdata_len;
} registered_buffer;

static registered_buffer *registered_buffers;
```

## 4. Main Data 与 BufData

| | Main Data（`XLogRegisterData`） | BufData（`XLogRegisterBufData`） |
| --- | --- | --- |
| 绑定 | 不绑定具体 page | 绑定已注册的 `block_id` |
| 典型内容 | 记录级元信息（`offnum`、flags、split 描述等） | 重做该页所需的页外载荷（新 tuple 字节、offset 列表等） |
| 大小 | 无 64KB 上限 | 单段 `len` ≤ 65535；可多次注册追加 |
| 与 FPI | 组装时通常仍保留 | 若该块带 full-page image，默认可省略；`REGBUF_KEEP_DATA` 可强制保留 |

选择：

1. 载荷明确属于某一页的 redo 材料 → BufData  
2. 跨页共享、或仅作记录头/操作描述、或可能 >64KB → Main Data  

组装顺序：按 `block_id` 链接各块的 FPI / BufData，最后接 Main Data。回放侧常先读 Main Data 取得上下文，再按块消费 buffer 侧数据。

```c
/* Heap insert */
XLogBeginInsert();
XLogRegisterBuffer(0, buffer, REGBUF_STANDARD);
XLogRegisterBufData(0, newtup->t_data, newtup->t_len);
XLogRegisterData(&xlrec, sizeof(xlrec));
XLogInsert(RM_HEAP_ID, XLOG_HEAP_INSERT);

/* B-tree split（多页） */
XLogBeginInsert();
XLogRegisterBuffer(0, leftbuf, REGBUF_STANDARD);
XLogRegisterBufData(0, moved_left, len0);
XLogRegisterBuffer(1, rightbuf, REGBUF_STANDARD);
XLogRegisterBufData(1, moved_right, len1);
XLogRegisterData(&split_meta, sizeof(split_meta));
XLogInsert(RM_BTREE_ID, XLOG_BTREE_SPLIT);
```

---

## 5. 注册与组装

注册结束后，调用方侧逻辑上存在多条链，例如：

```text
MainData:  [xlrec] -> NULL
Buffer 0:  [tuple_data] -> NULL
```

`XLogRecordAssemble`（示意）把它们收成一条链：

```c
static XLogRecData *
XLogRecordAssemble(RmgrId rmid, uint8 info, ...)
{
    XLogRecData *result = &hdr_rdt;

    for (block_id = 0; block_id <= max_registered_block_id; block_id++) {
        /* skip unused */
        if (needs_backup)
            /* link FPI chunks for this block */;
        if (needs_data)
            /* link rdata_head .. rdata_tail */;
    }
    if (mainrdata_len > 0)
        /* link mainrdata_head */;
    result->next = NULL;
    return &hdr_rdt;
}
```

逻辑链：

```text
[Header] -> [block0 ...] -> [block1 ...] -> [Main Data] -> NULL
```

落盘布局（概念）：

```text
+--------------------+
| XLogRecord header  |
+--------------------+
| Block 0 header     |
|   optional FPI     |
|   optional BufData |
+--------------------+
| Block 1 ...        |
+--------------------+
| Main Data          |
+--------------------+
```

是否附带 FPI、以及 BufData 是否省略，见 [Full Page Writes](./13_full_page_writes.md)。

---

## 6. RegisterBuffer 与 RegisterBufData

| | `XLogRegisterBuffer` | `XLogRegisterBufData` |
| --- | --- | --- |
| 作用 | 声明本记录修改哪一页（及 flags） | 提供该页 redo 所需的附加字节 |
| 限制 | — | 单次长度受 `uint16` 约束 |
| 与 FPI | 块始终参与记录（可含 image） | 有 FPI 时默认可不写 BufData |

仅注册 buffer 而不提供 BufData（且无 FPI）时，回放往往缺少「如何改」的材料；仅有 Main Data 而无 buffer 时，则缺少页定位。Heap insert 典型组合：

```c
XLogBeginInsert();
XLogRegisterBuffer(0, buffer, REGBUF_STANDARD);
xlrec.offnum = ItemPointerGetOffsetNumber(&newtup->t_self);
XLogRegisterData((char *) &xlrec, SizeOfHeapInsert);
XLogRegisterBufData(0, (char *) newtup->t_data, newtup->t_len);
XLogInsert(RM_HEAP_ID, XLOG_HEAP_INSERT);
```

| 操作 | Buffer | BufData | Main Data |
| --- | --- | --- | --- |
| Heap Insert | 目标页 | tuple 字节 | offnum / flags |
| B-tree Split | 多页 | 迁到各页的内容 | split 元信息 |
| Page Vacuum | 清理页 | 删除的 offset 等 | 元信息 |
| Meta 页更新 | meta 页 | 常无 | 新 meta 内容 |

约束：

- 未 `XLogRegisterBuffer(id, …)` 即对 `id` 调用 `XLogRegisterBufData` — 非法  
- 单次 BufData `len` > 65535 — 须拆成多次注册，或改走 Main Data  

---

## 7. 小结

1. 插入路径 = 注册（多链）+ 组装（按 block 再 Main）+ 写入 WAL。  
2. 三类登记：`RegisterBuffer`（页）、`RegisterBufData`（页附属 redo 数据）、`RegisterData`（记录级 Main Data）。  
3. 指针链表 + 对象池降低拷贝与分配；FPI 与 BufData 的取舍在组装阶段决定。
