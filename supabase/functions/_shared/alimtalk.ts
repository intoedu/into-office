// ============================================================
// 카카오 알림톡 공통 모듈 (솔라피)
//
// esign-notify(관리자 화면에서 호출)와 esign-sign(마지막 서명 시 완료 통지)이
// 함께 쓴다. 변수 이름은 docs/알림톡-템플릿-초안.md 의 등록 템플릿과
// 한 글자도 다르지 않아야 한다 — 다르면 솔라피가 발송을 거절한다.
//
// SOLAPI_* 키나 템플릿 코드가 없으면 실제 발송 없이 status='skipped' 로 기록만 남긴다.
// ============================================================
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";

const SOLAPI_URL = "https://api.solapi.com/messages/v4/send-many/detail";

export type Kind = "request" | "remind" | "done" | "approve";

const TEMPLATE_ENV: Record<Kind, string> = {
  request: "ALIMTALK_TPL_REQUEST",
  remind: "ALIMTALK_TPL_REMIND",
  done: "ALIMTALK_TPL_DONE",
  approve: "ALIMTALK_TPL_APPROVE",
};

export const isKind = (k: unknown): k is Kind =>
  typeof k === "string" && k in TEMPLATE_ENV;

const env = (k: string) => Deno.env.get(k) ?? "";

export const serviceBase = () =>
  (env("SIGN_BASE_URL") || "https://intoedu.github.io/into-office/").replace(/\/?$/, "/");

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

export const fmtDate = (v: string | null | undefined) =>
  v ? new Date(v).toLocaleString("ko-KR", { timeZone: "Asia/Seoul", dateStyle: "long", timeStyle: "short" })
    : "미지정";

export const digits = (p: string) => (p ?? "").replace(/[^0-9]/g, "");

// 서명 기한까지 남은 기간 — 리마인드 템플릿의 #{남은기간}
export function remainText(deadline: string | null | undefined): string {
  if (!deadline) return "기한 없음";
  const ms = new Date(deadline).getTime() - Date.now();
  if (ms <= 0) return "기한 경과";
  const days = Math.floor(ms / 86_400_000);
  if (days >= 1) return `${days}일`;
  return `${Math.max(1, Math.floor(ms / 3_600_000))}시간`;
}

// 010-1234-5678 → 010-****-5678 (가운데를 가린다)
export function maskPhone(p: string): string {
  const d = digits(p);
  if (d.length < 8) return "***";
  return `${d.slice(0, 3)}-****-${d.slice(-4)}`;
}

// 서명 요청 템플릿의 #{서명자목록} — 함께 서명하는 사람 전원 (줄바꿈으로 구분)
//   1. 홍길동 (010-****-1234)
//   2. 김철수 (010-****-5678)
function signerLines(targets: Array<{ name: string; phone: string }>): string {
  return targets.map((t, i) => `${i + 1}. ${t.name} (${maskPhone(t.phone)})`).join("\n");
}

export type Row = {
  org_id: string | null;
  doc_id: string | null;
  phone: string;
  vars: Record<string, string>;
};

// 문서 기반 발송(요청 · 리마인드 · 완료)의 수신자와 변수를 만든다
export async function collectDocRows(admin: SupabaseClient, kind: Kind, ids: string[]) {
  const rows: Row[] = [];
  const notFound: string[] = [];
  const base = serviceBase();

  for (const id of ids) {
    const { data: info } = await admin.rpc("esign_notify_targets", { p_kind: kind, p_document_id: id });
    if (!info?.ok) { notFound.push(id); continue; }

    const doc = info.document;
    // 서명 요청 시점에는 아직 아무도 서명하지 않았으므로 targets 가 곧 서명자 전원이다
    const allSigners = kind === "request" ? signerLines(info.targets ?? []) : "";
    for (const t of info.targets ?? []) {
      if (digits(t.phone).length < 10) continue;
      const common = {
        "#{이름}": t.name,
        "#{문서명}": doc.title,
        "#{서명링크}": `${base}?s=${t.sign_token}`,   // 본문용 (SMS 대체발송에도 링크가 남도록)
        "#{서명토큰}": t.sign_token,                  // 버튼 URL 의 변수 부분
      };
      const vars: Record<string, string> =
        kind === "request" ? { ...common, "#{요청자}": doc.requester_name, "#{기한}": fmtDate(doc.deadline),
                               "#{서명자목록}": allSigners }
        : kind === "remind" ? { ...common, "#{남은기간}": remainText(doc.deadline), "#{기한}": fmtDate(doc.deadline) }
        : { ...common, "#{완료일시}": fmtDate(doc.completed_at), "#{서명자목록}": doc.signer_names ?? t.name };
      rows.push({ org_id: doc.org_id, doc_id: doc.id, phone: t.phone, vars });
    }
  }
  return { rows, notFound };
}

// 발송 + 기록. 키가 없으면 기록만 남긴다.
export async function sendRows(admin: SupabaseClient, kind: Kind, rows: Row[]) {
  const templateId = env(TEMPLATE_ENV[kind]);
  const ready = providerReady() && !!templateId;

  const logBase = (status: string, error: string | null, response: unknown) =>
    rows.map((r) => ({
      org_id: r.org_id, document_id: r.doc_id, kind,
      template_id: templateId || null, to_phone: r.phone, variables: r.vars,
      status, error, response,
      sent_at: status === "sent" ? new Date().toISOString() : null,
    }));

  if (!rows.length) return { ok: true, sent: 0, skipped: 0 };

  if (!ready) {
    await admin.rpc("esign_alimtalk_log", { p_rows: logBase("skipped", "PROVIDER_NOT_CONFIGURED", null) });
    return { ok: true, sent: 0, skipped: rows.length };
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
  return { ok: !failed, sent: failed ? 0 : rows.length, skipped: 0, result };
}
