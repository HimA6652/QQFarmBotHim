function registerAdminSuperAdminRoutes({
  app,
  store,
  userStore,
  logger,
  requireAdminToken,
  requireSuperAdminRole,
  requireDangerConfirmation,
}) {
  app.post(
    "/api/super-admin/clear-data",
    requireAdminToken,
    requireSuperAdminRole,
    (req, res) => {
      try {
        if (!requireDangerConfirmation(req, res, "CLEAR_ALL_DATA")) return;
        const result = userStore.clearAllData();
        logger.warn("超级管理员清空全部数据", {
          admin: req.currentUser?.username || "",
          confirmation: "CLEAR_ALL_DATA",
          executed: !!result.ok,
        });
        result.requiredConfirmation = "CLEAR_ALL_DATA";
        result.executed = !!result.ok;
        res.json(result);
      } catch (error) {
        res.status(500).json({ ok: false, error: error.message });
      }
    },
  );

}

module.exports = { registerAdminSuperAdminRoutes };
