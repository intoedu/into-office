// ============================================================
// esign-file · 비공개 버킷의 문서에 대한 유효기간 URL 발급
//
// 호출
//   POST { path, sign_token? }
//
// 권한
//   sign_token 이 있으면  → 그 토큰이 가리키는 문서의 파일인지 확인 (비로그인 서명자)
//   없으면            → Authorization 의 사용자가 볼 수 있는 문서인지 확인
//
// 서명 토큰은 비로그인으로 써야 하므로 verify_jwt 를 끄고
// 함수 내부에서 직접 권한을 검사한다.
//
// 권한 판정은 esign.file_access() 가 하지만, esign 스키마는 PostgREST 에
// 노출되어 있지 않다. 그래서 public.esign_file_access() 래퍼를 호출한다.
// (schema('esign') 로 직접 부르면 PGRST106 "Invalid schema: esign" 이 난다)
// ============================================================
import { createClient } from "jsr:@supabase/supabase-js@2";

const BUCKET = "esign-docs";
const TTL = 60 * 30; // 30분

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const env = (k: string) => Deno.env.get(k) ?? "";
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, error: "METHOD_NOT_ALLOWED" }, 405);

  let body: { path?: string; sign_token?: string };
  try { body = await req.json(); } catch { return json({ ok: false, error: "BAD_JSON" }, 400); }

  const path = (body.path ?? "").trim();
  const signToken = (body.sign_token ?? "").trim();
  if (!path) return json({ ok: false, error: "PATH_REQUIRED" }, 400);

  const admin = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"));

  // 로그인 사용자라면 그 신원을 확인한다
  let uid: string | null = null;
  const authz = req.headers.get("Authorization") ?? "";
  if (!signToken && authz) {
    const jwt = authz.replace(/^Bearer\s+/i, "");
    const { data } = await admin.auth.getUser(jwt);
    uid = data?.user?.id ?? null;
  }

  const { data: perm, error: permErr } = await admin.rpc("esign_file_access", {
    p_path: path,
    p_sign_token: signToken || null,
    p_uid: uid,
  });

  if (permErr) return json({ ok: false, error: permErr.message }, 500);
  if (!perm?.ok) {
    const status = perm?.error === "AUTH_REQUIRED" ? 401
                 : perm?.error === "FORBIDDEN" ? 403
                 : 404;
    return json({ ok: false, error: perm?.error ?? "FORBIDDEN" }, status);
  }

  const { data: signed, error: signErr } = await admin.storage
    .from(BUCKET)
    .createSignedUrl(path, TTL);

  if (signErr || !signed?.signedUrl) {
    return json({ ok: false, error: signErr?.message ?? "SIGN_FAILED" }, 500);
  }

  return json({
    ok: true,
    url: signed.signedUrl,
    expires_in: TTL,
    document_id: perm.document_id,
    via: perm.via,
  });
});
