/**
 * QQ农场助手 · 控制面板（Web 服务端）
 * ------------------------------------------------------------------
 * 设计目标
 *  - 只做两件事：展示状态、触发启停。不含业务逻辑，业务仍在 core/ 里跑。
 *  - 零第三方依赖，直接用部署目录自带的 Node 运行时启动。
 *  - 动作交给 panel.ps1 -Action xxx 执行（PowerShell 已有成熟的进程/端口/UAC 处理）。
 *
 * 为什么不用 PowerShell 手写 HTTP：
 *  旧方案用 TcpListener 自己解析 HTTP，需要处理 Content-Length 上限、慢连接、
 *  并发 accept 阻塞等问题，容易写出 DoS 面。这里用 node:http，解析与超时都由
 *  运行时保证，代码量也更小。
 *
 * 安全边界（按用户要求：家庭内网使用，不设口令）
 *  - 监听 0.0.0.0:3100，仅本机 + 局域网可达；不映射公网。
 *  - 拒绝 Host 为域名（只接受 IP 字面量 / localhost），阻断 DNS rebinding。
 *  - NapCat WebUI 令牌只对回环来源返回，局域网页面看不到。
 *  - 动作白名单固定，不接受任意命令。
 */
'use strict';

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const net = require('node:net');
const { spawn } = require('node:child_process');

// ---------------------------------------------------------------------------
// 路径
// ---------------------------------------------------------------------------
const PANEL_DIR = __dirname;
const ROOT = path.resolve(PANEL_DIR, '..');
const WEB_DIR = path.join(PANEL_DIR, 'web');
const RUN_DIR = path.join(PANEL_DIR, 'run');
const LOG_DIR = path.join(PANEL_DIR, 'logs');
const SERVER_LOG = path.join(LOG_DIR, 'panel-server.log');
const PANEL_PS1 = path.join(PANEL_DIR, 'panel.ps1');

const PORT = Number(process.env.PANEL_PORT) || 3100;
const BIND = process.env.PANEL_BIND || '0.0.0.0';
const CORE_PORT = 3007;
const NAPCAT_WEBUI_PORT_DEFAULT = 6099;

for (const dir of [RUN_DIR, LOG_DIR]) {
  try {
    fs.mkdirSync(dir, { recursive: true });
  } catch {}
}

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------
function appendLog(line) {
  const stamp = new Date().toLocaleString('zh-CN', { hour12: false });
  try {
    const stat = fs.existsSync(SERVER_LOG) ? fs.statSync(SERVER_LOG) : null;
    if (stat && stat.size > 2 * 1024 * 1024) {
      try {
        fs.renameSync(SERVER_LOG, `${SERVER_LOG}.1`);
      } catch {}
    }
    fs.appendFileSync(SERVER_LOG, `[${stamp}] ${line}\r\n`, 'utf8');
  } catch {}
}

function readJson(file, fallback = null) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return fallback;
  }
}

/** 只取文件尾部 N 字节，避免把几十 MB 日志读进内存 */
function tailFile(file, lines = 200, maxBytes = 256 * 1024) {
  try {
    const stat = fs.statSync(file);
    if (!stat.isFile() || stat.size === 0) return [];
    const readBytes = Math.min(stat.size, maxBytes);
    const buf = Buffer.alloc(readBytes);
    const fd = fs.openSync(file, 'r');
    try {
      fs.readSync(fd, buf, 0, readBytes, stat.size - readBytes);
    } finally {
      fs.closeSync(fd);
    }
    const text = buf.toString('utf8');
    const all = text.split(/\r?\n/).filter(line => line.trim() !== '');
    return all.slice(-lines);
  } catch {
    return [];
  }
}

/** 端口探测：能连上就认为服务在监听 */
function probePort(port, host = '127.0.0.1', timeout = 350) {
  return new Promise((resolve) => {
    const socket = new net.Socket();
    let settled = false;
    const done = (result) => {
      if (settled) return;
      settled = true;
      socket.destroy();
      resolve(result);
    };
    socket.setTimeout(timeout);
    socket.once('connect', () => done(true));
    socket.once('timeout', () => done(false));
    socket.once('error', () => done(false));
    try {
      socket.connect(port, host);
    } catch {
      done(false);
    }
  });
}

