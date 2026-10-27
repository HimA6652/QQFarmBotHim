/**
 * 控制面板前端
 * - 3 秒轮询一次状态（页面隐藏时暂停）
 * - 所有文本一律用 textContent 写入，不用 innerHTML 拼外部数据
 * - 动作按钮走白名单接口 /api/action
 */
'use strict';

const $ = id => document.getElementById(id);

// 主程序日志的模块分类，与主界面「账号概览」保持一致。
const LOG_MODULES = [
  { label: '全部', value: '' },
  { label: '农场', value: 'farm' },
  { label: '好友', value: 'friend' },
  { label: '仓库', value: 'warehouse' },
  { label: '商城', value: 'shop' },
  { label: '任务', value: 'task' },
  { label: '活动', value: 'activity' },
  { label: '宠物', value: 'pet' },
  { label: '系统', value: 'system' },
  { label: '其他', value: 'other' },
];

// 面板日志自己的分类：面板行是「[时间] [标记] 正文」，标记来自 server.js 的 appendLog。
const PANEL_MODULES = [
  { label: '全部', value: '' },
  { label: '动作', value: 'action' },
  { label: '防火墙', value: 'firewall' },
  { label: '错误', value: 'error' },
  { label: '系统', value: 'system' },
  { label: '其他', value: 'other' },
];

// 各日志源使用哪套分类
const MODULES_BY_SOURCE = {
  panel: PANEL_MODULES,
  core: LOG_MODULES,
};

// 类别标记配色（按日志自带的 tag）。
const LOG_TAG_TONES = {
  农场: 'green',
  好友: 'sky',
  仓库: 'teal',
  商城: 'orange',
  任务: 'indigo',
  活动: 'violet',
  宠物: 'pink',
  系统: 'slate',
  警告: 'amber',
  错误: 'red',
  // 面板日志的标记
  动作: 'indigo',
  启动: 'green',
  防火墙: 'slate',
  拒绝: 'amber',
  退出: 'slate',
  致命: 'red',
};

let currentSource = 'panel';
let currentModule = '';
let busy = false;
let timer = null;
let lastToken = '';
let lastLogPayload = null;
let lastLogSource = '';

function fmtDuration(sec) {
  const value = Number(sec) || 0;
  if (value <= 0) return '—';
  const d = Math.floor(value / 86400);
  const h = Math.floor((value % 86400) / 3600);
  const m = Math.floor((value % 3600) / 60);
  const s = value % 60;
  if (d > 0) return `${d}天${h}小时`;
  if (h > 0) return `${h}时${m}分`;
  if (m > 0) return `${m}分${s}秒`;
  return `${s}秒`;
}

function toast(text) {
  const el = $('toast');
  el.textContent = text;
  el.classList.add('show');
  clearTimeout(el._timer);
  el._timer = setTimeout(() => el.classList.remove('show'), 2600);
}

function setBadge(el, running, textOn, textOff) {
  el.textContent = running ? (textOn || '运行中') : (textOff || '已停止');
  el.className = `badge ${running ? 'on' : 'off'}`;
}

function renderAccounts(items, total) {
  const list = $('accountList');
  list.replaceChildren();
  $('accountBadge').textContent = `${total} 个`;
  if (!items.length) {
    const li = document.createElement('li');
    li.className = 'empty';
    li.textContent = '暂无账号，请在主界面添加';
    list.appendChild(li);
    return;
  }
  for (const item of items) {
    const li = document.createElement('li');
    const left = document.createElement('span');
    left.textContent = item.name || '未命名';
    const right = document.createElement('small');
    right.textContent = `${item.platform || 'qq'} · id ${item.id || '?'}`;
    li.append(left, right);
    list.appendChild(li);
  }
}

