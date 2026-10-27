const crypto = require('node:crypto');

function createAdminSessionManager({ logger, getIo }) {
  const adminTokens = new Set();
  const adminSessions = new Map();

  // 上游修复(H1)：会话原本永不过期（cleanupInvalidAdminSessions 是空函数），
  // 泄漏的 token 只要进程不重启就一直有效。这里加滑动空闲期 + 绝对上限。
  const SESSION_IDLE_MS = 7 * 24 * 60 * 60 * 1000;
  const SESSION_MAX_MS = 30 * 24 * 60 * 60 * 1000;

  function generateAdminToken() {
    return crypto.randomBytes(24).toString('hex');
  }

  function sendUnauthorized(res) {
    return res.status(401).json({
      ok: false,
      error: 'Unauthorized',
    });
  }

  function isSessionExpired(session) {
    if (!session) return true;
    const now = Date.now();
    const created = Number(session._createdAt) || 0;
    const seen = Number(session._lastSeenAt) || created;
    if (created && now - created > SESSION_MAX_MS) return true;
    if (seen && now - seen > SESSION_IDLE_MS) return true;
    return false;
  }

  function createAdminSession(user) {
    const token = generateAdminToken();
    const now = Date.now();
    adminTokens.add(token);
    adminSessions.set(token, { ...user, _createdAt: now, _lastSeenAt: now });
    return token;
  }

  function invalidateAdminSession(token) {
    adminTokens.delete(token);
    adminSessions.delete(token);
  }

  function disconnectAdminTokenSockets(token) {
    const io = typeof getIo === 'function' ? getIo() : null;
    if (!io) return;
    for (const socket of io.sockets.sockets.values()) {
      String(socket.data.adminToken || '') === String(token)
        && socket.disconnect(true);
    }
  }

  function invalidateAdminSessionAndDisconnect(token) {
    invalidateAdminSession(token);
    disconnectAdminTokenSockets(token);
  }

  function invalidateAdminSessions(predicate) {
    for (const [token, session] of adminSessions.entries()) {
      if (predicate(session, token))
        invalidateAdminSessionAndDisconnect(token);
    }
  }

  function updateAdminSessions(predicate, updateSession) {
    for (const [token, session] of adminSessions.entries()) {
      if (predicate(session, token)) {
        updateSession(session, token);
        adminSessions.set(token, session);
      }
    }
  }

  function requireAdminToken(req, res, next) {
    const token = req.headers['x-admin-token'];
    if (!token || !adminTokens.has(token))
      return sendUnauthorized(res);
    const session = adminSessions.get(token);
    if (!session || isSessionExpired(session)) {
      invalidateAdminSessionAndDisconnect(token);
      return sendUnauthorized(res);
    }
    // 滑动续期：有活动的会话不会因为空闲超时被踢
    session._lastSeenAt = Date.now();
    adminSessions.set(token, session);
    req.adminToken = token;
    req.currentUser = session;
    next();
  }

  function cleanupInvalidAdminSessions() {
    // 原来是空函数，5 分钟一次纯属摆设；现在真正清理过期会话
    for (const [token, session] of adminSessions.entries()) {
      if (isSessionExpired(session)) invalidateAdminSessionAndDisconnect(token);
    }
  }

  function hasToken(token) {
    return adminTokens.has(token);
  }

  function getSession(token) {
    return adminSessions.get(token) || null;
  }

  return {
    cleanupInvalidAdminSessions,
    createAdminSession,
    getSession,
    hasToken,
    invalidateAdminSessionAndDisconnect,
    invalidateAdminSessions,
    requireAdminToken,
    updateAdminSessions,
  };
}

module.exports = {
  createAdminSessionManager,
};
