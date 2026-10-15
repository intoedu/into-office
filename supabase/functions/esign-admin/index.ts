// INTO SIGN - 관리자 전용 계정 관리 함수
// 역할: 비밀번호 재설정 링크 발급 / 임시 비밀번호 발급
// 보안: 호출자가 실제 관리자인지 DB로 검증

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

/** 읽기 쉽고 혜안되지 않는 임시 비밀번호 생성 */
function makeTempPassword(): string {
  const A = "ABCDEFGHJKLMNPQRSTUVWXYZ";   // I, O 제외
  const a = "abcdefghijkmnpqrstuvwxyz";   // l, o 제외
  const n = "23456789";                   // 0, 1 제외
  const s = "!@#$";
  const pick = (set: string, k: number) => {
    const buf = new Uint32Array(k);
    crypto.getRandomValues(buf);
    return Array.from(buf, (v) => set[v % set.length]).join("");
  };
  const raw = pick(A, 2) + pick(a, 5) + pick(n, 3) + pick(s, 1);
  const arr = raw.split("");
  const idx = new Uint32Array(arr.length);
  crypto.getRandomValues(idx);
  for (let i = arr.length - 1; i > 0; i--) {
    const j = idx[i] % (i + 1);
    [arr[i], arr[j]] = [arr[j], arr[i]];
  }
  return arr.join("");
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, error: "METHOD_NOT_ALLOWED" }, 405);

  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const token = authHeader.replace(/^Bearer\s+/i, "");
    if (!token) return json({ ok: false, error: "AUTH_REQUIRED" }, 401);

    const SB_URL = Deno.env.get("SUPABASE_URL")!;
    const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const admin = createClient(SB_URL, SERVICE, { auth: { persistSession: false } });

    // 1) 호출자 신원 확인
    const { data: caller, error: uErr } = await admin.auth.getUser(token);
    if (uErr || !caller?.user) return json({ ok: false, error: "INVALID_TOKEN" }, 401);

    // 2) 관리자 권한 검증
    const { data: prof } = await admin
      .schema("esign").from("profiles")
      .select("role, status").eq("user_id", caller.user.id).single();

    if (!prof || prof.role !== "admin" || prof.status !== "active") {
      return json({ ok: false, error: "ADMIN_ONLY" }, 403);
    }

    const body = await req.json();
    const { action, user_id, redirect_to } = body ?? {};
    if (!user_id) return json({ ok: false, error: "USER_ID_REQUIRED" }, 400);
    if (user_id === caller.user.id) {
      return json({ ok: false, error: "CANNOT_MODIFY_SELF" }, 400);
    }

    // 대상 사용자 조회
    const { data: target, error: tErr } = await admin.auth.admin.getUserById(user_id);
    if (tErr || !target?.user?.email) {
      return json({ ok: false, error: "USER_NOT_FOUND" }, 404);
    }
    const email = target.user.email;

    // ===== 재설정 링크 발급 =====
    if (action === "reset_link") {
      const { data, error } = await admin.auth.admin.generateLink({
        type: "recovery",
        email,
        options: { redirectTo: redirect_to || undefined },
      });
      if (error) return json({ ok: false, error: error.message }, 400);
      return json({
        ok: true,
        email,
        link: data.properties?.action_link,
        expires_hint: "발급 후 1시간 동안 유효합니다.",
      });
    }

    // ===== 임시 비밀번호 발급 =====
    if (action === "temp_password") {
      const pw = makeTempPassword();
      const { error } = await admin.auth.admin.updateUserById(user_id, { password: pw });
      if (error) return json({ ok: false, error: error.message }, 400);
      return json({ ok: true, email, password: pw });
    }

    return json({ ok: false, error: "UNKNOWN_ACTION" }, 400);
  } catch (e) {
    return json({ ok: false, error: String(e) }, 500);
  }
});