function readPidRecord(name) {
  const file = path.join(RUN_DIR, `${name}.pid`);
  try {
    const raw = fs.readFileSync(file, 'utf8').trim();
    const pid = Number.parseInt(raw.split('|')[0], 10);
    if (!Number.isFinite(pid) || pid <= 0) return { pid: 0, startedAt: 0 };
    let startedAt = 0;
    try {
      startedAt = fs.statSync(file).mtimeMs;
    } catch {}
    return { pid, startedAt };
  } catch {
    return { pid: 0, startedAt: 0 };
  }
}

function isPidAlive(pid) {
  if (!pid) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function localAddresses() {
  const out = [];
  for (const list of Object.values(os.networkInterfaces())) {
    for (const item of list || []) {
      if (item.family !== 'IPv4' || item.internal) continue;
      if (item.address.startsWith('169.254.')) continue;
      out.push(item.address);
    }
  }
  return out;
}

function isLoopback(addr) {
  const value = String(addr || '');
  return value === '::1' || value === '127.0.0.1' || value.startsWith('127.') || value === '::ffff:127.0.0.1';
}

// ---------------------------------------------------------------------------
// 日志来源
// ---------------------------------------------------------------------------
function newestFile(dir, pattern) {
  try {
    const items = fs.readdirSync(dir)
      .filter(name => pattern.test(name))
      .map(name => {
        const full = path.join(dir, name);
        try {
          return { full, mtime: fs.statSync(full).mtimeMs };
        } catch {
          return null;
        }
      })
      .filter(Boolean)
      .sort((a, b) => b.mtime - a.mtime);
    return items.length ? items[0].full : '';
  } catch {
    return '';
  }
}

function logSources() {
  const coreLogDir = path.join(ROOT, 'data', 'logs');
  const napcatLogDir = path.join(ROOT, 'napcat', 'logs');
  return {
    panel: SERVER_LOG,
    core: newestFile(coreLogDir, /^combined.*\.log$/i),
    napcat: newestFile(napcatLogDir, /\.log$/i),
  };
}

/**
 * 主程序日志按小时切文件（combined-YYYY-MM-DD-HH.log），只读最新一个会跨小时丢上下文，
 * 用户看到的就"很少"。这里从最新的文件往前合并最近 24 个小时文件，凑够 lines 行为止。
 * 文件名含日期小时，字典序即时间序；每个文件仍只读尾部，避免大文件整读。
 */
function tailCoreLogs(lines = 200, maxFiles = 24, maxBytesPerFile = 256 * 1024) {
  const coreLogDir = path.join(ROOT, 'data', 'logs');
  let names = [];
  try {
    names = fs.readdirSync(coreLogDir)
      .filter(name => /^combined-\d{4}-\d{2}-\d{2}-\d{2}\.log$/i.test(name))
      .sort();
  } catch {}
  const picked = names.slice(-maxFiles).reverse(); // 新 → 旧
  const parts = [];
  const used = [];
  let total = 0;
  for (const name of picked) {
    if (total >= lines) break;
    const part = tailFile(path.join(coreLogDir, name), lines - total, maxBytesPerFile);
    if (!part.length) continue;
    used.push(name);
    parts.push(part);
    total += part.length;
  }
  // parts 是新→旧 push 的，反转后按时间正序拼接
  const merged = parts.length ? parts.reverse().flat().slice(-lines) : [];
  return { files: used, lines: merged };
}

// ---------------------------------------------------------------------------
// 状态
// ---------------------------------------------------------------------------
async function buildStatus(remoteAddr) {
  const [farmUp, napcatUp] = await Promise.all([
    probePort(CORE_PORT),
    probePort(readWebuiPort()),
  ]);

  const farmPid = readPidRecord('farm');
  const napcatPid = readPidRecord('napcat');

  const accountsFile = path.join(ROOT, 'data', 'accounts.json');
  const accountsData = readJson(accountsFile, { accounts: [] });
  const accounts = Array.isArray(accountsData.accounts) ? accountsData.accounts : [];

  const corePkg = readJson(path.join(ROOT, 'core', 'package.json'), {});
  const webui = readJson(path.join(ROOT, 'napcat', 'config', 'webui.json'), {});

  const now = Date.now();
  const addrList = localAddresses();

  return {
    ok: true,
    panel: {
      version: corePkg.version || '',
      host: os.hostname(),
      bind: BIND,
      port: PORT,
      addresses: addrList,
      localUrl: `http://127.0.0.1:${PORT}`,
      uptimeSec: Math.round(process.uptime()),
      serverTime: new Date().toISOString(),
    },
    services: {
      farm: {
        running: farmUp,
        port: CORE_PORT,
        pid: isPidAlive(farmPid.pid) ? farmPid.pid : 0,
        uptimeSec: farmPid.startedAt ? Math.max(0, Math.round((now - farmPid.startedAt) / 1000)) : 0,
        url: `http://${addrList[0] || '127.0.0.1'}:${CORE_PORT}`,
        localUrl: `http://127.0.0.1:${CORE_PORT}`,
      },
      napcat: {
        running: napcatUp,
        port: readWebuiPort(),
        pid: isPidAlive(napcatPid.pid) ? napcatPid.pid : 0,
        uptimeSec: napcatPid.startedAt ? Math.max(0, Math.round((now - napcatPid.startedAt) / 1000)) : 0,
        // NapCat WebUI 只监听回环，跨机访问必须走主程序界面
        localOnly: true,
      },
    },
    accounts: {
      count: accounts.length,
      items: accounts.slice(0, 20).map(item => ({
        id: String(item.id || ''),
        name: String(item.name || item.nick || '未命名'),
        platform: String(item.platform || ''),
        online: false,
      })),
    },
    // 令牌只对回环来源下发：局域网页面拿不到，避免同网段设备接管 QQ
    napcat: isLoopback(remoteAddr)
      ? { webuiPort: Number(webui.port) || NAPCAT_WEBUI_PORT_DEFAULT, token: String(webui.token || '') }
      : { webuiPort: Number(webui.port) || NAPCAT_WEBUI_PORT_DEFAULT, token: '' },
    logs: logSources(),
  };
}

function readWebuiPort() {
  const webui = readJson(path.join(ROOT, 'napcat', 'config', 'webui.json'), {});
  const port = Number(webui.port);
  return Number.isFinite(port) && port > 0 ? port : NAPCAT_WEBUI_PORT_DEFAULT;
}

// ---------------------------------------------------------------------------
// 动作（白名单）
// ---------------------------------------------------------------------------
const ACTIONS = {
  'farm-start': { label: '启动主程序', args: ['-Action', 'start'] },
  'farm-stop': { label: '停止主程序', args: ['-Action', 'stop'] },
  'farm-restart': { label: '重启主程序', args: ['-Action', 'restart'] },
  'napcat-start': { label: '启动 NapCat', args: ['-Action', 'startnapcat'] },
  'napcat-stop': { label: '停止 NapCat', args: ['-Action', 'stopnapcat'] },
};

let actionLockUntil = 0;

function runAction(action) {
  const spec = ACTIONS[action];
  if (!spec) return { ok: false, error: `不支持的动作：${action}` };
  const now = Date.now();
  if (now < actionLockUntil) {
    return { ok: false, error: '上一次操作还在执行，请稍候再试' };
  }
  actionLockUntil = now + 8000;

  appendLog(`[动作] ${spec.label}（${action}）`);

  try {
    const child = spawn(
      'powershell.exe',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', PANEL_PS1, ...spec.args, '-NoPause'],
      {
        cwd: ROOT,
        windowsHide: true,
        // 注意：不能用 detached:true。实测 Windows 下 detached 会让
        // powershell.exe -File 立即以 0 退出且不执行脚本（无输出、无副作用），
        // 表现为“面板点了没反应”。保持同进程组 + windowsHide 即可后台隐藏运行。
        detached: false,
        // 不接管 stdout/stderr：panel.ps1 是 GBK 输出，混进 UTF-8 日志会乱码。
        // 它自己会写 panel\logs\panel.gui.log，需要细节时看那里。
        stdio: 'ignore',
      },
    );
    child.on('error', (error) => {
      appendLog(`[动作] 无法启动 powershell.exe：${error.code || ''} ${error.message}`);
    });
    child.on('exit', (code) => {
      appendLog(`[动作] ${action} 结束 code=${code}`);
    });
    child.unref();
    return { ok: true, action, label: spec.label };
  } catch (error) {
    appendLog(`[动作] 启动失败：${error.message}`);
    return { ok: false, error: error.message };
  }
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------
const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.png': 'image/png',
  '.json': 'application/json; charset=utf-8',
};

function sendJson(res, status, payload) {
  const body = Buffer.from(JSON.stringify(payload), 'utf8');
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': body.length,
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
  });
  res.end(body);
}

