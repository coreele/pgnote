# PostgreSQL 源码笔记

PostgreSQL 内部机制学习笔记。侧重底层实现原理，配合源码调试记录。

在线阅读: [https://coreele.github.io/pgnote/](https://coreele.github.io/pgnote/)

## 本地预览（mdBook）

需已安装 [mdBook](https://rust-lang.github.io/mdBook/)（例如 `cargo install mdbook` 或 `brew install mdbook`）。

```bash
mdbook serve --open   # 本地服务，默认 http://localhost:3000 ，改文件自动刷新
mdbook build          # 输出到 book/（已在 .gitignore）
```

## Markdown 格式化

使用 [Prettier](https://prettier.io/)。行尾统一为 LF（见 `.gitattributes` / `.editorconfig`）。

```bash
npm install           # 安装 Prettier
git config core.hooksPath .githooks   # 启用仓库内 pre-commit（本机一次即可）
npm run format:src    # 格式化 src/、waiting/ 以及 README / TODO
npm run format        # 格式化全部未 ignore 的 .md
npm run format:check  # 仅检查，不改写
```

**提交前自动格式化**：`.githooks/pre-commit` 会对本次暂存的 `*.md` 跑 Prettier，改动会重新纳入暂存区。

## 参考文档

- https://www.interdb.jp/pg/index.html
- https://deepwiki.com/postgres/postgres/1-overview
- https://roadmap.sh/postgresql-dba
- https://postgrespro.com/blog/pgsql/3994098

---

**Maintainer**: [coreele](https://github.com/coreele)
