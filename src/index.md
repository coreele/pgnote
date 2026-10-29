# Overview

- PostgreSQL 源码学习笔记，目录镜像 `src/backend/`，主要介绍 PG 数据库的核心模块运行机制
- 核心模块包括：解析、优化、执行、存储、内存、复制等，详细见相应目录
- 本文档大部分内容以用例和源码调用栈为主，assets 目录下包含原始绘图文件，建议使用 Obsidian 打开（需安装 Excalidraw 插件）
- 本文档配套讲解视频见： [https://space.bilibili.com/306901642](https://space.bilibili.com/306901642)

## 参考资料

- [PostgreSQL Internals (interdb.jp)](https://www.interdb.jp/pg/index.html)
- [PostgreSQL Source Code](https://github.com/postgres/postgres)

---

**Maintainer**: [coreele](https://github.com/coreele/pgnote)
