// INTO SIGN - 아이디 로그인 함수
// 아이디를 이메일로 변환해 서버에서 로그인 처리
// 이메일 주소를 클라이언트에 노출하지 않음

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, error: "METHOD_NOT_ALLOWED" }, 405);

  try {
    const { identifier, password } = await req.json() ?? {};
    if (!identifier || !password) {
      return json({ ok: false, error: "MISSING_CREDENTIALS" }, 400);
    }

    const SB_URL = Deno.env.get("SUPABASE_URL")!;
    const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;

    const raw = String(identifier).trim();
    let email = raw;

    // 아이디로 입력한 경우 이메일로 변환
    if (!raw.includes("@")) {
      const admin = createClient(SB_URL, SERVICE, { auth: { persistSession: false } });
      const { data: prof } = await admin
        .schema("esign").from("profiles")
        .select("email").ilike("username", raw).maybeSingle();

      if (!prof?.email) {
        // 존재 여부를 구분해 알려주지 않음 (계정 탐색 방지)
        return json({ ok: false, error: "INVALID_CREDENTIALS" }, 401);
      }
      email = prof.email;
    }

    // 실제 로그인은 anon 키로 수행 (정상 세션 발급)
    const pub = createClient(SB_URL, ANON, { auth: { persistSession: false } });
    const { data, error } = await pub.auth.signInWithPassword({ email, password });

    if (error || !data?.session) {
      return json({ ok: false, error: "INVALID_CREDENTIALS" }, 401);
    }

    return json({
      ok: true,
      access_token: data.session.access_token,
      refresh_token: data.session.refresh_token,
    });
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
