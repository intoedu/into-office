// ============================================================
// 카카오 알림톡 공통 모듈 (솔라피)
//
// esign-notify(관리자 화면에서 호출)와 esign-sign(마지막 서명 시 완료 통지)이
// 함께 쓴다. 변수 이름은 docs/알림톡-템플릿-초안.md 의 등록 템플릿과
// 한 글자도 다르지 않아야 한다 — 다르면 솔라피가 발송을 거절한다.
//
// SOLAPI_* 키나 템플릿 코드가 없으면 실제 발송 없이 status='skipped' 로 기록만 남긴다.
// ============================================================
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.47.10";

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

// 붙여 넣을 때 딸려 온 앞뒤 공백 · 줄바꿈 때문에 서명(HMAC)이 틀어지지 않게 다듬는다
const env = (k: string) => (Deno.env.get(k) ?? "").trim();

// ---------- 외국어 알림톡 ----------
// 서명자 언어(esign.signers.lang)에 맞는 템플릿이 등록돼 있으면 그 템플릿으로 보낸다.
//   ALIMTALK_TPL_REQUEST_EN · ALIMTALK_TPL_REMIND_ZH · ALIMTALK_TPL_DONE_JA … (docs/알림톡-외국어-템플릿.md)
// 값이 없는 언어는 한국어 템플릿으로 간다. 변수 이름은 한국어 템플릿과 같다.
export type Lang = "ko" | "en" | "zh" | "ja" | "vi";
const LANGS: Lang[] = ["ko", "en", "zh", "ja", "vi"];
const LOCALE: Record<Lang, string> = { ko: "ko-KR", en: "en-US", zh: "zh-CN", ja: "ja-JP", vi: "vi-VN" };
const T: Record<Exclude<Lang, "ko">, Record<string, string>> = {
  en: { none: "Not set", noDeadline: "No deadline", passed: "Deadline passed", days: "{n} day(s)", hours: "{n} hour(s)", line: "· {name} (ending {tail})" },
  zh: { none: "未指定", noDeadline: "无期限", passed: "已过期限", days: "{n}天", hours: "{n}小时", line: "· {name}（尾号 {tail}）" },
  ja: { none: "未指定", noDeadline: "期限なし", passed: "期限切れ", days: "{n}日", hours: "{n}時間", line: "· {name} 様（末尾 {tail}）" },
  vi: { none: "Chưa đặt", noDeadline: "Không có thời hạn", passed: "Đã quá hạn", days: "{n} ngày", hours: "{n} giờ", line: "· {name} (số cuối {tail})" },
};
const fill = (t: string, v: Record<string, string | number>) =>
  Object.entries(v).reduce((a, [k, x]) => a.split(`{${k}}`).join(String(x)), t);
const asLang = (l: unknown): Lang => (LANGS.includes(l as Lang) ? l as Lang : "ko");

// 이 종류 · 언어로 보낼 템플릿 ID (외국어 템플릿이 없으면 한국어)
export function templateFor(kind: Kind, lang: Lang = "ko"): { id: string; lang: Lang } {
  if (lang !== "ko") {
    const id = env(`${TEMPLATE_ENV[kind]}_${lang.toUpperCase()}`);
    if (id) return { id, lang };
  }
  return { id: env(TEMPLATE_ENV[kind]), lang: "ko" };
}

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

export const fmtDate = (v: string | null | undefined, lang: Lang = "ko") =>
  v ? new Date(v).toLocaleString(LOCALE[lang], { timeZone: "Asia/Seoul", dateStyle: "long", timeStyle: "short" })
    : (lang === "ko" ? "미지정" : T[lang].none);

export const digits = (p: string) => (p ?? "").replace(/[^0-9]/g, "");

// 서명 기한까지 남은 기간 — 리마인드 템플릿의 #{남은기간}
export function remainText(deadline: string | null | undefined, lang: Lang = "ko"): string {
  const t = lang === "ko" ? null : T[lang];
  if (!deadline) return t ? t.noDeadline : "기한 없음";
  const ms = new Date(deadline).getTime() - Date.now();
  if (ms <= 0) return t ? t.passed : "기한 경과";
  const days = Math.floor(ms / 86_400_000);
  if (days >= 1) return t ? fill(t.days, { n: days }) : `${days}일`;
  const hours = Math.max(1, Math.floor(ms / 3_600_000));
  return t ? fill(t.hours, { n: hours }) : `${hours}시간`;
}

// 휴대폰 끝 4자리만 남긴다 (010-1234-5678 → 5678)
export function phoneTail(p: string): string {
  const d = digits(p);
  return d.length >= 4 ? d.slice(-4) : "****";
}

// 서명 요청 · 완료 템플릿의 #{서명자목록} — 함께 서명하는 사람 전원 (줄바꿈으로 구분)
//   · 홍길동 님 (끝자리 1234)
//   · 김철수 님 (끝자리 5678)
function signerLines(targets: Array<{ name: string; phone: string }>, lang: Lang = "ko"): string {
  return targets.map((t) => lang === "ko"
    ? `· ${t.name} 님 (끝자리 ${phoneTail(t.phone)})`
    : fill(T[lang].line, { name: t.name, tail: phoneTail(t.phone) })).join("\n");
}