function sendText(res, status, text, type = 'text/plain; charset=utf-8') {
  const body = Buffer.from(text, 'utf8');
  res.writeHead(status, {
    'Content-Type': type,
    'Content-Length': body.length,
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
  });
  res.end(body);
}

function serveStatic(res, urlPath) {
  const name = urlPath === '/' ? 'index.html' : urlPath.replace(/^\/+/, '');
  // 只允许 web 目录下的单层文件名，杜绝路径穿越
  if (!/^[A-Za-z0-9._-]+$/.test(name)) {
    sendText(res, 404, '404');
    return;
  }
  const full = path.join(WEB_DIR, name);
  if (!full.startsWith(WEB_DIR)) {
    sendText(res, 404, '404');
    return;
  }
  let content;
  try {
    content = fs.readFileSync(full);
  } catch {
    sendText(res, 404, '404');
    return;
  }
  res.writeHead(200, {
    'Content-Type': MIME[path.extname(name).toLowerCase()] || 'application/octet-stream',
    'Content-Length': content.length,
    'Cache-Control': 'no-store',
  });
  res.end(content);
}

/** 只接受 IP 字面量 / localhost 作为 Host，阻断 DNS rebinding */
function hostAllowed(hostHeader) {
  if (!hostHeader) return true;
  const host = String(hostHeader).split(':')[0].replace(/^\[|\]$/g, '');
  if (host === 'localhost') return true;
  return net.isIP(host) !== 0;
}

