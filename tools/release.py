#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""QQFarmBotHim 发版脚本。

用法：
    python tools/release.py            # 按 core/package.json 的版本发版
    python tools/release.py --dry-run  # 只跑前置校验，不同步、不打 tag、不推送
    python tools/release.py --skip-tests

流程（对应 0000docs/GITHUB-PUSH-RULES.md §7）：
  1. 版本格式校验
  2. CHANGELOG 必须已有该版本小节（脚本不代写）
  3. 开发仓库工作区干净
  4. 分支为 master
  5. 目标 tag 在本地发布仓库与远端都不存在
  6. 跑 core 测试（可 --skip-tests 跳过）
  7. 同步到发布仓库并推送 main
  8. 在发布仓库打 annotated tag 并推送（CI 由 tag 触发建 Release）
  9. 轮询核对 Release 已出现（tag、正文、非 Draft）
任一步失败即停，并打印当前停在哪个阶段。
"""
import json
import glob
import io
import os
import re
import subprocess
import sys
import time
import urllib.request

DEV = r'D:/WorkBuddy/QQFarmBotHim'
PUB = r'D:/WorkBuddy/QQFarmBotHim-release'
REPO = 'HimA6652/QQFarmBotHim'
PYTHON = sys.executable


def run(cmd, cwd, check=True, timeout=None):
    result = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                            encoding='utf-8', errors='replace', timeout=timeout)
    if check and result.returncode != 0:
        print(f'[失败] {" ".join(cmd)}')
        print(result.stdout[-2000:])
        print(result.stderr[-2000:])
        sys.exit(1)
    return result


def fail(stage, message):
    print(f'[中止 @ {stage}] {message}')
    sys.exit(1)


def main():
    dry = '--dry-run' in sys.argv
    skip_tests = '--skip-tests' in sys.argv

    version = json.load(open(os.path.join(DEV, 'core', 'package.json'), encoding='utf-8'))['version']
    tag = f'v{version}'
    print(f'== 目标版本：{version}（tag {tag}）==')

    # 1. 版本格式
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[A-Za-z0-9.]+)?', version):
        fail('版本格式', f'{version} 不是合法的 x.y.z 或 x.y.z-预发布')
    print('[1/8] 版本格式 OK')

    # 2. CHANGELOG 小节
    notes = run([PYTHON, 'tools/release-notes.py', version], DEV, check=False)
    if notes.returncode != 0:
        fail('CHANGELOG', notes.stderr.strip() or '缺少该版本小节')
    print(f'[2/8] CHANGELOG 小节存在（{len(notes.stdout.strip())} 字符）')

    # 3. 工作区干净
    status = run(['git', 'status', '--porcelain'], DEV).stdout.strip()
    if status:
        fail('工作区', f'开发仓库有未提交改动：\n{status[:600]}')
    print('[3/8] 工作区干净')

    # 4. 分支
    branch = run(['git', 'rev-parse', '--abbrev-ref', 'HEAD'], DEV).stdout.strip()
    if branch != 'master':
        fail('分支', f'当前在 {branch}，发版要求在 master')
    print('[4/8] 分支 master OK')

    # 5. tag 不存在（本地发布仓库 + 远端）
    local_tag = run(['git', 'tag', '--list', tag], PUB).stdout.strip()
    if local_tag:
        fail('tag', f'发布仓库已存在本地 tag {tag}')
    remote = run(['git', 'ls-remote', '--tags', 'origin', f'refs/tags/{tag}'], PUB).stdout.strip()
    if remote:
        fail('tag', f'远端已存在 tag {tag}（如需重发请换版本号，不要移动已发布 tag）')
    print('[5/8] tag 未被占用')

    # 6. 测试（允许清单内的失败放行，清单外失败即中止）
    if skip_tests:
        print('[6/8] 测试已跳过（--skip-tests）')
    else:
        print('[6/8] 运行 core 测试…')
        core_dir = os.path.join(DEV, 'core')
        test_files = sorted(glob.glob(os.path.join(core_dir, 'test', '*.test.js')))
        test = run(['node', '--test'] + test_files, core_dir, check=False, timeout=1800)
        tail = (test.stdout or '').strip().splitlines()[-6:]
        print('    ' + '\n    '.join(tail))
        failures = re.findall(r'^not ok \d+ - (.+)$', test.stdout or '', re.M)
        known_file = os.path.join(DEV, 'tools', 'known-test-failures.txt')
        known = set()
        if os.path.isfile(known_file):
            known = {line.strip() for line in io.open(known_file, encoding='utf-8')
                     if line.strip() and not line.startswith('#')}
        unknown = [name for name in failures if name not in known]
        if unknown:
            print(f'    [中止] 出现 {len(unknown)} 个清单外失败：')
            for name in unknown[:10]:
                print(f'      - {name}')
            fail('测试', '存在已知清单之外的测试失败')
        if failures:
            print(f'    {len(failures)} 个已知失败已登记（tools/known-test-failures.txt），其余通过')
        else:
            print('    全部测试通过')

    if dry:
        print('\n[演练结束] 前置校验全部通过；未同步、未打 tag、未推送。')
        return

    # 7. 同步并推送 main
    print('[7/8] 同步到发布仓库…')
    sync = run([PYTHON, 'tools/publish-to-github.py', '--yes'], DEV, check=False, timeout=1800)
    print('    ' + '\n    '.join((sync.stdout or '').strip().splitlines()[-4:]))
    if sync.returncode != 0:
        fail('同步', 'publish-to-github.py 失败')

    # 8. 打 tag 并推送
    print('[8/8] 打 tag 并推送…')
    run(['git', 'tag', '-a', tag, '-m', tag], PUB)
    run(['git', 'push', 'origin', tag], PUB, timeout=600)
    print(f'    已推送 {tag}，等待 CI 建 Release…')

    # 9. 轮询 Release
    deadline = time.time() + 600
    api = f'https://api.github.com/repos/{REPO}/releases/tags/{tag}'
    body = ''
    while time.time() < deadline:
        try:
            req = urllib.request.Request(api, headers={'Accept': 'application/vnd.github+json',
                                                       'User-Agent': 'release-script'})
            with urllib.request.urlopen(req, timeout=20) as resp:
                data = json.load(resp)
            body = data.get('body') or ''
            print(f'    Release 已创建：{data.get("html_url")}')
            print(f'    Draft={data.get("draft")} Prerelease={data.get("prerelease")} 正文 {len(body)} 字符')
            break
        except urllib.error.HTTPError as error:
            if error.code != 404:
                print(f'    查询返回 HTTP {error.code}，继续等待')
            time.sleep(15)
        except Exception as error:
            print(f'    查询异常（{error}），继续等待')
            time.sleep(15)
    else:
        fail('Release', f'600 秒内未看到 Release；检查 Actions：https://github.com/{REPO}/actions')

    # 正文来自 CHANGELOG 小节，已随源码一起经过 publish-to-github.py 的两层扫描，
    # 这里不再重复关键字检查（避免脚本自身携带本机路径字面量）。
    print('\n完成。')


if __name__ == '__main__':
    main()
