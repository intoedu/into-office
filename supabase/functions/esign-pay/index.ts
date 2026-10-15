// ============================================================
// esign-pay · 카드 결제 확정 (토스페이먼츠)
//
// 결제창에서 돌아온 브라우저가 successUrl 의 paymentKey · orderId · amount 를 넘기면
//   1) esign_pay_card_begin   — 주문 주인 · 금액 · 상태를 DB 기준으로 검증 (금액 조작 차단)
//   2) 토스 결제 승인 API     — 시크릿 키로 결제를 실제로 확정
//   3) esign_pay_card_complete — 구독 활성화 + 승인 대기였던 소유자 가입 승인
//   4) 가입 승인 알림톡
//
// 시크릿 키: Supabase Secrets 의 TOSS_SECRET_KEY (테스트 키 test_sk_… / 실제 키 live_sk_…)
// 클라이언트 키는 관리자 화면(조직 · 입금 → 결제 설정)에 넣는다 — 둘은 같은 상점 · 같은 모드여야 한다.
// ============================================================
import { createClient } from "npm:@supabase/supabase-js@2.47.10";
import { approveRow, sendRows, type Row } from "../_shared/alimtalk.ts";

const TOSS_API = "https://api.tosspayments.com/v1/payments";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const env = (k: string) => Deno.env.get(k) ?? "";
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

const tossAuth = () => "Basic " + btoa(env("TOSS_SECRET_KEY") + ":");

async function tossConfirm(paymentKey: string, orderId: string, amount: number) {
  const res = await fetch(`${TOSS_API}/confirm`, {
    method: "POST",
    headers: { Authorization: tossAuth(), "Content-Type": "application/json", "Idempotency-Key": orderId },
    body: JSON.stringify({ paymentKey, orderId, amount }),
  });
  const body = await res.json().catch(() => ({ code: "BAD_RESPONSE", message: `HTTP ${res.status}` }));
  return { ok: res.ok, body };
}

// 이미 승인된 결제(새로고침 · 중복 호출)는 조회로 확인한다
async function tossGet(paymentKey: string) {
  const res = await fetch(`${TOSS_API}/${encodeURIComponent(paymentKey)}`, {
    headers: { Authorization: tossAuth() },
  });
  const body = await res.json().catch(() => ({}));
  return { ok: res.ok, body };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, error: "METHOD_NOT_ALLOWED" }, 405);

  let body: { paymentKey?: string; orderId?: string; amount?: number | string };
  try { body = await req.json(); } catch { return json({ ok: false, error: "BAD_JSON" }, 400); }

  const paymentKey = String(body.paymentKey ?? "");
  const orderId = String(body.orderId ?? "");
  const amount = Number(body.amount);
  if (!paymentKey || !orderId || !Number.isInteger(amount) || amount <= 0) {
    return json({ ok: false, error: "BAD_PARAMS" }, 400);
  }
  if (!env("TOSS_SECRET_KEY")) return json({ ok: false, error: "PG_NOT_CONFIGURED" }, 503);

  const authz = req.headers.get("Authorization") ?? "";
  const caller = createClient(env("SUPABASE_URL"), env("SUPABASE_ANON_KEY"), {
    global: { headers: { Authorization: authz } },
  });
  const { data: u } = await caller.auth.getUser();
  if (!u?.user) return json({ ok: false, error: "AUTH_REQUIRED" }, 401);

  const admin = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"));

  // 1) DB 기준 검증 — 금액은 브라우저 값이 아니라 결제 신청 때 저장한 값과 맞아야 한다
  const { data: begin } = await admin.rpc("esign_pay_card_begin", {
    p_order_id: orderId, p_user_id: u.user.id, p_payment_key: paymentKey, p_amount: amount,
  });
  if (begin?.error === "ALREADY_CONFIRMED") return json({ ok: true, already: true });
  if (!begin?.ok) return json({ ok: false, error: begin?.error ?? "BEGIN_FAILED" }, 400);

  // 2) 토스 결제 승인
  let paid: Record<string, unknown> | null = null;
  const c = await tossConfirm(paymentKey, orderId, amount);
  if (c.ok) {
    paid = c.body;
  } else if (c.body?.code === "ALREADY_PROCESSED_PAYMENT") {
    const g = await tossGet(paymentKey);
    if (g.ok) paid = g.body;
  }

  const valid = paid && paid.status === "DONE" && paid.orderId === orderId && Number(paid.totalAmount) === amount;
  if (!valid) {
    const raw = paid ?? c.body ?? {};
    await admin.rpc("esign_pay_card_fail", { p_order_id: orderId, p_raw: raw });
    return json({ ok: false, error: (raw as { code?: string }).code ?? "CONFIRM_FAILED",
                  message: (raw as { message?: string }).message ?? null }, 402);
  }

  // 3) 구독 활성화 + 가입 승인
  const { data: done } = await admin.rpc("esign_pay_card_complete", { p_order_id: orderId, p_raw: paid });
  if (!done?.ok && done?.error !== "ALREADY_CONFIRMED") {
    // 돈은 빠져나갔는데 활성화가 실패한 경우 — 관리자 화면 「입금 확인 대기」에 카드 건으로 남는다
    console.error("card complete failed", orderId, done);
    return json({ ok: false, error: "ACTIVATE_FAILED", paid: true }, 500);
  }

  // 4) 가입 승인 알림톡 (실패해도 결제 결과에는 영향 없음)
  const approved: string[] = done?.approved_user_ids ?? [];
  try {
    const rows = (await Promise.all(approved.map((id) => approveRow(admin, id)))).filter((r): r is Row => r !== null);
    if (rows.length) await sendRows(admin, "approve", rows);
  } catch (e) {
    console.error("approve alimtalk", e);
  }

  return json({ ok: true, plan_code: done?.plan_code, billing_cycle: done?.billing_cycle,
                period_end: done?.period_end, approved: approved.length > 0 });
});
