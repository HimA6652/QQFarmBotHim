#!/usr/bin/env node
/**
 * 取码器（Code Fetcher）
 * ---------------------------------------------------------------------------
 * 借鉴 NapCat 的注入方案，把「扫码登录 → 调 QQ 内部 OpenAuth 拿小程序码」这一小段
 * 做成一个可被面板拉起的短生命周期进程：
 *
 *   面板 --spawn--> 本进程 --注入--> QQ(内含 NapCat) --内部API--> 小程序 code
 *                <--HTTP 轮询 /state--                              |
 *                <--拿到 code 后：杀 QQ 进程树，本进程退出-----------
 *
 * 设计约束
 *   - 只做取码，不带 OneBot、不带插件市场；NapCat 仅作为注入与内部 API 的桥
 *   - 一次会话只服务一次取码；成功/失败/超时/取消 都会清理进程并退出
 *   - 与面板的解耦：本进程只在本机 127.0.0.1:<port> 暴露 /state 与 /cancel，
 *     不反向调用面板（面板无需知道回调地址）
 *
 * 用法
 *   node code-fetcher.mjs --port 8460 --appid 1112386029 --timeout 180
 *
 * 状态机
 *   booting → qr → scanning → logged → code → done
 *                ↘ error / cancelled（任何阶段）
 */

import { createRequire } from 'node:module';
import { spawn, spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');
const NAPCAT_DIR = path.join(__dirname, 'napcat');
const QQ_FALLBACK = path.join(ROOT, 'qqpath.txt');

// ---------------------------------------------------------------- 参数
function arg(name, fallback = '') {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}
const PORT = Number(arg('port', '8460'));
const APPID = String(arg('appid', '1112386029'));
const TIMEOUT_SEC = Number(arg('timeout', '180'));
const NAPCAT_PORT = Number(arg('napcat-port', '6099'));
const LOG = path.join(ROOT, 'logs', `fetcher-${new Date().toISOString().slice(0, 10)}.log`);

fs.mkdirSync(path.join(ROOT, 'logs'), { recursive: true });
function log(...args) {
  const line = `[${new Date().toISOString()}] ${args.join(' ')}`;
  try { fs.appendFileSync(LOG, `${line}\n`); } catch { }
  console.log(line);
}

// ---------------------------------------------------------------- 状态
const state = {
  phase: 'booting',      // booting | qr | scanning | logged | code | done | error | cancelled
  qr: '',                // 二维码原始内容（QQ 给的登录 URL）
  qrPng: '',             // 二维码渲染后的 dataURL（面板直接 <img src>）
  uin: '',
  nickname: '',
  code: '',
  error: '',
  appId: APPID,
  startedAt: Date.now(),
  updatedAt: Date.now(),
  attempts: [],
};

// 二维码渲染：借用主程序 node_modules 里的 qrcode；拿不到就退回只给原始 URL
const coreRequire = createRequire(path.join(ROOT, 'core', 'node_modules') + path.sep);
let QRCode = null;
try { QRCode = coreRequire('qrcode'); } catch { QRCode = null; }

async function renderQr(url) {
  if (!QRCode || !url) return '';
  try { return await QRCode.toDataURL(url, { margin: 1, width: 260, errorCorrectionLevel: 'M' }); }
  catch { return ''; }
}
function setState(patch) {
  Object.assign(state, patch, { updatedAt: Date.now() });
  log(`[state] ${state.phase}${state.error ? ' err=' + state.error : ''}${state.code ? ' code=' + state.code.slice(0, 4) + '…' : ''}`);
}

let childPid = 0;
let finished = false;

// ---------------------------------------------------------------- 工具
function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

async function httpJson(url, { method = 'GET', headers = {}, body, timeout = 8000 } = {}) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeout);
  try {
    const res = await fetch(url, {
      method,
      headers: { 'Content-Type': 'application/json', ...headers },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: ctrl.signal,
    });
    const text = await res.text();
    try { return { status: res.status, json: JSON.parse(text) }; }
    catch { return { status: res.status, json: null, text }; }
  }
  finally { clearTimeout(timer); }
}

function resolveQqPath() {
  const fromArg = arg('qq', '');
  if (fromArg && fs.existsSync(fromArg)) return fromArg;
  if (fs.existsSync(QQ_FALLBACK)) {
    const p = fs.readFileSync(QQ_FALLBACK, 'utf8').trim();
    if (p && fs.existsSync(p)) return p;
  }
  // 注册表（与 NapCat 官方 launcher 一致）
  try {
    const r = spawnSync('reg', ['query',
      'HKLM\\SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\QQ',
      '/v', 'UninstallString'], { encoding: 'utf8' });
    const m = /REG_SZ\s+(.+)/.exec(r.stdout || '');
    if (m) {
      const dir = path.dirname(m[1].trim().replace(/^"|"$/g, ''));
      const exe = path.join(dir, 'QQ.exe');
      if (fs.existsSync(exe)) return exe;
    }
  } catch { }
  return '';
}

