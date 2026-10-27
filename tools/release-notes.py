#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 CHANGELOG.md 抽取指定版本的正文，用于生成 GitHub Release 说明。

用法：python tools/release-notes.py 2.8.0-local.10 > RELEASE_NOTES.md
缺少该版本小节或小节为空时以非零码退出（发版前置闸）。
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHANGELOG = os.path.join(ROOT, 'CHANGELOG.md')


def main():
    if len(sys.argv) < 2:
        print('用法: python tools/release-notes.py <版本>', file=sys.stderr)
        return 2
    version = sys.argv[1].lstrip('v')
    text = io.open(CHANGELOG, encoding='utf-8').read()
    pattern = re.compile(
        r'^## \[' + re.escape(version) + r'\][^\n]*\n(.*?)(?=^## |\Z)',
        re.M | re.S,
    )
    match = pattern.search(text)
    if not match:
        print(f'CHANGELOG.md 缺少 [{version}] 小节，拒绝发布', file=sys.stderr)
        return 1
    body = match.group(1).strip()
    if not body:
        print(f'[{version}] 小节为空，拒绝发布', file=sys.stderr)
        return 1
    print(body)
    return 0


if __name__ == '__main__':
    sys.exit(main())
