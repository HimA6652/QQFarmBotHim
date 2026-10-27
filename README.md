# QQ农场助手（QQFarmBotHim）

主程序 + 控制面板 + NapCat 协议端 + 农场自动化。版本 `2.8.0-local.10`。

| 项 | 路径 |
|---|---|
| **源码工程（权威）** | 本仓库 |
| **运行实例（部署）** | `<部署目录>`（示例：`%ProgramData%\QQFarmBotHim`） |

> ⚠️ **改动只允许在源码工程进行**，构建后复制到部署目录；部署目录禁止直接编辑 `core/src`、`web/src`（这是 2026-10-26 事故的根因，详见 `QQFarmBotHim_事故根因分析报告_2026-10-26.md`）。部署记录见部署目录下的 `DEPLOY.md`。

## 结构

```
QQFarmBotHim/                  源码工程
├─ core/                       主程序（Node，150+ 源文件）
│  └─ src/
│     ├─ controllers/          管理界面 HTTP 路由（3007）
│     ├─ core/worker.js        账号 Worker（同时只跑 1000+ 条业务日志缓冲）
│     ├─ runtime/              运行时（engine / worker-manager / state / 日志缓冲 5 万条）
│     ├─ services/             业务（农场、好友、活动、奶茶、节令、NapCat 登录、推送）
│     ├─ utils/                协议（network / proto / tsdk wasm）、客户端档案
│     ├─ gameConfig/           种子/物品配置与命名图
│     └─ proto/                游戏 protobuf（含 player-login / solarterms / globalscene）
├─ web/                        主程序前端（Vue 3 + Vite，pnpm build:web）
├─ panel/                      控制面板（panel.ps1 + web）
├─ fetcher/                    本机取码器（MITM 方案，**当前未启用**，仅作功能储备）
├─ tools/                      抓码开关脚本 + CA 证书
└─ docs/                       文档索引（现行方案与功能储备）
```

## 端口

| 服务 | 端口 | 监听 | 说明 |
|---|---|---|---|
| 主程序管理界面 | 3007 | 0.0.0.0 | 账号/自动化/系统配置（**务必修改默认密码 admin/admin**） |
| 控制面板 | 3100 | 0.0.0.0 | 启停主程序/NapCat、看日志 |
| NapCat WebUI | 6099 | 127.0.0.1 | 仅本机，令牌由面板下发 |
| NapCat OneBot HTTP | 3000 | 127.0.0.1 | 带 token |
| 取码器 API/代理（未启用） | 8450 / 18000 | 本机/局域网 | 需 `--capture` 或 fetcher 显式启动 |

## 启动

1. 双击部署目录的 `启动控制面板.bat` → <http://127.0.0.1:3100>
2. 面板依次启动 NapCat、主程序；或双击 `启动.bat`
3. 停止：`停止.bat` 或面板按钮

## 登录方式

| 通道 | 说明 |
|---|---|
| QQ 扫码登录 | 面板/主程序界面发起，NapCat 收码（当前主用） |
| 微信扫码 | 微信账号走 `getFarmCode`，全自动 |
| 手动填码 / 抓包登录 | 粘贴 Code，或抓包服务采集 |
| 本机取码器 | `fetcher/` + `controllers/local-code-routes.js`，**未接入 admin.js，需要时再启用** |

## 开发与发布

```powershell
# 前端
cd <本仓库根目录>
pnpm -C web build          # vue-tsc -b && vite build（判类型通过前先删 web/node_modules/.tmp/*.tsbuildinfo）

# 部署（示例，详见部署目录 DEPLOY.md）
robocopy web\dist <部署目录>\web\dist /MIR
```

**发布前必做功能等价校验**（本次事故的直接教训）：构建产物中 `grep` 关键 UI 字符串并与线上版逐项计数比对——系统公告、连接参数、设备协议、Code/GID、QQ 扫码、服务器地址。

## 历史

- 本工程原名 `QQFarmBotS`（2026-10-21 从 `QQFarmBot` local.9 分叉的"去 NapCat + 本机取码器"实验分支）。
- 2026-10-26 事故复盘后，core 已从部署侧完整回写（协议 1.15、W/A/H/L 系列修复、节令/奶茶新玩法、anti-resale 与 NapCat autoCode 裁剪），web 已对齐 `QQFarmBot` local.9 并重放日志 24h 改动，工程更名为 `QQFarmBotHim`，成为唯一权威源码。
- 旧主线 `QQFarmBot` 与早期实验 `QQFarmBot-Dev` 已归档到工作区的归档目录（不随本仓库发布）。
