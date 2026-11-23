"""다크 모드 CSS 다시 만들기: python3 tools/dark-mode/apply.py
(index.html 의 스타일을 고친 뒤 실행 — DARK MODE 블록을 지우고 새로 넣는다. 필요: pip install tinycss2)"""
import re, subprocess, sys
import os
M = os.path.dirname(os.path.abspath(__file__)) + '/'
p = M + '../../index.html'
s = open(p).read()
MARK = '/* ===== DARK MODE (generated) ===== */'
END = '/* ===== DARK MODE END ===== */'
if MARK in s:   # 다시 만들 때는 지우고 새로
    a = s.index(MARK); b = s.index(END) + len(END)
    s = s[:a] + s[b:]
    open(p, 'w').write(s)
subprocess.run(['python3', M + 'darkgen.py', M + 'dark_gen.css'], check=True)  # dark_gen.css 는 만들 때마다 새로 쓴다
gen = open(M + 'dark_gen.css').read()
manual = open(M + 'dark_manual.css').read()
block = MARK + '\n' + manual + '\n/* 자동 계산 (밝은 바탕 → 어두운 바탕, 어두운 글자 → 밝은 글자) */\n' + gen + '\n' + END + '\n'
i = s.index('</style>')
s = s[:i] + block + s[i:]
open(p, 'w').write(s)
print('dark block', len(block))
