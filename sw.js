// ============================================================
// 인투오피스 — PC · 휴대폰에 「앱으로 설치」 할 때 쓰는 서비스 워커
//
// 화면 · 데이터는 저장(캐시)하지 않는다. 항상 서버에서 최신 화면을 받는다.
// 인터넷이 끊겼을 때 페이지 이동만 「연결 확인」 안내 화면으로 대신한다.
// API · 파일 · 다른 사이트 요청은 건드리지 않는다.
// ============================================================
const OFFLINE_HTML = `<!doctype html><html lang="ko"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>INTO OFFICE</title>
<style>body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#f4f6f9;
font-family:-apple-system,'Malgun Gothic',sans-serif;color:#1a2a3a}.c{text-align:center;padding:32px}
h1{font-size:20px;margin:0 0 10px}p{color:#5a6d7e;font-size:14px;line-height:1.7;margin:0 0 18px}
button{padding:11px 22px;border:0;border-radius:8px;background:#0e2d4d;color:#fff;font-size:14px;font-weight:700;cursor:pointer}</style>
</head><body><div class="c"><h1>인터넷에 연결되어 있지 않습니다</h1>
<p>인투오피스는 인터넷이 연결되어 있어야 사용할 수 있습니다.<br>연결을 확인한 뒤 다시 시도해 주세요.</p>
<button onclick="location.reload()">다시 시도</button></div></body></html>`;

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.mode !== 'navigate') return;   // 페이지 이동만 (그 밖의 요청은 브라우저가 그대로 처리)
  e.respondWith(fetch(req).catch(() =>
    new Response(OFFLINE_HTML, { headers: { 'Content-Type': 'text/html; charset=utf-8' } })));
});
