const process = require('node:process');

const {
    startAdminServer,
    emitRealtimeStatus,
    emitRealtimeLog,
    emitRealtimeAccountLog,
} = require('./src/controllers/admin');
const { createRuntimeEngine } = require('./src/runtime/runtime-engine');
const { createModuleLogger } = require('./src/services/logger');
const { verifyAndRun } = require('./src/services/license');

const mainLogger = createModuleLogger('main');
const isWorkerProcess = process.env.FARM_WORKER === '1';

// 上游修复(H10)：仓库原本没有任何进程级异常兜底。
// Express 4 不捕获 async handler 的 rejection，Node 15+ 默认把 unhandledRejection
// 视为致命错误 → 整个 Bot 进程退出，所有账号同时掉线。这里记录并保活。
let uncaughtCount = 0;

process.on('unhandledRejection', (reason) => {
    try {
        mainLogger.error('未处理的 Promise 拒绝（已拦截，进程继续运行）', {
            error: reason && reason.message ? reason.message : String(reason),
            stack: reason && reason.stack ? String(reason.stack).split('\n').slice(0, 5).join(' | ') : '',
        });
    }
    catch { }
});

process.on('uncaughtException', (err) => {
    uncaughtCount += 1;
    try {
        mainLogger.error('未捕获异常（已拦截）', {
            error: err && err.message ? err.message : String(err),
            stack: err && err.stack ? String(err.stack).split('\n').slice(0, 8).join(' | ') : '',
            count: uncaughtCount,
        });
    }
    catch { }
    // 连续出现说明状态已不可信，重启比带着坏状态继续跑更安全
    if (uncaughtCount > 5) {
        try { mainLogger.error('未捕获异常过多，退出进程等待重启'); } catch { }
        process.exit(1);
    }
});

async function bootstrap() {
    if (isWorkerProcess) {
        require('./src/core/worker');
        return;
    }

    // 抓包服务子命令：qq-farm-bot --capture（或 FARM_CAPTURE_SERVER=1）
    if (process.argv.includes('--capture') || process.env.FARM_CAPTURE_SERVER === '1') {
        const { startCaptureServer } = require('./src/capture/index');
        const { resolveAdvertiseAddresses } = require('./src/capture/ip-utils');
        const { config, stop, log } = await startCaptureServer();
        const advertise = resolveAdvertiseAddresses(config);
        log.info(`抓包服务已启动，API: http://${config.apiHost}:${config.apiPort}`);
        log.info(`对外代理地址: ${advertise.addresses.length
            ? advertise.addresses.map(item => `${item.address} (${item.kind})`).join(', ')
            : '未检测到可用地址'}`);
        const shutdown = (signal) => {
            log.info(`收到 ${signal}，正在关闭抓包服务...`);
            void stop().then(() => process.exit(0));
        };
        process.on('SIGINT', () => shutdown('SIGINT'));
        process.on('SIGTERM', () => shutdown('SIGTERM'));
        return;
    }

    const licenseValid = await verifyAndRun();
    if (!licenseValid) {
        console.error('');
        console.error('[Error] License verification failed, exiting.');
        console.error('');
        process.exit(1);
        return;
    }

    const runtimeEngine = createRuntimeEngine({
        processRef: process,
        mainEntryPath: __filename,
        startAdminServer,
        onStatusSync: (accountId, status) => {
            emitRealtimeStatus(accountId, status);
        },
        onLog: (entry, accountId) => {
            if (accountId && entry) {
                entry.accountId = accountId;
            }
            emitRealtimeLog(entry);
        },
        onAccountLog: (entry) => {
            emitRealtimeAccountLog(entry);
        },
    });

    runtimeEngine.start({
        startAdminServer: true,
        autoStartAccounts: false,
    }).catch((err) => {
        mainLogger.error('runtime bootstrap failed', {
            error: err && err.message ? err.message : String(err),
        });
    });
}

bootstrap().catch((err) => {
    console.error('Bootstrap failed:', err);
    process.exit(1);
});
