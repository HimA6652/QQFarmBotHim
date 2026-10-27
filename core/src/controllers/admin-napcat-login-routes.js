const napcatLogin = require('../services/napcat-login');
const store = require('../models/store');

function owner(req) { return String(req.currentUser?.username || ''); }
function sendError(res, error) { res.status(400).json({ ok: false, error: error.message || 'NapCat 登录失败' }); }

function registerAdminNapcatLoginRoutes({ app, requireAdminToken, requireAdminRole, requireDangerConfirmation }) {
  app.get('/api/napcat-login/capability', (_req, res) => {
    const systemConfig = store.getSystemConfig() || {};
    res.json({ ok: true, data: { enabled: systemConfig.napcatLoginEnabled === true } });
  });

  app.get('/api/admin/napcat-login/status', requireAdminToken, requireAdminRole, (_req, res) => {
    try {
      const systemConfig = store.getSystemConfig() || {};
      res.json({ ok: true, data: { enabled: systemConfig.napcatLoginEnabled === true } });
    } catch (error) {
      res.status(500).json({ ok: false, error: error.message });
    }
  });

  app.post('/api/admin/napcat-login/status', requireAdminToken, requireAdminRole, (req, res) => {
    try {
      if (!requireDangerConfirmation(req, res, 'UPDATE_NAPCAT_LOGIN_STATUS')) return;
      const { enabled } = req.body || {};
      const current = store.getSystemConfig() || {};
      store.setSystemConfig({ ...current, napcatLoginEnabled: enabled === true });
      res.json({ ok: true, data: { enabled: enabled === true } });
    } catch (error) {
      res.status(500).json({ ok: false, error: error.message });
    }
  });

  // 上游修复(H8)：这组接口原来只过全局 token 门禁、不校验角色。
  // NapCat 是全局单例，任意普通用户点一次扫码就会注销管理员当前已登录的 QQ，
  // 导致所有依赖该 QQ 的账号掉线（跨租户 DoS）。统一要求管理员角色。
  app.post('/api/napcat-login/tasks', requireAdminToken, requireAdminRole, async (req, res) => {
    try { res.json({ ok: true, data: await napcatLogin.create(owner(req), { refresh: req.body?.refresh === true }) }); } catch (error) { sendError(res, error); }
  });
  app.post('/api/napcat-login/tasks/:id/status', requireAdminToken, requireAdminRole, async (req, res) => {
    try { res.json({ ok: true, data: await napcatLogin.status(req.params.id, owner(req)) }); } catch (error) { sendError(res, error); }
  });
  app.post('/api/napcat-login/tasks/:id/code', requireAdminToken, requireAdminRole, async (req, res) => {
    try { res.json({ ok: true, data: { ...await napcatLogin.code(req.params.id, owner(req)), appId: napcatLogin.APP_ID } }); } catch (error) { sendError(res, error); }
  });
  app.post('/api/napcat-login/tasks/:id/cancel', requireAdminToken, requireAdminRole, async (req, res) => {
    try { await napcatLogin.cancel(req.params.id, owner(req)); res.json({ ok: true }); } catch (error) { sendError(res, error); }
  });
}

module.exports = { registerAdminNapcatLoginRoutes };
