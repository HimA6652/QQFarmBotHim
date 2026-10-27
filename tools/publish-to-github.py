#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把开发仓库同步到 GitHub 发布仓库（不含开发历史，只推白名单文件）。

用法：
    python tools/publish-to-github.py            # 演练：同步 + 扫描 + 打印变更，不提交
    python tools/publish-to-github.py --yes      # 实际提交并推送

设计要点（对应 0000docs/GITHUB-PUSH-RULES.md）：
- 文件集以 `git ls-files` 为准，再按排除表过滤（运行数据、私有运行时、个人证书）
- 推送前做两层扫描：凭据形状 + 本机路径/主机名元信息，任一命中即中止
- 发布仓库保持单线提交，不带开发历史（开发历史含早期已删除的 NapCat 运行时）
"""
import io
import os
import re
import shutil
import subprocess
import sys

DEV = r'D:/WorkBuddy/QQFarmBotHim'
PUB = r'D:/WorkBuddy/QQFarmBotHim-release'

# 不进公开仓库的路径（前缀匹配）
SKIP_PREFIX = (
    'node_modules/', 'web/dist/', 'data/', 'logs/', 'runtime/', 'panel/run/', 'panel/logs/',
    'fetcher/napcat/',
)
SKIP_EXACT = {
    'fetcher/qqpath.txt',   # 本机 QQ 安装路径
    'tools/mitm-ca.cer',    # 本机 MITM 根证书
    'web/stats.html',       # 构建统计
}

# 凭据形状（命中即中止）
SECRET_PATTERNS = [
    (r"LICENSE_SECRET\s*=\s*['\"][A-Za-z0-9]{20,}['\"]", '许可证种子明文'),
    (r'ghp_[A-Za-z0-9]{20,}', 'GitHub token'),
    (r'github_pat_[A-Za-z0-9_]{20,}', 'GitHub PAT'),
    (r'-----BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY-----', '私钥'),
]

# 元信息（命中需人工判断，脚本按中止处理避免误推）
META_PATTERNS = [
    (r'D:\\WorkBuddy', '本机源码路径'),
    (r'D:\\ProgramData\\QQFarmBotHim', '本机部署路径'),
    (r'C:\\Users\\[A-Za-z0-9._-]+\\', '本机用户目录'),
    (r'DESKTOP-[A-Z0-9]{7,}', '本机主机名'),
]

TEXT_EXT = {'.js', '.ts', '.vue', '.json', '.md', '.ps1', '.bat', '.py', '.yml', '.yaml',
            '.html', '.css', '.proto', '.txt', '.sh', '.mjs', '.cjs'}
SKIP_SCAN_EXT = {'.png', '.jpg', '.jpeg', '.webp', '.gif', '.ico', '.wasm', '.node', '.exe',
                 '.dll', '.cer', '.pfx', '.so', '.dylib', '.ttf', '.woff', '.woff2'}


def run(cmd, cwd, check=True):
    result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                            encoding='utf-8', errors='replace')
    if check and result.returncode != 0:
        print(f'[失败] {" ".join(cmd)}\n{result.stdout}\n{result.stderr}')
        sys.exit(1)
    return result


def main():
    apply = '--yes' in sys.argv

    # 1. 开发仓库必须干净
    status = run(['git', 'status', '--porcelain'], DEV).stdout.strip()
    if status:
        print('[中止] 开发仓库有未提交改动，先提交或还原：')
        print(status[:800])
        sys.exit(1)

    # 2. 取白名单文件
    files = run(['git', '-c', 'core.quotepath=false', 'ls-files'], DEV).stdout.splitlines()
    files = [f for f in files
             if f not in SKIP_EXACT and not any(f.startswith(p) for p in SKIP_PREFIX)]
    print(f'[1/5] 白名单文件：{len(files)} 个')

    # 3. 同步（以发布目录为镜像）
    if os.path.isdir(PUB):
        for name in os.listdir(PUB):
            if name == '.git':
                continue
            path = os.path.join(PUB, name)
            shutil.rmtree(path) if os.path.isdir(path) else os.remove(path)
    os.makedirs(PUB, exist_ok=True)
    copied = 0
    for rel in files:
        src = os.path.join(DEV, rel)
        dst = os.path.join(PUB, rel)
        if not os.path.isfile(src):
            continue
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(src, dst)
        copied += 1
    print(f'[2/5] 已同步 {copied} 个文件')

    # 4. 敏感扫描
    secret_hits, meta_hits = [], []
    for rel in files:
        ext = os.path.splitext(rel)[1].lower()
        if ext in SKIP_SCAN_EXT:
            continue
        path = os.path.join(PUB, rel)
        if not os.path.isfile(path):
            continue
        try:
            text = io.open(path, encoding='utf-8', errors='ignore').read()
        except Exception:
            continue
        for pattern, label in SECRET_PATTERNS:
            if re.search(pattern, text):
                secret_hits.append(f'{rel} <- {label}')
        for pattern, label in META_PATTERNS:
            if re.search(pattern, text):
                meta_hits.append(f'{rel} <- {label}')

    if secret_hits:
        print('[中止] 凭据形状命中（必须清理）：')
        for item in secret_hits[:20]:
            print('  ', item)
        sys.exit(1)
    if meta_hits:
        print('[中止] 本机元信息命中（改占位或加排除）：')
        for item in meta_hits[:20]:
            print('  ', item)
        sys.exit(1)
    print('[3/5] 扫描通过：无凭据形状、无本机元信息')

    # 5. 提交 / 推送
    run(['git', 'add', '-A'], PUB)
    diff = subprocess.run(['git', 'diff', '--cached', '--stat'], cwd=PUB, capture_output=True,
                          text=True, encoding='utf-8', errors='replace').stdout.strip()
    if not diff:
        print('[4/5] 与发布仓库无差异，无需提交')
        return
    print('[4/5] 变更摘要：')
    print(diff)

    if not apply:
        print('[5/5] 演练模式：未提交。确认无误后加 --yes 执行。')
        return

    run(['git', 'commit', '-m', 'chore: 同步源码快照'], PUB)
    run(['git', 'push', 'origin', 'main'], PUB)
    print('[5/5] 已提交并推送')


if __name__ == '__main__':
    main()
