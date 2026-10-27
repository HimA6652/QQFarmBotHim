# docs 目录说明

本目录只放**与当前版本一致的**说明文档；过时方案移入 `archive/` 并标注废弃原因，避免误导。

## 当前生效的方案（简要）

| 环节 | 现行做法 | 代码位置 |
|---|---|---|
| 账号登录 | **NapCat 扫码登录**（面板/主程序界面发起，NapCat 收码） | `core/src/services/napcat-login.js`、`core/src/controllers/admin-napcat-login-routes.js` |
| 微信账号 | 应用宝协议扫码 + `getFarmCode` 刷新 | `core/src/services/wx-login/`、`runtime/auto-code-refresh.js` |
| 手动填码 | 粘贴 Code | 账号新增弹窗 |
| 抓包登录 | 可选，需显式启动抓包服务 | `core/src/capture/` |

## 功能储备（未接入，勿按此实施）

- **本机取码器**：`fetcher/code-fetcher.mjs` + `core/src/controllers/local-code-routes.js`。
  代码保留但未在 `admin.js` 注册路由，面板也无入口；启用前需要补齐安全边界（回环来源 + 共享令牌）与面板 UI。
- 相关设计文档已归档，见下。

## 归档文档

| 文档 | 归档原因 |
|---|---|
| [archive/取码器方案.md](archive/取码器方案.md) | 「Code Hub」设计稿，适用对象是已废弃的 SnowLuma 宿主方案，从未实施 |
| [archive/取码器方案-注入式.md](archive/取码器方案-注入式.md) | 注入式取码路线（依赖 82MB 的 `fetcher/napcat/` 运行时）未落地即被放弃，现行方案改用 NapCat 官方扫码登录 |

归档文档保留原文，只加废弃横幅，便于追溯「为什么没走这条路」。
