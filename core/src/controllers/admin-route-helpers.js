function toBooleanFlag(value) {
  return value === true || value === 'true' || value === 1 || value === '1';
}

function createAdminRouteHelpers({ store, userStore, logger, getProvider }) {
  function requireDangerConfirmation(req, res, requiredConfirmation) {
    const confirmed = req && req.body ? toBooleanFlag(req.body.confirmed) : false;
    if (!confirmed) {
      return (
        res.status(400).json({
          ok: false,
          error: '危险操作未确认',
          requiredConfirmation,
        }),
        false
      );
    }
    return true;
  }

  function getAdminUserMutationError(currentUser, targetUsername) {
    const normalizedTarget = String(targetUsername || '').trim();
    if (!currentUser || !normalizedTarget) return null;
    if (currentUser.role === 'super_admin') return null;
    if (String(currentUser.username || '').trim() === normalizedTarget) return null;
    try {
      const users = userStore.getAllUsers();
      const targetUser = Array.isArray(users)
        ? users.find(
            user => String(user.username || '').trim() === normalizedTarget,
          )
        : null;
      if (targetUser && targetUser.role === 'admin')
        return '普通管理员不能修改或删除其他管理员账号';
    } catch {}
    return null;
  }


  function isExpectedProviderError(err) {
    const message = String((err && err.message) || '');
    return message === '账号未运行' || message === 'API Timeout';
  }

  function sendProviderError(res, err) {
    if (res.headersSent || res.writableEnded || res.destroyed || res.locals?.requestTimedOut)
      return;

    if (isExpectedProviderError(err)) {
      return res.json({
        ok: false,
        error: err.message,
      });
    }
    return res.status(500).json({
      ok: false,
      error: err.message,
    });
  }

  function requireAdminRole(req, res, next) {
    if (
      !req.currentUser
      || (req.currentUser.role !== 'admin'
        && req.currentUser.role !== 'super_admin')
    ) {
      return res.status(403).json({
        ok: false,
        error: '需要管理员权限',
      });
    }
    next();
  }

  function requireSuperAdminRole(req, res, next) {
    if (!req.currentUser || req.currentUser.role !== 'super_admin') {
      return res.status(403).json({
        ok: false,
        error: '需要超级管理员权限',
      });
    }
    next();
  }

  return {
    getAdminUserMutationError,
    requireAdminRole,
    requireDangerConfirmation,
    requireSuperAdminRole,
    sendProviderError,
  };
}

module.exports = {
  createAdminRouteHelpers,
};
