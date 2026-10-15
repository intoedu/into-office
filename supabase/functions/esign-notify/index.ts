// ============================================================
// esign-notify · 카카오 알림톡 발송
//
// 호출
//   POST { kind, document_id }          단건   (request · remind · done)
//   POST { kind, document_ids: [...] }  대량   (한 번의 API 호출로 묶어 보낸다)
//   POST { kind: 'approve', user_id }   가입 승인 안내 (관리자만)
//
// 발송·변수 규칙은 ../_shared/alimtalk.ts 에 있다.
// SOLAPI_* 키가 없는 동안에는 실제 발송 없이 status='skipped' 로 기록만 남긴다.
//
// esign 스키마는 PostgREST 에 노출되어 있지 않다.
// 대상 조회·발송 기록은 public 래퍼(esign_notify_targets / esign_member_notify_info /
// esign_alimtalk_log)로 한다.
// ============================================================
import { createClient } from "npm:@supabase/supabase-js@2.47.10";
import { collectDocRows, fmtDate, isKind, sendRows, type Row } from "../_shared/alimtalk.ts";

const MAX_DOCS = 500;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const env = (k: string) => Deno.env.get(k) ?? "";
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

function isServiceRole(authz: string): boolean {
  try {
    return JSON.parse(atob(authz.replace(/^Bearer\s+/i, "").split(".")[1]))?.role === "service_role";
  } catch { return false; }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, error: "METHOD_NOT_ALLOWED" }, 405);

  let body: { kind?: string; document_id?: string; document_ids?: string[]; user_id?: string };
  try { body = await req.json(); } catch { return json({ ok: false, error: "BAD_JSON" }, 400); }

  const kind = body.kind ?? "request";
  if (!isKind(kind)) return json({ ok: false, error: "BAD_KIND" }, 400);

  const authz = req.headers.get("Authorization") ?? "";
  const admin = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"));
  const caller = createClient(env("SUPABASE_URL"), env("SUPABASE_ANON_KEY"), {
    global: { headers: { Authorization: authz } },
  });
  const trusted = isServiceRole(authz);

  // ---------- 가입 승인 ----------
  if (kind === "approve") {
    if (!body.user_id) return json({ ok: false, error: "USER_ID_REQUIRED" }, 400);
    if (!trusted) {
      const { data: me } = await caller.rpc("esign_me");
      if (!me?.ok || !me.is_admin) return json({ ok: false, error: "ADMIN_ONLY" }, 403);
    }
    const { data: m } = await admin.rpc("esign_member_notify_info", { p_user_id: body.user_id });
    if (!m?.ok) return json({ ok: false, error: m?.error ?? "NOT_FOUND" }, 404);
    if (m.status !== "active") return json({ ok: false, error: "NOT_APPROVED" }, 400);

    const rows: Row[] = (m.phone && m.phone.replace(/[^0-9]/g, "").length >= 10) ? [{
      org_id: null, doc_id: null, phone: m.phone,
      vars: {
        "#{이름}": m.name || "회원",
        "#{아이디}": m.username || m.email || "-",
        "#{승인일시}": fmtDate(m.approved_at),
      },
    }] : [];
    if (!rows.length) return json({ ok: true, sent: 0, note: "연락처가 없어 발송하지 않았습니다" });
    return json(await sendRows(admin, kind, rows));
  }

  // ---------- 문서 기반 발송 ----------
  const ids = (body.document_ids?.length ? body.document_ids : (body.document_id ? [body.document_id] : []))
    .slice(0, MAX_DOCS);
  if (!ids.length) return json({ ok: false, error: "DOCUMENT_ID_REQUIRED" }, 400);

  // 권한 확인 — 문서마다 검사한다. 서비스 롤 호출은 생략.
  if (!trusted) {
    for (const id of ids) {
      const { data: perm } = await caller.rpc("esign_can_notify", { p_document_id: id });
      if (!perm?.ok) return json({ ok: false, error: perm?.error ?? "FORBIDDEN", document_id: id }, 403);
    }
  }

  const { rows, notFound } = await collectDocRows(admin, kind, ids);
  if (!rows.length) {
    return json({ ok: true, sent: 0, documents: ids.length, not_found: notFound, note: "발송 대상이 없습니다" });
  }

  const r = await sendRows(admin, kind, rows);
  return json({ ...r, documents: ids.length, not_found: notFound }, r.ok ? 200 : 502);
});
