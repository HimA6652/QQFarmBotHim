/**
 * 日志 tag → module 兜底映射
 *
 * 背景：日志调用普遍不传 meta.module，导致前端「模块」过滤漏日志
 * （例如 19 条商城日志只有 6 条带 module）。这里在日志入口统一兜底归类，
 * 只有在调用方未显式传 module 时才生效，不覆盖显式值。
 *
 * 约定：module 取值必须与前端 Dashboard.modules 的 value 一致
 * （farm / friend / warehouse / task / activity / pet / shop / mall / network / scheduler / system）。
 */
const TAG_MODULE_FALLBACK = Object.freeze({
    农场: 'farm',
    种植: 'farm',
    成长种植: 'farm',
    施肥: 'farm',
    多季节施肥: 'farm',
    铲除: 'farm',
    仓库: 'warehouse',
    好友: 'friend',
    申请: 'friend',
    邀请: 'friend',
    任务: 'task',
    活跃: 'task',
    活动: 'activity',
    分享: 'activity',
    商城: 'mall',
    月卡: 'mall',
    会员: 'mall',
    商店: 'shop',
    购买: 'shop',
    宠物: 'pet',
    系统: 'system',
    错误: 'system',
    警告: 'system',
    推送: 'system',
    登录: 'system',
});

/**
 * 解析一条日志应归属的 module。
 * 优先级：显式 meta.module > tag 兜底映射 > 空（不归类，前端落「全部」）
 */
function resolveLogModule(tag, explicitModule) {
    const explicit = String(explicitModule || '').trim();
    if (explicit) return explicit;
    const name = String(tag || '').trim();
    return TAG_MODULE_FALLBACK[name] || '';
}

module.exports = { TAG_MODULE_FALLBACK, resolveLogModule };