async function refreshStatus() {
  if (busy) return;
  try {
    const res = await fetch('/api/status', { cache: 'no-store' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    if (!data.ok) throw new Error(data.error || '状态读取失败');

    $('versionTag').textContent = data.panel.version || '控制面板';
    $('hostMeta').textContent = `${data.panel.host} · 面板 ${data.panel.bind}:${data.panel.port} · 已运行 ${fmtDuration(data.panel.uptimeSec)}`;

    const farm = data.services.farm;
    setBadge($('farmBadge'), farm.running);
    $('farmPid').textContent = farm.pid || '—';
    $('farmUptime').textContent = farm.running ? fmtDuration(farm.uptimeSec) : '—';
    const link = $('farmLink');
    link.href = `http://${location.hostname}:${farm.port}/`;
    link.textContent = `打开 ${farm.port} 界面`;

    const napcat = data.services.napcat;
    setBadge($('napcatBadge'), napcat.running);
    $('napcatPort').textContent = napcat.port;
    $('napcatPid').textContent = napcat.pid || '—';
    $('napcatUptime').textContent = napcat.running ? fmtDuration(napcat.uptimeSec) : '—';

    renderAccounts(data.accounts.items || [], data.accounts.count || 0);

    lastToken = (data.napcat && data.napcat.token) || '';
    $('copyToken').disabled = !lastToken;
    $('tokenHint').textContent = lastToken
      ? '令牌只在本机访问时下发；复制后可登录 NapCat WebUI。'
      : '令牌仅在本机访问时显示（当前是局域网访问）。';

    const dot = $('healthDot');
    const both = farm.running && napcat.running;
    dot.className = `dot ${both ? 'ok' : (farm.running || napcat.running ? 'warn' : '')}`;

    if (data.panel.addresses && data.panel.addresses.length) {
      $('footInfo').textContent = `局域网访问：${data.panel.addresses.map(a => `http://${a}:${data.panel.port}`).join('　')}`;
    }
  } catch (error) {
    $('hostMeta').textContent = `连接面板失败：${error.message}`;
    $('healthDot').className = 'dot';
  }
}

function formatLogTime(value) {
  const text = String(value || '');
  if (!text) return '';
  const date = new Date(text);
  if (Number.isNaN(date.getTime())) return '';
  const pad = n => String(n).padStart(2, '0');
  return `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
}

function levelTagName(level) {
  const name = String(level || '').toLowerCase();
  if (name === 'error') return '错误';
  if (name === 'warn' || name === 'warning') return '警告';
  return '';
}

/** 把主程序的一行 JSON 日志解析成「分类 + 标记 + 时间 + 正文」，非 JSON 行原样保留。 */
function parseCoreLine(line) {
  const text = String(line || '').trim();
  if (!text) return null;
  if (text[0] !== '{') return { category: 'other', tag: '', level: '', time: '', msg: text };
  try {
    const item = JSON.parse(text);
    const moduleName = String(item.module || '').toLowerCase();
    const tag = String(item.tag || '') || levelTagName(item.level);
    const known = LOG_MODULES.some(entry => entry.value === moduleName);
    const category = known ? moduleName : (tag === '系统' ? 'system' : 'other');
    return {
      category,
      tag,
      level: String(item.level || '').toLowerCase(),
      time: formatLogTime(item.timestamp),
      msg: String(item.message || text),
    };
  } catch {
    return { category: 'other', tag: '', level: '', time: '', msg: text };
  }
}

/**
 * 把面板的一行日志「[2026/10/24 15:50:57] [动作] xxx」解析成结构化条目。
 * 标记由 server.js 的 appendLog 写入：启动/动作/防火墙/致命/拒绝/退出/错误。
 */
function parsePanelLine(line) {
  const text = String(line || '').trim();
  if (!text) return null;
  const matched = text.match(/^\[(\d{4}\/\d{2}\/\d{2}[ T]\d{2}:\d{2}:\d{2})\]\s*\[([^\]]+)\]\s*([\s\S]*)$/);
  if (!matched) return { category: 'other', tag: '', level: '', time: '', msg: text };
  const tag = matched[2];
  let category = 'system';
  let level = '';
  if (tag === '动作') category = 'action';
  else if (tag === '防火墙') category = 'firewall';
  else if (tag === '致命') { category = 'error'; level = 'error'; }
  else if (tag === '错误') { category = 'error'; level = 'warn'; }
  else if (tag === '拒绝') level = 'warn';
  return {
    category,
    tag,
    level,
    // 面板行自带完整日期，展示只取时分秒，与主程序风格一致
    time: matched[1].slice(-8),
    msg: matched[3] || text,
  };
}

function buildLogFilters() {
  const bar = $('logFilters');
  bar.replaceChildren();
  const modules = MODULES_BY_SOURCE[currentSource] || [];
  for (const item of modules) {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = `chip${item.value === currentModule ? ' active' : ''}`;
    btn.dataset.module = item.value;
    btn.textContent = item.label;
    bar.appendChild(btn);
  }
}

function buildLogRow(entry) {
  const row = document.createElement('div');
  row.className = 'logrow';
  const time = document.createElement('span');
  time.className = 'logtime';
  time.textContent = entry.time || '--:--:--';
  row.appendChild(time);
  if (entry.tag) {
    const tag = document.createElement('span');
    tag.className = `logtag tone-${LOG_TAG_TONES[entry.tag] || 'slate'}`;
    tag.textContent = entry.tag;
    row.appendChild(tag);
  }
  const msg = document.createElement('span');
  msg.className = `logmsg${entry.level === 'error' ? ' is-error' : entry.level === 'warn' ? ' is-warn' : ''}`;
  msg.textContent = entry.msg;
  row.appendChild(msg);
  return row;
}

function renderLogs() {
  const payload = lastLogPayload || {};
  const lines = Array.isArray(payload.lines) ? payload.lines : [];
  // 面板与主程序都有分类，走同一套行式渲染；NapCat 是外部纯文本，保持原样
  const structured = currentSource === 'core' || currentSource === 'panel';
  const box = $('logBox');
  const list = $('logList');
  $('logFilters').hidden = !structured;

  if (!structured) {
    box.hidden = false;
    list.hidden = true;
    const atBottom = box.scrollTop + box.clientHeight >= box.scrollHeight - 30;
    box.textContent = lines.length ? lines.join('\n') : '（暂无日志）';
    if (atBottom) box.scrollTop = box.scrollHeight;
    return;
  }

  box.hidden = true;
  list.hidden = false;
  const atBottom = list.scrollTop + list.clientHeight >= list.scrollHeight - 30;
  const parse = currentSource === 'core' ? parseCoreLine : parsePanelLine;
  const entries = lines.map(parse).filter(Boolean);
  const visible = currentModule ? entries.filter(entry => entry.category === currentModule) : entries;
  list.replaceChildren();
  if (!visible.length) {
    const empty = document.createElement('div');
    empty.className = 'logempty';
    empty.textContent = entries.length ? '没有符合条件的日志' : '（暂无日志）';
    list.appendChild(empty);
  } else {
    const fragment = document.createDocumentFragment();
    for (const entry of visible) fragment.appendChild(buildLogRow(entry));
    list.appendChild(fragment);
  }
  if (atBottom) list.scrollTop = list.scrollHeight;
}

async function refreshLogs() {
  try {
    const res = await fetch(`/api/logs?source=${encodeURIComponent(currentSource)}&lines=300`, { cache: 'no-store' });
    const data = await res.json();
    lastLogPayload = data;
    $('logFile').textContent = data.file || '—';
    renderLogs();
  } catch {
    $('logFile').textContent = '—';
    const structured = currentSource === 'core' || currentSource === 'panel';
    if (structured) {
      lastLogPayload = { lines: ['日志读取失败'] };
      renderLogs();
    } else {
      $('logBox').textContent = '日志读取失败';
    }
  }
}

async function doAction(action, label) {
  if (busy) return;
  busy = true;
  document.querySelectorAll('button[data-act]').forEach(btn => (btn.disabled = true));
  try {
    const res = await fetch('/api/action', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action }),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok || data.ok === false) throw new Error(data.error || `HTTP ${res.status}`);
    // 主程序冷启动要加载 700+ 物品与 2000+ 配置，实测 10~60 秒才监听 3007
    const slow = action === 'farm-start' || action === 'farm-restart';
    toast(slow ? `${label}已下发，冷启动约需 10~60 秒…` : `${label}已下发，正在执行…`);
    setTimeout(refreshStatus, 2000);
    setTimeout(refreshStatus, 6000);
    setTimeout(refreshStatus, 15000);
    setTimeout(refreshStatus, 30000);
    setTimeout(refreshLogs, 2000);
  } catch (error) {
    toast(`操作失败：${error.message}`);
  } finally {
    busy = false;
    document.querySelectorAll('button[data-act]').forEach(btn => (btn.disabled = false));
  }
}

document.querySelectorAll('button[data-act]').forEach((btn) => {
  btn.addEventListener('click', () => {
    const action = btn.dataset.act;
    const label = btn.textContent.trim();
    const risky = action.endsWith('-stop') || action.endsWith('-restart');
    if (risky && !confirm(`确定要${label}吗？`)) return;
    doAction(action, label);
  });
});

$('logTabs').addEventListener('click', (event) => {
  const btn = event.target.closest('.tab');
  if (!btn) return;
  if (currentSource === btn.dataset.source) return;
  currentSource = btn.dataset.source;
  document.querySelectorAll('.tab').forEach(tab => tab.classList.toggle('active', tab === btn));
  // 两个源的分类值互不通用，切换时重置为「全部」并按源重建分类条
  currentModule = '';
  buildLogFilters();
  refreshLogs();
});

$('logFilters').addEventListener('click', (event) => {
  const btn = event.target.closest('.chip');
  if (!btn) return;
  currentModule = btn.dataset.module || '';
  document.querySelectorAll('#logFilters .chip').forEach(chip => chip.classList.toggle('active', chip === btn));
  renderLogs();
});

$('copyToken').addEventListener('click', async () => {
  if (!lastToken) return;
  try {
    await navigator.clipboard.writeText(lastToken);
    toast('令牌已复制，90 秒后请自行清空剪贴板');
  } catch {
    toast('复制失败，请手动选择文本');
  }
});

$('stopPanel').addEventListener('click', async () => {
  if (!confirm('关闭后需要重新运行「启动控制面板.bat」才能再次打开，确定？')) return;
  try {
    await fetch('/api/action', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'panel-stop' }),
    });
  } catch {}
  document.body.innerHTML = '<div style="padding:40px;font:14px system-ui">控制面板已停止，可以关闭此页面。</div>';
});

function startPolling() {
  clearInterval(timer);
  timer = setInterval(() => {
    if (document.hidden) return;
    refreshStatus();
    refreshLogs();
  }, 3000);
}

document.addEventListener('visibilitychange', () => {
  if (!document.hidden) {
    refreshStatus();
    refreshLogs();
  }
});

buildLogFilters();
refreshStatus();
refreshLogs();
startPolling();