// ---------------------------------------------------------------- NapCat 注入
function launchNapCat(qqPath) {
  const env = {
    ...process.env,
    NAPCAT_PATCH_PACKAGE: path.join(NAPCAT_DIR, 'qqnt.json'),
    NAPCAT_LOAD_PATH: path.join(NAPCAT_DIR, 'loadNapCat.js'),
    NAPCAT_INJECT_PATH: path.join(NAPCAT_DIR, 'NapCatWinBootHook.dll'),
    NAPCAT_LAUNCHER_PATH: path.join(NAPCAT_DIR, 'NapCatWinBootMain.exe'),
    NAPCAT_MAIN_PATH: path.join(NAPCAT_DIR, 'napcat.mjs'),
  };
  const launcher = path.join(NAPCAT_DIR, 'NapCatWinBootMain.exe');
  const hook = path.join(NAPCAT_DIR, 'NapCatWinBootHook.dll');
  if (!fs.existsSync(launcher) || !fs.existsSync(hook)) {
    throw new Error(`NapCat 注入件缺失（${launcher}）`);
  }
  // 关键：必须接住启动器的输出，否则注入失败时完全看不到原因
  const bootLog = path.join(ROOT, 'logs', 'fetcher-boot.log');
  const bootStream = fs.createWriteStream(bootLog, { flags: 'a' });
  bootStream.write(`\n===== ${new Date().toISOString()} qq=${qqPath} =====\n`);
  const child = spawn(launcher, [qqPath, hook], {
    cwd: NAPCAT_DIR, env, windowsHide: true, detached: false,
  });
  childPid = child.pid || 0;
  if (child.stdout) child.stdout.pipe(bootStream, { end: false });
  if (child.stderr) child.stderr.pipe(bootStream, { end: false });
  log(`[boot] NapCatWinBootMain pid=${childPid} qq=${qqPath} log=${bootLog}`);
  child.on('exit', (code) => {
    log(`[boot] NapCatWinBootMain exited code=${code}`);
    try { bootStream.end(); } catch { }
  });
  return child;
}

async function webuiToken() {
  try {
    const cfg = JSON.parse(fs.readFileSync(path.join(NAPCAT_DIR, 'config', 'webui.json'), 'utf8'));
    return String(cfg.token || '');
  } catch { return ''; }
}

async function pluginToken() {
  try {
    const cfg = JSON.parse(fs.readFileSync(
      path.join(NAPCAT_DIR, 'config', 'plugins', 'qq-miniapp-openauth', 'config.json'), 'utf8'));
    return String(cfg.token || '');
  } catch { return ''; }
}

async function waitWebui(deadline) {
  while (Date.now() < deadline) {
    try {
      const r = await httpJson(`http://127.0.0.1:${NAPCAT_PORT}/api/status`, { timeout: 2000 });
      if (r.status > 0) return true;
    } catch { }
    await sleep(1000);
  }
  return false;
}

async function authCredential() {
  const token = await webuiToken();
  const hash = crypto.createHash('sha256').update(`${token}.napcat`).digest('hex');
  const r = await httpJson(`http://127.0.0.1:${NAPCAT_PORT}/api/auth/login`, { method: 'POST', body: { hash } });
  const cred = r.json?.data?.Credential || '';
  if (!cred) throw new Error(`WebUI 鉴权失败：${r.json?.message || r.status}`);
  return cred;
}

async function fetchQr(cred) {
  const r = await httpJson(`http://127.0.0.1:${NAPCAT_PORT}/api/QQLogin/GetQQLoginQrcode`, {
    method: 'POST', headers: { Authorization: `Bearer ${cred}` }, body: {}, timeout: 40000,
  });
  const url = r.json?.data?.qrcode || '';
  if (!url) throw new Error(`取二维码失败：${r.json?.message || r.status}`);
  return url;
}

async function qqStatus(cred) {
  const r = await httpJson(`http://127.0.0.1:${NAPCAT_PORT}/api/QQLogin/CheckLoginStatus`, {
    method: 'POST', headers: { Authorization: `Bearer ${cred}` }, body: {}, timeout: 10000,
  });
  return r.json?.data || {};
}

async function fetchCodeViaPlugin() {
  const token = await pluginToken();
  const headers = token ? { Authorization: `Bearer ${token}` } : {};
  const r = await httpJson(
    `http://127.0.0.1:${NAPCAT_PORT}/plugin/qq-miniapp-openauth/api/miniapp`,
    { method: 'POST', headers, body: { appId: APPID }, timeout: 30000 });
  const j = r.json || {};
  state.attempts = j.attempts || [];
  if (j.ok && j.code) {
    state.uin = String(j.uin || state.uin || '');
    state.nickname = String(j.nickname || state.nickname || '');
    return String(j.code);
  }
  throw new Error(j.error || `插件返回 code 失败（${r.status}）`);
}

