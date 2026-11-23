"""index.html 의 <style> 을 읽어 다크 모드용 덮어쓰기 CSS 를 만든다.
- 밝은 바탕(흰색 · 연한 색)  → 같은 색조의 어두운 바탕
- 어두운 글자(남색 · 검정 등) → 같은 색조의 밝은 글자
- 밝은 테두리               → 어두운 테두리
- color: var(--navy)        → 밝은 남색 글자 (--navy 는 머리말 · 버튼 바탕에도 쓰여 값 자체는 두고 글자만 바꾼다)
문서 · 서명 그림처럼 종이 색을 지켜야 하는 곳은 건너뛴다."""
import re, colorsys, sys
import tinycss2

import os
HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, '..', '..', 'index.html')
html = open(SRC).read()
styles = re.findall(r'<style[^>]*>(.*?)</style>', html, re.S)
css = styles[0]
# 이미 만든 다크 블록은 다시 읽지 않는다
css = css.split('/* ===== DARK MODE (generated) ===== */')[0]

SKIP = re.compile(r'msg-preview|btn-alim|pa-pad|canvas|pdf-page|sig-pad|signature|sa-kakao|kakao|share-card|sl-alim|stamp|sv-|vault|sig-prev|typed|th-sw|smk-|mk-item|sig-field|in-field|boot-|pv-body|lp-shot|lp-hero-img|mock|qr', re.I)
DARK_BASE = (15, 20, 26)

def hex2rgb(h):
    h = h.lstrip('#')
    if len(h) == 3: h = ''.join(c * 2 for c in h)
    if len(h) != 6: return None
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))
def rgb2hex(c): return '#%02x%02x%02x' % tuple(max(0, min(255, int(round(x)))) for x in c)
def hls(c): return colorsys.rgb_to_hls(*(x / 255 for x in c))
def from_hls(h, l, s): return tuple(x * 255 for x in colorsys.hls_to_rgb(h, l, s))

def dark_bg(c):
    h, l, s = hls(c)
    if s < 0.08: return '#171d25'                       # 흰색 · 회색 → 카드색
    return rgb2hex(from_hls(h, 0.15, min(0.45, s * 0.55)))
def light_fg(c):
    h, l, s = hls(c)
    if s < 0.08: return '#e6edf3'
    return rgb2hex(from_hls(h, 0.80, min(0.75, s)))
def dark_border(c):
    h, l, s = hls(c)
    if s < 0.08: return '#2a3441'
    return rgb2hex(from_hls(h, 0.26, min(0.4, s * 0.5)))

def map_value(prop, value):
    """값 안의 색을 바꾼 새 값 (안 바뀌면 None)"""
    changed = False
    def sub_hex(m):
        nonlocal changed
        c = hex2rgb(m.group(0))
        if not c: return m.group(0)
        h, l, s = hls(c)
        if prop.startswith('background') or prop == 'fill':
            if l >= 0.88: changed = True; return dark_bg(c)
        elif prop == 'color':
            if l <= 0.52: changed = True; return light_fg(c)
        elif prop.startswith('border') or prop.startswith('outline'):
            if l >= 0.80: changed = True; return dark_border(c)
        return m.group(0)
    v = re.sub(r'#[0-9a-fA-F]{3,6}\b', sub_hex, value)
    if prop.startswith('background'):
        def sub_rgba(m):
            nonlocal changed
            if float(m.group(1)) < 0.5: return m.group(0)   # 어두운 바탕 위 살짝 밝게(호버)는 그대로
            changed = True
            return 'rgba(23,29,37,' + m.group(1) + ')'
        v = re.sub(r'rgba\(\s*255\s*,\s*255\s*,\s*255\s*,\s*([0-9.]+)\s*\)', sub_rgba, v)
        if re.search(r'(^|[\s,(])white\b', v): v = re.sub(r'\bwhite\b', '#171d25', v); changed = True
    if prop == 'color' and re.fullmatch(r'\s*var\(--navy(-dark|-light)?\)\s*(!important)?\s*', v):
        v = 'var(--navy-text)'; changed = True
    return v if changed else None

out = []
def prefix(sel):
    parts = []
    for s in sel.split(','):
        s = s.strip()
        if not s: continue
        if s.startswith(':root') or s.startswith('html'): continue
        parts.append('html[data-mode="dark"] ' + s)
    return ', '.join(parts)

def walk(rules, media=None):
    for r in rules:
        if r.type == 'qualified-rule':
            sel = tinycss2.serialize(r.prelude).strip()
            if SKIP.search(sel): continue
            decls = tinycss2.parse_declaration_list(r.content, skip_comments=True, skip_whitespace=True)
            new = []
            for d in decls:
                if d.type != 'declaration': continue
                prop = d.lower_name
                if prop not in ('background', 'background-color', 'color', 'border', 'border-color', 'border-top', 'border-bottom',
                                'border-left', 'border-right', 'outline', 'fill'): continue
                val = tinycss2.serialize(d.value).strip()
                nv = map_value(prop, val)
                if nv: new.append(f'{prop}:{nv}' + (' !important' if d.important else ''))
            ps = prefix(sel)
            if new and ps:
                rule = ps + ' { ' + '; '.join(new) + '; }'
                out.append(('  ' + rule) if media else rule)
        elif r.type == 'at-rule' and r.lower_at_keyword == 'media' and r.content:
            inner_start = len(out)
            walk(tinycss2.parse_rule_list(r.content, skip_comments=True, skip_whitespace=True), media=True)
            if len(out) > inner_start:
                out.insert(inner_start, '@media ' + tinycss2.serialize(r.prelude).strip() + ' {')
                out.append('}')

walk(tinycss2.parse_stylesheet(css, skip_comments=True, skip_whitespace=True))
open(sys.argv[1], 'w').write('\n'.join(out))
print(len(out), 'lines')
