# delete

![](../../storage/assets/delete.svg)

在 PG 中，所谓的**删除**其实是**标记死亡** + **空间异步回收**。

---

## 打上“死亡标记”

执行 `DELETE FROM tb WHERE a = 1;` 时，磁盘上的数据并不会立即消失，而是发生了以下变化：

- **找到元组**：通过索引或全表扫描找到 `a=1` 的那行数据。
- **修改 `t_xmax`**：在元组头（`HeapTupleHeader`）中，原本为 0 的 `t_xmax` 被填入了**当前执行删除操作的事务 ID**。
- **状态标记**：`infomask` 会随之更新，记录该元组目前处于“被删除/锁定”的状态，取消标记与 `t_xmax` 相关的 `HEAP_XMAX_INVALID` 使其生效
- **物理现状**：
  - `ItemId` 依然是 `LP_NORMAL`，指向地址 `8160`。
  - 元组依然占据着那 28 字节的空间。
  - **可见性判定**：后续其他事务再来读时，发现 `t_xmax` 有值且事务已提交，跳过这行。

```
ExecutePlan | ExecProcNode | ExecProcNodeFirst
    ExecModifyTable
        ExecDelete | ExecDeleteAct
            table_tuple_delete
                heapam_tuple_delete
                    heap_delete
                        compute_new_xmax_infomask
```

## 页内修剪（Page Pruning）

这是为了防止 Page 空间过早耗尽。当下次有事务访问这个 Page，或者 Page 空间不足时：

- **判断过期**：根据 `prune_xid` 判定该元组已经对所有活跃事务都不可见。
- **物理抹除**：系统直接把 `upper` 到页尾之间的这 28 字节“活元组”进行平移，抹掉死元组。
- **指针重设**：`ItemId` 里的 `off` 被清空或重定向，但这个 `ItemId` **小方块本身还在**。
- **空间释放**：你图中的 `free space` 区域会由于元组的抹除而物理增大。

## 彻底清理（VACUUM）

虽然元组物理消失了，但那个 `ItemId` 指针还在占用 `pd_lower` 的空间。

- **回收 `ItemId`**：`VACUUM` 确认没有任何索引再指向这个元组。
- **标记 `LP_UNUSED`**：将 `ItemId` 的标志位改为 `LP_UNUSED`。
- **循环利用**：此时，`pd_lower` 计数器虽然没变，但这个“槽位”已经空出来了。下一个 `INSERT` 进来时，会优先抢占这个 `1` 号槽位，而不是去开辟 `4` 号槽位。

---

## 总结

- **逻辑删除 = 写 `t_xmax`**：数据依然在磁盘，只是通过 MVCC 逻辑让别人“看不见”。
- **空间回收 = 移动 `upper` 指针**：通过 `Pruning` 或 `VACUUM` 把原本被占据的区域划归回 `free space`。
