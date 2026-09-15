// ============================================================
// esign-retention · 보관 정책 마무리 작업
//
//  1. 영구 삭제된 문서의 스토리지 파일 정리
//  2. 삭제 예정 안내(D-30 / D-7 / D-1) 발송
//
// service_role 토큰으로만 호출할 수 있다. pg_cron 이 매일 호출한다.
//
// esign 스키마는 PostgREST 에 노출되어 있지 않다.
// purge_log / alimtalk_logs 접근은 public 래퍼를 통한다.
// ============================================================
import { createClient } from "jsr:@supabase/supabase-js@2";

const BUCKET = "esign-docs";
const PURGE_BATCH = 500;
const env = (k: string) => Deno.env.get(k) ?? "";

const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { "Content-Type": "application/json" } });

function isServiceRole(authz: string): boolean {
  try {
    const payload = JSON.parse(atob(authz.replace(/^Bearer\s+/i, "").split(".")[1]));
    return payload?.role === "service_role";
  } catch {
    return false;
  }
}

Deno.serve(async (req) => {
  if (!isServiceRole(req.headers.get("Authorization") ?? "")) {
    return json({ ok: false, error: "SERVICE_ROLE_ONLY" }, 403);
  }

  const admin = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"));
  const out: Record<string, unknown> = { ok: true, ran_at: new Date().toISOString() };

  // ---------- 1) 스토리지 정리 ----------
  const { data: pendingRes, error: pErr } = await admin.rpc("esign_purge_pending", { p_limit: PURGE_BATCH });
  if (pErr) return json({ ok: false, error: pErr.message }, 500);

  const pending = (pendingRes?.items ?? []) as Array<{
    id: string;
    file_path: string | null;
    signed_path: string | null;
  }>;

  let removed = 0;
  if (pending.length) {
    const paths = pending
      .flatMap((r) => [r.file_path, r.signed_path])
      .filter((p): p is string => !!p);

    if (paths.length) {
      // 100개씩 나누어 삭제
      for (let i = 0; i < paths.length; i += 100) {
        const { error } = await admin.storage.from(BUCKET).remove(paths.slice(i, i + 100));
        if (!error) removed += Math.min(100, paths.length - i);
      }
    }

    await admin.rpc("esign_purge_mark_cleared", { p_ids: pending.map((r) => r.id) });
  }
  out.storage = { rows: pending.length, files_removed: removed };

  // ---------- 2) 삭제 예정 안내 ----------
  const { data: due } = await admin.rpc("esign_notify_retention_due");
  const items = (due?.items ?? []) as Array<{
    event_id: string;
    org_id: string;
    org_name: string;
    kind: string;
    purge_at: string;
    doc_count: number;
    days_left: number;
    recipients: Array<{ name: string; phone: string }>;
  }>;

  const logs: Record<string, unknown>[] = [];
  for (const it of items) {
    for (const r of it.recipients ?? []) {
      logs.push({
        org_id: it.org_id,
        kind: "retention",
        to_phone: r.phone,
        status: "skipped",
        error: "PROVIDER_NOT_CONFIGURED",
        variables: {
          event_id: it.event_id,
          notice: it.kind,
          "#{이름}": r.name,
          "#{조직명}": it.org_name,
          "#{문서수}": String(it.doc_count ?? 0),
          "#{남은기간}": `${it.days_left}일`,
          "#{삭제예정일}": new Date(it.purge_at).toLocaleDateString("ko-KR", { timeZone: "Asia/Seoul" }),
        },
      });
    }
  }

  if (logs.length) {
    await admin.rpc("esign_alimtalk_log", { p_rows: logs });
  }
  out.retention_notices = { events: items.length, recipients: logs.length };

  return json(out);
});
