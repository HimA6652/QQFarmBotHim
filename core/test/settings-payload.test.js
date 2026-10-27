const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'qq-farm-settings-payload-'));
process.env.FARM_DATA_DIR = dataDir;

const store = require('../src/models/store');
const { registerAdminSettingsRoutes } = require('../src/controllers/admin-settings-routes');

test.after(() => {
  fs.rmSync(dataDir, { recursive: true, force: true });
});

function mountSettingsRoutes(accountId = '1') {
  const routes = new Map();
  const app = {
    get: (p, fn) => routes.set(`GET ${p}`, fn),
    post: (p, fn) => routes.set(`POST ${p}`, fn),
    put: (p, fn) => routes.set(`PUT ${p}`, fn),
  };
  registerAdminSettingsRoutes({
    app,
    provider: {},
    store,
    logger: { info() {}, warn() {}, error() {} },
    getAccountIdFromRequest: () => accountId,
    canAccessAccount: () => true,
    requireDangerConfirmation: () => {},
  });
  return routes;
}

async function readSettingsPayload(accountId = '1') {
  const handler = mountSettingsRoutes(accountId).get('GET /api/settings');
  assert.ok(handler, 'GET /api/settings 应已注册');
  let body = null;
  const res = {
    statusCode: 200,
    status(code) { this.statusCode = code; return this; },
    json(payload) { body = payload; return this; },
  };
  await handler({ currentUser: { username: 'tester' }, headers: {}, query: {}, body: {} }, res);
  assert.equal(body && body.ok, true, '接口应返回 ok');
  return body.data;
}

// 本机定制补丁（2026-10-18）：这三个 + auto2x2SyncBuy 之前只在写路径支持，
// 读回接口的手写返回体漏了，导致「保存成功但一刷新就变回关闭」。
test('settings payload carries the four fields the UI reads back', async () => {
  store.applyConfigSnapshot({
    auto2x2SyncBuy: true,
    plantSeedPriority: [20129, 21037],
    bagSeedExcludedIds: [20002],
    stealDelaySeconds: 7,
  }, { accountId: '1' });

  const data = await readSettingsPayload();

  assert.equal(data.auto2x2SyncBuy, true, 'auto2x2SyncBuy 必须原样读回');
  assert.deepEqual(data.plantSeedPriority, [20129, 21037], 'plantSeedPriority 必须原样读回');
  assert.deepEqual(data.bagSeedExcludedIds, [20002], 'bagSeedExcludedIds 必须原样读回');
  assert.equal(data.stealDelaySeconds, 7, 'stealDelaySeconds 必须原样读回');
});

test('settings payload reports disabled state as false, not undefined', async () => {
  store.applyConfigSnapshot({
    auto2x2SyncBuy: false,
    stealDelaySeconds: 0,
  }, { accountId: '1' });

  const data = await readSettingsPayload();

  assert.equal(data.auto2x2SyncBuy, false);
  assert.equal(data.stealDelaySeconds, 0);
  assert.ok(Array.isArray(data.plantSeedPriority));
  assert.ok(Array.isArray(data.bagSeedExcludedIds));
});

test('settings for an account without stored config still expose the fields', async () => {
  const data = await readSettingsPayload('no-config-account');
  assert.equal(typeof data.auto2x2SyncBuy, 'boolean');
  assert.equal(typeof data.stealDelaySeconds, 'number');
});
