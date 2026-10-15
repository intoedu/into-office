// ============================================================
// esign-notify · 카카오 알림톡 발송
//
// 호출
//   POST { kind, document_id }          단건
//   POST { kind, document_ids: [...] }  대량 (한 번의 API 호출로 묶어 보낸다)
//
// SOLAPI_* 키가 없는 동안에는 실제 발송 없이 status='skipped' 로
// 기록만 남긴다. 키와 템플릿 코드를 넣는 순간 발송이 시작된다.
//
// esign 스키마는 PostgREST 에 노출되어 있지 않다.
// 대상 조회·발송 기록은 public 래퍼(esign_notify_targets / esign_alimtalk_log)로 한다.
// ============================================================
import { createClient } from "jsr:@supabase/supabase-js@2";

const SOLAPI_URL = "https://api.solapi.com/messages/v4/send-many/detail";
const MAX_DOCS = 500;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const env = (k: string) => Deno.env.get(k) ?? "";
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

const providerReady = () =>
  !!(env("SOLAPI_API_KEY") && env("SOLAPI_API_SECRET") && env("SOLAPI_PFID") && env("SOLAPI_SENDER"));

async function authHeader(): Promise<string> {
  const date = new Date().toISOString();
  const salt = crypto.randomUUID().replace(/-/g, "");
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(env("SOLAPI_API_SECRET")),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(date + salt));
  const signature = [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
  return `HMAC-SHA256 apiKey=${env("SOLAPI_API_KEY")}, date=${date}, salt=${salt}, signature=${signature}`;
}

const TEMPLATE_ENV: Record<string, string> = {
  request: "ALIMTALK_TPL_REQUEST",
  remind: "ALIMTALK_TPL_REMIND",
  done: "ALIMTALK_TPL_DONE",
};

const fmtDate = (v: string | null) =>
  v ? new Date(v).toLocaleString("ko-KR", { timeZone: "Asia/Seoul", dateStyle: "long", timeStyle: "short" }) : "미지정";
const digits = (p: string) => (p ?? "").replace(/[^0-9]/g, "");

function isServiceRole(authz: string): boolean {
  try {
    return JSON.parse(atob(authz.replace(/^Bearer\s+/i, "").split(".")[1]))?.role === "service_role";
  } catch { return false; }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, error: "METHOD_NOT_ALLOWED" }, 405);

  let body: { kind?: string; document_id?: string; document_ids?: string[] };
  try { body = await req.json(); } catch { return json({ ok: false, error: "BAD_JSON" }, 400); }

  const kind = body.kind ?? "request";
  if (!TEMPLATE_ENV[kind]) return json({ ok: false, error: "BAD_KIND" }, 400);

  const ids = (body.document_ids?.length ? body.document_ids : (body.document_id ? [body.document_id] : []))
    .slice(0, MAX_DOCS);
  if (!ids.length) return json({ ok: false, error: "DOCUMENT_ID_REQUIRED" }, 400);

  const authz = req.headers.get("Authorization") ?? "";
  const admin = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"));

  // 권한 확인 — 문서마다 검사한다. 서비스 롤 호출은 생략.
  if (!isServiceRole(authz)) {
    const caller = createClient(env("SUPABASE_URL"), env("SUPABASE_ANON_KEY"), {
      global: { headers: { Authorization: authz } },
    });
    for (const id of ids) {
      const { data: perm } = await caller.rpc("esign_can_notify", { p_document_id: id });
      if (!perm?.ok) return json({ ok: false, error: perm?.error ?? "FORBIDDEN", document_id: id }, 403);
    }
  }

  const base = (env("SIGN_BASE_URL") || "https://intoedu.github.io/into-office/").replace(/\/?$/, "/");
  const templateId = env(TEMPLATE_ENV[kind]);
  const ready = providerReady() && !!templateId;

  type Row = { org_id: string; doc_id: string; phone: string; vars: Record<string, string> };
  const rows: Row[] = [];
  const notFound: string[] = [];

  for (const id of ids) {
    const { data: info } = await admin.rpc("esign_notify_targets", { p_kind: kind, p_document_id: id });
    if (!info?.ok) { notFound.push(id); continue; }

    const doc = info.document;
    for (const t of info.targets ?? []) {
      if (digits(t.phone).length < 10) continue;
      const link = `${base}?s=${t.sign_token}`;
      const vars: Record<string, string> = {
        "#{이름}": t.name,
        "#{조직명}": doc.org_name,
        "#{요청자}": doc.requester_name,
        "#{문서명}": doc.title,
        "#{기한}": fmtDate(doc.deadline),
        "#{서명링크}": link,
      };
      if (kind === "done") {
        vars["#{완료일시}"] = fmtDate(doc.completed_at);
        vars["#{서명자목록}"] = doc.signer_names ?? t.name;
        vars["#{문서링크}"] = link;
      }
      rows.push({ org_id: doc.org_id, doc_id: doc.id, phone: t.phone, vars });
    }
  }

  if (!rows.length) {
    return json({ ok: true, sent: 0, documents: ids.length, not_found: notFound, note: "발송 대상이 없습니다" });
  }

  const logBase = (status: string, error: string | null, response: unknown) =>
    rows.map((r) => ({
      org_id: r.org_id, document_id: r.doc_id, kind,
      template_id: templateId || null, to_phone: r.phone, variables: r.vars,
      status, error, response,
      sent_at: status === "sent" ? new Date().toISOString() : null,
    }));

  if (!ready) {
    await admin.rpc("esign_alimtalk_log", { p_rows: logBase("skipped", "PROVIDER_NOT_CONFIGURED", null) });
    return json({
      ok: true, sent: 0, skipped: rows.length, documents: ids.length, not_found: notFound,
      note: "발송 대행사 설정이 없어 기록만 남겼습니다. SOLAPI_* 와 템플릿 코드를 등록하면 발송이 시작됩니다.",
    });
  }

  const messages = rows.map((r) => ({
    to: digits(r.phone),
    from: digits(env("SOLAPI_SENDER")),
    kakaoOptions: { pfId: env("SOLAPI_PFID"), templateId, variables: r.vars, disableSms: false },
  }));

  let result: unknown = null;
  let failed = false;
  try {
    const res = await fetch(SOLAPI_URL, {
      method: "POST",
      headers: { Authorization: await authHeader(), "Content-Type": "application/json" },
      body: JSON.stringify({ messages }),
    });
    result = await res.json().catch(() => ({ status: res.status }));
    failed = !res.ok;
  } catch (e) {
    failed = true;
    result = { error: String(e) };
  }

  await admin.rpc("esign_alimtalk_log", {
    p_rows: logBase(failed ? "failed" : "sent", failed ? JSON.stringify(result).slice(0, 500) : null, result),
  });

  return json({ ok: !failed, sent: failed ? 0 : rows.length, documents: ids.length, not_found: notFound, result },
              failed ? 502 : 200);
});
