/**
 * 本机取码对接路由（仅供控制面板调用）
 * ---------------------------------------------------------------------------
 * 取码器（fetcher/code-fetcher.mjs）拿到 code 后，面板把 code 交给这里：
 *   POST /api/local/code-account
 *   { token, mode: 'new' | 'refresh', accountId?, code, platform?, uin?, name? }
 *
 * 安全边界：只接受本机回环来源 + 共享令牌（data/local-api-token.txt，首次启动生成）。
 * 这条路由不做用户态鉴权，因为它不面向浏览器，只面向本机面板。
 */

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const TOKEN_FILE = process.env.FARM_DATA_DIR
  ? path.join(process.env.FARM_DATA_DIR, 'local-api-token.txt')
  : path.join(__dirname, '..', '..', 'data', 'local-api-token.txt');

function ensureToken() {
  try {
    if (fs.existsSync(TOKEN_FILE)) {
      const token = fs.readFileSync(TOKEN_FILE, 'utf8').trim();
      if (token.length >= 16) return token;
    }
    const token = crypto.randomBytes(24).toString('hex');
    fs.mkdirSync(path.dirname(TOKEN_FILE), { recursive: true });
    fs.writeFileSync(TOKEN_FILE, token, 'utf8');
    return token;
  }
  catch {
    return '';
  }
}

function isLoopback(req) {
  const ip = String((req.socket && req.socket.remoteAddress) || '');
  return ip === '127.0.0.1' || ip === '::1' || ip === '::ffff:127.0.0.1';
}

function registerLocalCodeRoutes({ app, store, provider, logger }) {
  const token = ensureToken();

  app.get('/api/local/ping', (req, res) => {
    if (!isLoopback(req)) return res.status(403).json({ ok: false, error: 'local only' });
    res.json({ ok: true, data: { tokenReady: Boolean(token) } });
  });

  app.post('/api/local/code-account', (req, res) => {
    if (!isLoopback(req)) return res.status(403).json({ ok: false, error: 'local only' });
    const body = req.body || {};
    if (!token || String(body.token || '') !== token) {
      return res.status(401).json({ ok: false, error: 'invalid local token' });
    }
    const code = String(body.code || '').trim();
    if (!code) return res.status(400).json({ ok: false, error: '缺少 code' });

    const mode = body.mode === 'refresh' ? 'refresh' : 'new';
    const platform = body.platform === 'wx' ? 'wx' : 'qq';
    const uin = String(body.uin || '').trim();
    const accountId = body.accountId ? String(body.accountId) : '';

    try {
      const all = store.getAccounts().accounts || [];
      let target = mode === 'refresh' && accountId
        ? all.find(a => String(a.id) === accountId)
        : null;

      // refresh 但没给 accountId：按 uin 兜底匹配（失效账号重登常见）
      if (mode === 'refresh' && !target && uin) {
        target = all.find(a => String(a.uin || a.qq || '') === uin);
      }

      const wasRunning = target && provider.isAccountRunning
        ? Boolean(provider.isAccountRunning(target.id))
        : false;

      const payload = {
        ...(target ? { id: target.id } : {}),
        code,
        platform,
        loginType: 'openauth',
        ...(uin ? { uin, qq: uin } : {}),
        ...(body.name ? { name: String(body.name) } : {}),
      };
      store.addOrUpdateAccount(payload);
      const accounts = store.getAccounts().accounts || [];
      const saved = target
        ? accounts.find(a => String(a.id) === target.id)
        : accounts.at(-1);
      if (!saved) throw new Error('账号保存失败');

      // 与抓包登录一致：稍后启动/重启账号
      setTimeout(() => {
        try {
          if (target) provider.restartAccount(saved.id);
          else provider.startAccount(saved.id);
        }
        catch (error) {
          logger.warn?.('取码器账号已保存，但启动失败', { accountId: saved.id, error: error.message });
        }
      }, 1200);

      logger.info?.('取码器写入账号', { mode, accountId: saved.id, uin, platform });
      res.json({
        ok: true,
        data: {
          mode,
          accountId: saved.id,
          created: !target,
          name: saved.name || '',
          uin: saved.uin || uin,
          started: true,
        },
      });
    }
    catch (error) {
      logger.error?.('取码器写入账号失败', { error: error.message });
      res.status(500).json({ ok: false, error: error.message });
    }
  });
}

module.exports = { registerLocalCodeRoutes, ensureToken };