export type Row = {
  org_id: string | null;
  doc_id: string | null;
  phone: string;
  vars: Record<string, string>;
  template_id?: string;   // 없으면 그 종류의 한국어 템플릿
  lang?: Lang;
};

// 가입 승인 안내 1건 — esign_member_notify_info 결과로 만든다. 연락처가 없으면 null.
export async function approveRow(admin: SupabaseClient, userId: string): Promise<Row | null> {
  const { data: m } = await admin.rpc("esign_member_notify_info", { p_user_id: userId });
  if (!m?.ok || m.status !== "active" || digits(m.phone ?? "").length < 10) return null;
  return {
    org_id: null, doc_id: null, phone: m.phone,
    vars: {
      "#{이름}": m.name || "회원",
      "#{아이디}": m.username || m.email || "-",
      "#{승인일시}": fmtDate(m.approved_at),
    },
  };
}

// 문서 기반 발송(요청 · 리마인드 · 완료)의 수신자와 변수를 만든다
export async function collectDocRows(admin: SupabaseClient, kind: Kind, ids: string[]) {
  const rows: Row[] = [];
  const notFound: string[] = [];
  const base = serviceBase();

  for (const id of ids) {
    const { data: info } = await admin.rpc("esign_notify_targets", { p_kind: kind, p_document_id: id });
    if (!info?.ok) { notFound.push(id); continue; }

    // 서명자 언어 { sign_token: lang } — 함수가 없거나 실패하면 모두 한국어
    let langs: Record<string, string> = {};
    try {
      const { data: l, error } = await admin.rpc("esign_signer_langs", { p_document_id: id });
      if (!error && l && typeof l === "object") langs = l as Record<string, string>;
    } catch { /* 한국어로 */ }

    const doc = info.document;
    // 서명 요청 시점(아직 아무도 서명 안 함)과 완료 통지(kind=done)에는 targets 가 곧 서명자 전원이다
    const listCache: Partial<Record<Lang, string>> = {};
    const allSigners = (lang: Lang) => (kind === "request" || kind === "done")
      ? (listCache[lang] ??= signerLines(info.targets ?? [], lang)) : "";
    for (const t of info.targets ?? []) {
      if (digits(t.phone).length < 10) continue;
      // 그 언어 템플릿이 등록돼 있을 때만 외국어로 (아니면 한국어 문구 · 한국어 템플릿)
      const tpl = templateFor(kind, asLang(langs[t.sign_token]));
      const lang = tpl.lang;
      const common = {
        "#{이름}": t.name,
        "#{문서명}": doc.title,
        // 본문용 (SMS 대체발송에도 링크가 남도록). 외국어는 서명 화면도 그 언어로 열리게 lang 을 붙인다
        "#{서명링크}": `${base}?s=${t.sign_token}` + (lang === "ko" ? "" : `&lang=${lang}`),
        "#{서명토큰}": t.sign_token,                  // 버튼 URL 의 변수 부분
      };
      const vars: Record<string, string> =
        kind === "request" ? { ...common, "#{요청자}": doc.requester_name, "#{기한}": fmtDate(doc.deadline, lang),
                               "#{서명자목록}": allSigners(lang) }
        : kind === "remind" ? { ...common, "#{남은기간}": remainText(doc.deadline, lang), "#{기한}": fmtDate(doc.deadline, lang) }
        : { ...common, "#{완료일시}": fmtDate(doc.completed_at, lang), "#{서명자목록}": allSigners(lang) || doc.signer_names || t.name };
      rows.push({ org_id: doc.org_id, doc_id: doc.id, phone: t.phone, vars, template_id: tpl.id, lang });
    }
  }
  return { rows, notFound };
}

// 발송 + 기록. 템플릿(언어)별로 나눠 보낸다.
export async function sendRows(admin: SupabaseClient, kind: Kind, rows: Row[]) {
  if (!rows.length) return { ok: true, sent: 0, skipped: 0 };
  const groups = new Map<string, Row[]>();
  for (const r of rows) {
    const id = r.template_id ?? env(TEMPLATE_ENV[kind]);
    groups.set(id, [...(groups.get(id) ?? []), r]);
  }
  if (groups.size === 1) {
    const [[id, list]] = [...groups];
    return sendGroup(admin, kind, id, list);
  }
  let ok = true, sent = 0, skipped = 0;
  const results: unknown[] = [];
  for (const [id, list] of groups) {
    const r = await sendGroup(admin, kind, id, list);
    ok = ok && r.ok; sent += r.sent; skipped += r.skipped;
    results.push((r as { result?: unknown }).result ?? null);
  }
  return { ok, sent, skipped, result: { groups: results } };
}

// 한 템플릿으로 묶인 발송 + 기록. 키가 없으면 기록만 남긴다.
async function sendGroup(admin: SupabaseClient, kind: Kind, templateId: string, rows: Row[]) {
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