// ---------------------------------------------------------------- 清理
function killTree() {
  if (!childPid) return;
  try {
    spawnSync('taskkill', ['/F', '/T', '/PID', String(childPid)], { windowsHide: true });
    log(`[cleanup] taskkill /T ${childPid}`);
  } catch { }
  childPid = 0;
}

function finish(phase, patch = {}) {
  if (finished) return;
  finished = true;
  setState({ phase, ...patch });
  // 取码成功也立刻收掉 QQ：本进程的唯一职责已经完成
  if (phase === 'code') {
    setTimeout(() => { setState({ phase: 'done' }); killTree(); }, 1200);
  }
  else {
    killTree();
  }
}

// ---------------------------------------------------------------- 主流程
function closeExistingQq() {
  // QQ 是单实例应用：已有 QQ 在跑时，注入实例会立刻退出（启动器打印 "Process exited."）
  try {
    const r = spawnSync('tasklist', ['/FI', 'IMAGENAME eq QQ.exe', '/NH'], { encoding: 'utf8', windowsHide: true });
    const running = /QQ\.exe/i.test(r.stdout || '');
    if (!running) return 0;
    log('[pre] 检测到已有 QQ 在运行，先关闭（可用 --no-kill-qq 关闭该行为）');
    spawnSync('taskkill', ['/F', '/IM', 'QQ.exe'], { windowsHide: true });
    spawnSync('taskkill', ['/F', '/IM', 'QQEX.exe'], { windowsHide: true });
    return 1;
  }
  catch (e) { log('[pre] 关闭旧 QQ 失败:', e.message); return 0; }
}

async function run() {
  const deadline = Date.now() + TIMEOUT_SEC * 1000;
  const qqPath = resolveQqPath();
  if (!qqPath) {
    finish('error', { error: '未找到 QQ.exe（可用 --qq 指定，或写 qqpath.txt）' });
    return;
  }
  log(`[run] qq=${qqPath} appId=${APPID} timeout=${TIMEOUT_SEC}s`);
  if (!process.argv.includes('--no-kill-qq')) {
    closeExistingQq();
    await sleep(1200);
  }
  launchNapCat(qqPath);

  if (!await waitWebui(deadline)) {
    finish('error', { error: `NapCat WebUI 未就绪（${NAPCAT_PORT}）。若日志停在 “Process resumed”，说明注入未完成。` });
    return;
  }
  log('[run] WebUI ready');

  const cred = await authCredential().catch(e => { finish('error', { error: e.message }); return ''; });
  if (!cred) return;

  // 已经登录就直接取码，否则出二维码
  let st = await qqStatus(cred).catch(() => ({}));
  if (!st.isLogin) {
    try {
      const qr = await fetchQr(cred);
      const png = await renderQr(qr);
      setState({ phase: 'qr', qr, qrPng: png });
    }
    catch (e) { finish('error', { error: e.message }); return; }
  }
  else {
    setState({ phase: 'logged', uin: String(st.uin || '') });
  }

  // 等登录
  while (Date.now() < deadline && !finished) {
    st = await qqStatus(cred).catch(() => ({}));
    if (st.isLogin) {
      setState({ phase: 'logged', uin: String(st.uin || state.uin || '') });
      break;
    }
    if (st.loginError) log(`[login] phase=${st.loginPhase} err=${st.loginError}`);
    if (state.phase === 'qr') setState({ phase: 'scanning' });
    await sleep(1500);
  }
  if (finished) return;
  if (!st.isLogin) {
    finish('error', { error: '扫码登录超时' });
    return;
  }

  // 取码
  setState({ phase: 'logged' });
  try {
    const code = await fetchCodeViaPlugin();
    finish('code', { code });
  }
  catch (e) {
    finish('error', { error: e.message });
  }
}

// ---------------------------------------------------------------- 状态服务
const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://127.0.0.1:${PORT}`);
  const json = (obj, status = 200) => {
    const body = JSON.stringify(obj);
    res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(body) });
    res.end(body);
  };
  if (url.pathname === '/state') {
    return json({ ok: true, ...state, elapsedSec: Math.round((Date.now() - state.startedAt) / 1000) });
  }
  if (url.pathname === '/cancel') {
    setState({ phase: 'cancelled' });
    finish('cancelled');
    return json({ ok: true });
  }
  if (url.pathname === '/health') return json({ ok: true, pid: process.pid });
  return json({ ok: false, error: 'not found' }, 404);
});

server.listen(PORT, '127.0.0.1', () => {
  log(`[http] state server on 127.0.0.1:${PORT}`);
  run().catch((e) => finish('error', { error: e.message || String(e) }));
});

// 兜底：异常/信号都要收进程，避免留下 QQ
process.on('exit', () => killTree());
process.on('SIGINT', () => { setState({ phase: 'cancelled' }); killTree(); process.exit(0); });
process.on('SIGTERM', () => { killTree(); process.exit(0); });

// 超时兜底
setTimeout(() => {
  if (!finished) finish('error', { error: `总超时（${TIMEOUT_SEC}s）` });
}, TIMEOUT_SEC * 1000 + 15000);
