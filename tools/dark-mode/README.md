# 다크 모드 색 만들기

`index.html` 의 `<style>` 끝에 있는 `/* ===== DARK MODE (generated) ===== */` ~ `/* ===== DARK MODE END ===== */` 블록은 이 도구로 만든다.

- `dark_manual.css` — 손으로 쓴 부분 (색 변수, 입력 칸, 테마별 보정, 직접 쓴 `style="background:#fff"` 덮어쓰기)
- `darkgen.py` — 스타일을 읽어 밝은 바탕 → 어두운 바탕, 어두운 글자 → 밝은 글자, 밝은 테두리 → 어두운 테두리로 자동 계산
  (문서 · 서명 칸 · 카카오 미리보기처럼 색을 지켜야 하는 곳은 `SKIP` 에서 건너뛴다)
- `apply.py` — 기존 블록을 지우고 새로 만들어 넣는다

화면 스타일을 고친 뒤에는 다시 실행한다.

```bash
pip install tinycss2
python3 tools/dark-mode/apply.py
```