function readBody(req, limit = 64 * 1024) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > limit) {
        reject(new Error('请求体过大'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

const server = http.createServer(async (req, res) => {
  const remoteAddr = req.socket.remoteAddress || '';
  const url = new URL(req.url || '/', `http://${req.headers.host || '127.0.0.1'}`);

  if (!hostAllowed(req.headers.host)) {
    appendLog(`[拒绝] Host 校验未通过：${req.headers.host}（来源 ${remoteAddr}）`);
    sendText(res, 403, '403 forbidden');
    return;
  }

  try {
    if (url.pathname === '/api/status') {
      if (req.method !== 'GET') return sendJson(res, 405, { ok: false, error: 'method not allowed' });
      return sendJson(res, 200, await buildStatus(remoteAddr));
    }

    if (url.pathname === '/api/logs') {
      if (req.method !== 'GET') return sendJson(res, 405, { ok: false, error: 'method not allowed' });
      const source = String(url.searchParams.get('source') || 'panel');
      const lines = Math.min(1000, Math.max(20, Number(url.searchParams.get('lines')) || 200));
      if (source === 'core') {
        const merged = tailCoreLogs(lines);
        const file = merged.files.length
          ? (merged.files.length === 1
            ? merged.files[0]
            : `${merged.files[0]} 等 ${merged.files.length} 个小时文件（近 ${merged.files.length} 小时合并）`)
          : '';
        return sendJson(res, 200, { ok: true, source, file, lines: merged.lines });
      }
      const sources = logSources();
      const file = sources[source];
      if (!file) return sendJson(res, 200, { ok: true, source, file: '', lines: [] });
      return sendJson(res, 200, { ok: true, source, file, lines: tailFile(file, lines) });
    }

    if (url.pathname === '/api/action') {
      if (req.method !== 'POST') return sendJson(res, 405, { ok: false, error: 'method not allowed' });
      let payload = {};
      try {
        payload = JSON.parse((await readBody(req)) || '{}');
      } catch {
        return sendJson(res, 400, { ok: false, error: '请求体不是合法 JSON' });
      }
      const action = String(payload.action || '');
      if (action === 'panel-stop') {
        appendLog(`[动作] 关闭控制面板（来源 ${remoteAddr}）`);
        sendJson(res, 200, { ok: true, action, label: '关闭控制面板' });
        setTimeout(() => shutdown('panel-stop'), 200);
        return;
      }
      const result = runAction(action);
      return sendJson(res, result.ok ? 200 : 400, result);
    }

    if (url.pathname === '/favicon.ico') {
      return sendText(res, 204, '');
    }

    if (req.method !== 'GET' && req.method !== 'HEAD') {
      return sendText(res, 405, '405 method not allowed');
    }
    return serveStatic(res, url.pathname);
  } catch (error) {
    appendLog(`[错误] ${req.method} ${url.pathname} -> ${error.message}`);
    return sendJson(res, 500, { ok: false, error: '服务器内部错误' });
  }
});

server.setTimeout(30000);
server.keepAliveTimeout = 5000;
server.headersTimeout = 10000;

server.on('error', (error) => {
  appendLog(`[致命] 监听失败：${error.message}`);
  console.error(`\n  [控制面板] 端口 ${PORT} 监听失败：${error.message}`);
  console.error(`  可能已有面板在运行，或端口被占用。可用 PANEL_PORT=3101 换端口。\n`);
  process.exit(1);
});

// ---------------------------------------------------------------------------
// 防火墙：保证只有 3100 / 3007 对局域网开放
// 面板由 启动控制面板.bat 提权启动，这里顺带把规则校正一次；
// 没有管理员权限时只记一条日志，不影响面板使用。
// ---------------------------------------------------------------------------
function ensureFirewall() {
  const script = path.join(PANEL_DIR, 'ensure-firewall.ps1');
  if (!fs.existsSync(script)) return;
  try {
    const child = spawn(
      'powershell.exe',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script, '-DeployRoot', ROOT, '-LogPath', path.join(LOG_DIR, 'firewall.log')],
      { cwd: ROOT, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] },
    );
    let output = '';
    child.stdout.on('data', (chunk) => { output += chunk.toString(); });
    child.stderr.on('data', (chunk) => { output += chunk.toString(); });
    child.on('close', (code) => {
      const text = output.trim().split(/\r?\n/).slice(0, 6).join(' | ');
      appendLog(`[防火墙] 校验完成 code=${code} ${text}`);
    });
    child.on('error', (error) => appendLog(`[防火墙] 校验失败：${error.message}`));
  } catch (error) {
    appendLog(`[防火墙] 无法执行校验脚本：${error.message}`);
  }
}

function shutdown(reason) {
  appendLog(`[退出] ${reason}`);
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 1500);
}

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));

server.listen(PORT, BIND, () => {
  const addrs = localAddresses();
  appendLog(`[启动] http://${BIND}:${PORT}  pid=${process.pid}`);
  const line = '='.repeat(58);
  console.log(`\n${line}`);
  console.log('  QQ农场助手 · 控制面板已启动');
  console.log(line);
  console.log(`  监听     : ${BIND}:${PORT}`);
  console.log(`  本机访问 : http://127.0.0.1:${PORT}`);
  for (const addr of addrs) console.log(`  局域网   : http://${addr}:${PORT}`);
  console.log('');
  console.log('  只开放 3100（控制面板）与 3007（主程序界面）；');
  console.log('  NapCat 的 6099 / 3000 保持仅本机监听。');
  console.log(`  停止     : 本窗口 Ctrl+C，或页面上的「关闭面板」`);
  console.log(`${line}\n`);

  // 只在监听成功后校正防火墙，避免脚本报错时误导用户
  ensureFirewall();
});
