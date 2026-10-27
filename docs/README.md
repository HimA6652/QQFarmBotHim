# docs 目录说明

本目录只放**与当前版本一致的**说明文档。已废弃的方案文档不再随版本分发，需要追溯时查 git 历史。

## 当前生效的方案（简要）

| 环节 | 现行做法 | 代码位置 |
|---|---|---|
| 账号登录 | **NapCat 扫码登录**（面板/主程序界面发起，NapCat 收码） | `core/src/services/napcat-login.js`、`core/src/controllers/admin-napcat-login-routes.js` |
| 微信账号 | 应用宝协议扫码 + `getFarmCode` 刷新 | `core/src/services/wx-login/`、`runtime/auto-code-refresh.js` |
| 手动填码 | 粘贴 Code | 账号新增弹窗 |
| 抓包登录 | 可选，需显式启动抓包服务 | `core/src/capture/` |

## 已移除的历史方案

- **本机取码器**：代码（`fetcher/`、`core/src/controllers/local-code-routes.js`）已于 2026-10-27 随版本移除，面板中的对应入口同步删除。
  两版设计方案（Code Hub 与注入式）同样移除：前者面向已废弃的 SnowLuma 宿主，从未实施；后者依赖 82MB 的 `fetcher/napcat/` 注入运行时，未落地即放弃。
  需要了解历史决策时查 git 历史中的 `docs/取码器方案*.md` 与 `fetcher/code-fetcher.mjs`。
