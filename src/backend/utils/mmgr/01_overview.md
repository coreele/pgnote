# Memory Overview

## MemoryContext

基础 malloc/free 独立分配释放，效率低、管理复杂。(**相当于直接在根目录下管理文件**)

```cpp
void *malloc(size_t size);
void *realloc( void *ptr, size_t new_size);
void free( void *ptr );
```

PostgreSQL 通过 **MemoryContext** 实现按生命周期统一内存管理，提升效率与可靠性。`palloc` (**相当于在根目录下创建子目录独立管理**)

## 核心 API

```cpp
void *palloc(Size size);
void *repalloc(void *pointer, Size size);
void pfree(void *pointer);
```

### 上下文相关核心 API

```cpp
/* 创建 */
AllocSetContextCreate
	AllocSetContextCreateInternal
		MemoryContextCreate

/* 切换 */
MemoryContextSwitchTo

/* 删除 （递归删除所有子上下文 + 释放内存）*/
MemoryContextDelete

/* 重置 （释放所有内存，但保留上下文本身）*/
MemoryContextReset
```

## 类比

| **MemoryContext 概念**    | **文件系统类比**  | **说明**                     |
| ------------------------- | ----------------- | ---------------------------- |
| `MemoryContext`           | 目录 (Directory)  | 内存对象的容器               |
| `TopMemoryContext`        | 根目录 `/`        | 永远存在，所有目录的父节点   |
| `palloc()`                | `touch file`      | 在当前目录下创建文件         |
| `CurrentMemoryContext`    | `pwd`             | 新文件默认创建在这里         |
| `MemoryContextSwitchTo()` | `cd /path/to/dir` | 切换当前工作目录             |
| `MemoryContextDelete()`   | `rm -rf dir`      | 删除目录及旗下所有文件       |
| `MemoryContextReset()`    | `rm -rf dir/*`    | 清空内容，目录留着下次复用   |
| `MemoryContextSetParent`  | `mv`              | 移动到其他上下文             |
| 子上下文                  | 子目录            | 父目录删除时，子目录自动被删 |
| 内存泄漏                  | 忘记删临时目录    | 文件残留，占用磁盘空间       |
