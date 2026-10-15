// INTO SIGN - 서명자 전용 에지 함수
// 역할: 서명자의 실제 공인 IP를 캐처하여 감사 추적에 기록
// 인증: sign_token 자체가 인증 수단 (로그인 불필요)

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

/** 프록시 체인을 거친 실제 클라이언트 IP 추출 */
function getClientIp(req: Request): string {
  const fwd = req.headers.get("x-forwarded-for");
  if (fwd) {
    // 가장 앞쪽이 원본 클라이언트
    const first = fwd.split(",")[0]?.trim();
    if (first) return first;
  }
  return req.headers.get("cf-connecting-ip")
      ?? req.headers.get("x-real-ip")
      ?? "unknown";
}

/** User-Agent 파싱 */
function parseUA(ua: string) {
  let os = "Unknown", browser = "Unknown";
  if (/Windows NT/i.test(ua)) os = "Windows";
  else if (/iPhone|iPad|iPod/i.test(ua)) os = "iOS";
  else if (/Android/i.test(ua)) os = "Android";
  else if (/Mac OS X/i.test(ua)) os = "macOS";
  else if (/Linux/i.test(ua)) os = "Linux";

  if (/KAKAOTALK/i.test(ua)) browser = "KakaoTalk";
  else if (/Edg\//i.test(ua)) browser = "Edge";
  else if (/SamsungBrowser/i.test(ua)) browser = "Samsung Internet";
  else if (/Whale/i.test(ua)) browser = "Whale";
  else if (/Chrome\//i.test(ua)) browser = "Chrome";
  else if (/Firefox\//i.test(ua)) browser = "Firefox";
  else if (/Safari\//i.test(ua)) browser = "Safari";

  return { os, browser };
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, error: "METHOD_NOT_ALLOWED" }, 405);

  try {
    const body = await req.json();
    const { action, token } = body ?? {};

    if (!token || typeof token !== "string") {
      return json({ ok: false, error: "TOKEN_REQUIRED" }, 400);
    }

    const ip = getClientIp(req);
    const ua = req.headers.get("user-agent") ?? "";
    const { os, browser } = parseUA(ua);

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
      { auth: { persistSession: false } },
    );

    if (action === "view") {
      const { data, error } = await supabase.rpc("esign_record_view", {
        p_token: token,
        p_ip: ip,
        p_user_agent: ua.slice(0, 300),
        p_device_os: os,
        p_device_browser: browser,
      });
      if (error) return json({ ok: false, error: error.message }, 400);
      return json({ ...data, ip, device: { os, browser } });
    }

    if (action === "sign") {
      const { method, sig_data, consent } = body;
      if (consent !== true) return json({ ok: false, error: "CONSENT_REQUIRED" }, 400);

      const { data, error } = await supabase.rpc("esign_submit_signature", {
        p_token: token,
        p_method: method,
        p_sig_data: sig_data,
        p_consent: true,
        p_ip: ip,
        p_user_agent: ua.slice(0, 300),
        p_device_os: os,
        p_device_browser: browser,
      });
      if (error) return json({ ok: false, error: error.message }, 400);
      return json({ ...data, ip, device: { os, browser } });
    }

    return json({ ok: false, error: "UNKNOWN_ACTION" }, 400);
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
