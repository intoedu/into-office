-- ============================================================
-- 결제하면 가입이 바로 승인된다
--
-- · 승인 대기 회원도 대기 화면에서 조직을 만들고 유료 요금제를 결제할 수 있다
-- · 무통장: 관리자가 「입금 확인」을 누르는 순간 구독 활성화 + 조직 소유자 가입 승인
-- · 카드(토스페이먼츠): esign-pay 함수가 결제 승인 API 로 확정하는 순간 같은 처리
-- · 무료 체험은 지금처럼 관리자 승인을 거친다
--
-- 함께 고친 버그: 결제 신청이 고른 요금제를 저장하지 않아, 입금 확인 때
-- 조직의 현재 요금제(free_trial)로 활성화되던 문제. 이제 결제 행에 요금제 · 주기를 남긴다.
-- ============================================================

alter table esign.payments
  add column if not exists plan_code      text,
  add column if not exists billing_cycle  text,
  add column if not exists pg_provider    text,
  add column if not exists pg_order_id    text,
  add column if not exists pg_payment_key text,
  add column if not exists pg_raw         jsonb;

do $$ begin
  alter table esign.payments add constraint payments_billing_cycle_check
    check (billing_cycle is null or billing_cycle in ('monthly','yearly'));
exception when duplicate_object then null; end $$;

create unique index if not exists uq_payments_pg_order_id
  on esign.payments (pg_order_id) where pg_order_id is not null;

-- 카드 결제용 공개 키 (토스페이먼츠 클라이언트 키). 시크릿 키는 Supabase Secrets(TOSS_SECRET_KEY)에만 둔다.
insert into esign.app_settings (key, value, label)
values ('toss_client_key', null, '토스페이먼츠 클라이언트 키 (카드 결제)')
on conflict (key) do nothing;


-- ------------------------------------------------------------
-- 결제 확정 공통 처리 (관리자 입금 확인 · 카드 결제 승인이 함께 쓴다)
-- ------------------------------------------------------------
create or replace function esign.confirm_payment_core(p_payment_id uuid, p_by uuid)
returns jsonb language plpgsql security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
declare
  v_pay      esign.payments%rowtype;
  v_org      esign.organizations%rowtype;
  v_plan     text;
  v_cycle    text;
  v_start    timestamptz;
  v_end      timestamptz;
  v_sub      uuid;
  v_approved uuid[];
begin
  select * into v_pay from esign.payments where id = p_payment_id for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'NOT_FOUND'); end if;
  if v_pay.status = 'confirmed' then
    return jsonb_build_object('ok', false, 'error', 'ALREADY_CONFIRMED');
  end if;

  select * into v_org from esign.organizations where id = v_pay.org_id for update;

  -- 결제 행에 남긴 요금제가 우선. 예전 행은 조직의 유료 요금제로 대신한다.
  v_plan  := coalesce(v_pay.plan_code, nullif(v_org.plan_code, 'free_trial'));
  v_cycle := coalesce(v_pay.billing_cycle, v_org.billing_cycle, 'monthly');
  if v_plan is null then
    return jsonb_build_object('ok', false, 'error', 'PLAN_UNKNOWN');
  end if;

  -- 유예 중이던 조직이면 삭제 예약을 취소하고 되살린다
  if v_org.purge_at is not null and v_org.purged_at is null then
    perform esign.retention_cancel(v_org.id, '결제 확인에 따른 복구');
  end if;

  v_start := greatest(coalesce(v_org.period_end, now()), now());
  v_end   := v_start + case when v_cycle = 'yearly' then interval '1 year' else interval '1 month' end;

  insert into esign.subscriptions (org_id, plan_code, billing_cycle, period_start, period_end, amount, status)
  values (v_org.id, v_plan, v_cycle, v_start, v_end, v_pay.amount, 'active')
  returning id into v_sub;

  update esign.payments
     set status = 'confirmed', confirmed_by = p_by, confirmed_at = now(),
         received_at = coalesce(received_at, now()),
         plan_code = v_plan, billing_cycle = v_cycle, subscription_id = v_sub
   where id = p_payment_id;

  update esign.organizations
     set plan_code = v_plan, billing_cycle = v_cycle, status = 'active',
         period_start = v_start, period_end = v_end, updated_at = now()
   where id = v_org.id;

  -- 같은 조직의 다른 대기 결제(무통장 신청 · 끝내지 않은 카드 결제)는 이번 결제로 대체
  update esign.payments
     set status = 'rejected', memo = coalesce(memo, '') || ' (다른 결제로 대체)'
   where org_id = v_org.id and status = 'pending' and id <> p_payment_id;

  -- 결제한 조직의 소유자가 아직 승인 대기면 바로 승인 (거절 · 정지는 건드리지 않는다)
  with up as (
    update esign.profiles pr
       set status = 'active', approved_at = now(), approved_by = p_by, reject_reason = null
     where pr.status = 'pending'
       and pr.user_id in (select m.user_id from esign.memberships m
                           where m.org_id = v_org.id and m.role = 'owner' and m.status = 'active')
    returning pr.user_id)
  select coalesce(array_agg(user_id), '{}') into v_approved from up;

  return jsonb_build_object('ok', true, 'subscription_id', v_sub,
    'plan_code', v_plan, 'billing_cycle', v_cycle,
    'period_start', v_start, 'period_end', v_end,
    'approved_user_ids', to_jsonb(v_approved));
end $$;

revoke all on function esign.confirm_payment_core(uuid, uuid) from public, anon, authenticated;
grant execute on function esign.confirm_payment_core(uuid, uuid) to service_role;


-- 관리자 입금 확인 — 기존 호출 형태 그대로. 이제 가입 승인까지 함께 한다.
create or replace function public.esign_admin_confirm_payment(
  p_payment_id uuid, p_plan_code text default null, p_cycle text default null)
returns jsonb language plpgsql security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
begin
  if not esign.is_platform_admin() then
    return jsonb_build_object('ok', false, 'error', 'FORBIDDEN');
  end if;
  if p_plan_code is not null or p_cycle is not null then
    update esign.payments
       set plan_code = coalesce(p_plan_code, plan_code),
           billing_cycle = coalesce(p_cycle, billing_cycle)
     where id = p_payment_id and status <> 'confirmed';
  end if;
  return esign.confirm_payment_core(p_payment_id, auth.uid());
end $$;


-- ------------------------------------------------------------
-- 결제 화면 설정: 요금제 목록 · 사용할 수 있는 결제 수단
-- 승인 대기 회원도 부른다 (대기 화면에서 결제)
-- ------------------------------------------------------------
create or replace function public.esign_pay_config()
returns jsonb language plpgsql stable security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
declare v_key text;
begin
  if auth.uid() is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED'); end if;
  select value into v_key from esign.app_settings where key = 'toss_client_key';
  return jsonb_build_object('ok', true,
    'card', v_key is not null,
    'client_key', v_key,
    'transfer', (select count(*) = 3 from esign.app_settings
                  where key in ('bank_name','bank_account','bank_holder') and value is not null),
    'plans', coalesce((select jsonb_agg(jsonb_build_object(
                'code', code, 'name', name, 'description', description,
                'price_monthly', price_monthly, 'price_yearly', price_yearly,
                'doc_quota_monthly', doc_quota_monthly, 'doc_quota_yearly', doc_quota_yearly,
                'seat_quota', seat_quota, 'overage_price', overage_price) order by sort_order)
              from esign.plans where is_active and code <> 'free_trial'), '[]'::jsonb));
end $$;


-- ------------------------------------------------------------
-- 결제 신청 (무통장 · 카드)
--   조직이 없으면 p_org_name 으로 만든다 (대기 화면에서 바로 결제하는 경우)
-- ------------------------------------------------------------
create or replace function public.esign_request_payment_v2(
  p_plan_code text, p_cycle text, p_method text,
  p_depositor_name text default null, p_receipt_type text default 'none',
  p_org_name text default null)
returns jsonb language plpgsql security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
declare
  v_uid    uuid := auth.uid();
  v_prof   esign.profiles%rowtype;
  v_org    uuid;
  v_plan   esign.plans%rowtype;
  v_amount int;
  v_id     uuid;
  v_order  text;
  v_res    jsonb;
  v_cycle_ko text;
begin
  if v_uid is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED'); end if;
  select * into v_prof from esign.profiles where user_id = v_uid;
  if not found or v_prof.status not in ('pending','active') then
    return jsonb_build_object('ok',false,'error','FORBIDDEN');
  end if;
  if p_method not in ('transfer','card') then
    return jsonb_build_object('ok',false,'error','BAD_METHOD');
  end if;
  if p_cycle not in ('monthly','yearly') then
    return jsonb_build_object('ok',false,'error','BAD_CYCLE');
  end if;
  select * into v_plan from esign.plans where code = p_plan_code and is_active;
  if not found or v_plan.code = 'free_trial' then
    return jsonb_build_object('ok',false,'error','BAD_PLAN');
  end if;
  if p_method = 'card' and not exists (select 1 from esign.app_settings
                                        where key = 'toss_client_key' and value is not null) then
    return jsonb_build_object('ok',false,'error','CARD_NOT_AVAILABLE');
  end if;
  if p_method = 'transfer' and coalesce(btrim(p_depositor_name),'') = '' then
    return jsonb_build_object('ok',false,'error','DEPOSITOR_REQUIRED');
  end if;

  v_org := esign.my_org_id(v_uid);
  if v_org is null then
    if coalesce(btrim(p_org_name),'') = '' then
      return jsonb_build_object('ok',false,'error','NO_ORG');
    end if;
    v_res := public.esign_org_create(p_org_name, null, null);
    if not coalesce((v_res->>'ok')::boolean, false) then return v_res; end if;
    v_org := (v_res->>'org_id')::uuid;
  end if;
  if esign.my_org_role(v_uid) <> 'owner' then
    return jsonb_build_object('ok',false,'error','OWNER_ONLY');
  end if;

  v_amount := case when p_cycle = 'yearly' then v_plan.price_yearly else v_plan.price_monthly end;
  v_cycle_ko := case when p_cycle = 'yearly' then '연 결제' else '월 결제' end;

  -- 끝내지 않은 카드 결제는 새 신청으로 대체
  update esign.payments set status = 'rejected', memo = coalesce(memo,'') || ' (미완료)'
   where org_id = v_org and status = 'pending' and method = 'card';

  if p_method = 'transfer' then
    if exists (select 1 from esign.payments where org_id = v_org and status = 'pending') then
      return jsonb_build_object('ok',false,'error','ALREADY_PENDING');
    end if;
    insert into esign.payments
      (org_id, method, amount, depositor_name, status, receipt_type, memo, plan_code, billing_cycle)
    values (v_org, 'transfer', v_amount, btrim(p_depositor_name), 'pending',
            coalesce(nullif(p_receipt_type,''),'none'),
            format('%s / %s', v_plan.name, v_cycle_ko), v_plan.code, p_cycle)
    returning id into v_id;
    return jsonb_build_object('ok', true, 'method', 'transfer', 'payment_id', v_id,
      'amount', v_amount, 'plan', v_plan.name, 'cycle', p_cycle);
  end if;

  -- 카드: 주문번호(영문 · 숫자 6~64자)를 만들어 결제창에 넘긴다
  v_order := 'IO' || replace(gen_random_uuid()::text, '-', '');
  insert into esign.payments
    (org_id, method, amount, status, receipt_type, memo, plan_code, billing_cycle, pg_provider, pg_order_id)
  values (v_org, 'card', v_amount, 'pending', 'none',
          format('%s / %s (카드)', v_plan.name, v_cycle_ko), v_plan.code, p_cycle, 'toss', v_order)
  returning id into v_id;

  return jsonb_build_object('ok', true, 'method', 'card', 'payment_id', v_id,
    'order_id', v_order, 'amount', v_amount, 'plan', v_plan.name, 'cycle', p_cycle,
    'order_name', format('인투오피스 %s (%s)', v_plan.name, v_cycle_ko),
    'customer_name', coalesce(v_prof.name, ''),
    'customer_email', nullif(v_prof.email, ''),
    'customer_phone', nullif(regexp_replace(coalesce(v_prof.phone,''), '[^0-9]', '', 'g'), ''),
    'client_key', (select value from esign.app_settings where key = 'toss_client_key'));
end $$;

-- 기존 무통장 신청 함수 — 요금제 · 주기를 남기도록 v2 로 넘긴다
create or replace function public.esign_request_payment(
  p_plan_code text, p_cycle text, p_depositor_name text, p_receipt_type text default 'none')
returns jsonb language sql security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
  select public.esign_request_payment_v2(p_plan_code, p_cycle, 'transfer', p_depositor_name, p_receipt_type, null);
$$;

-- 소유자가 자기 대기 결제를 취소 (요금제를 바꾸고 싶을 때 · 카드 결제창을 닫았을 때)
create or replace function public.esign_cancel_payment(p_payment_id uuid default null, p_order_id text default null)
returns jsonb language plpgsql security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
declare v_org uuid;
begin
  if auth.uid() is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED'); end if;
  v_org := esign.my_org_id(auth.uid());
  if v_org is null or esign.my_org_role(auth.uid()) <> 'owner' then
    return jsonb_build_object('ok',false,'error','OWNER_ONLY');
  end if;
  update esign.payments set status = 'rejected', memo = coalesce(memo,'') || ' (신청 취소)'
   where org_id = v_org and status = 'pending'
     and ((p_payment_id is not null and id = p_payment_id)
       or (p_order_id is not null and pg_order_id = p_order_id));
  if not found then return jsonb_build_object('ok',false,'error','NOT_FOUND'); end if;
  return jsonb_build_object('ok', true);
end $$;

-- 입금 안내: 무통장 대기 건만 본다
create or replace function public.esign_payment_info()
returns jsonb language plpgsql stable security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
declare v_org uuid; v_pending jsonb;
begin
  if auth.uid() is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED'); end if;
  v_org := esign.my_org_id(auth.uid());
  if v_org is null then return jsonb_build_object('ok',false,'error','NO_ORG'); end if;
  if esign.my_org_role(auth.uid()) <> 'owner' then
    return jsonb_build_object('ok',false,'error','OWNER_ONLY');
  end if;

  select jsonb_build_object('id', p.id, 'amount', p.amount, 'memo', p.memo,
                            'plan_code', p.plan_code, 'billing_cycle', p.billing_cycle,
                            'depositor_name', p.depositor_name, 'created_at', p.created_at)
    into v_pending
    from esign.payments p
   where p.org_id = v_org and p.status = 'pending' and p.method = 'transfer'
   order by p.created_at desc limit 1;

  if v_pending is null then
    return jsonb_build_object('ok', true, 'has_pending', false);
  end if;

  return jsonb_build_object('ok', true, 'has_pending', true, 'payment', v_pending,
    'bank',    (select value from esign.app_settings where key='bank_name'),
    'account', (select value from esign.app_settings where key='bank_account'),
    'holder',  (select value from esign.app_settings where key='bank_holder'),
    'notice',  (select value from esign.app_settings where key='pay_notice'),
    'configured', (select count(*) = 3 from esign.app_settings
                    where key in ('bank_name','bank_account','bank_holder') and value is not null));
end $$;

-- 내 결제 내역: 결제 수단 · 요금제도 보여준다. 끝내지 않은 카드 시도는 감춘다.
create or replace function public.esign_my_payments()
returns jsonb language plpgsql security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
declare v_org uuid;
begin
  v_org := esign.my_org_id(auth.uid());
  if v_org is null then return jsonb_build_object('ok',true,'has_org',false); end if;
  return jsonb_build_object('ok',true,'has_org',true,
    'payments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',p.id,'amount',p.amount,'status',p.status,'memo',p.memo,'method',p.method,
        'plan_code',p.plan_code,'billing_cycle',p.billing_cycle,
        'depositor_name',p.depositor_name,'created_at',p.created_at,
        'confirmed_at',p.confirmed_at,'receipt_type',p.receipt_type
      ) order by p.created_at desc)
      from esign.payments p
     where p.org_id = v_org
       and not (p.method = 'card' and p.status <> 'confirmed')), '[]'::jsonb));
end $$;

-- 관리자 결제 목록: 끝내지 않은 카드 시도는 빼고, 소유자 · 요금제 정보를 붙인다
create or replace function public.esign_admin_payments(p_status text default 'pending')
returns jsonb language plpgsql security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
declare v_rows jsonb;
begin
  if not esign.is_platform_admin() then
    return jsonb_build_object('ok', false, 'error', 'FORBIDDEN');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'org_id', p.org_id, 'org_name', o.name,
           'method', p.method, 'amount', p.amount,
           'plan_code', p.plan_code, 'billing_cycle', p.billing_cycle,
           'depositor_name', p.depositor_name, 'received_at', p.received_at,
           'status', p.status, 'receipt_type', p.receipt_type,
           'memo', p.memo, 'created_at', p.created_at,
           'has_pg_key', p.pg_payment_key is not null,
           'owner_name', ow.name, 'owner_status', ow.status
         ) order by p.created_at desc), '[]'::jsonb) into v_rows
    from esign.payments p
    join esign.organizations o on o.id = p.org_id
    left join lateral (
      select pr.name, pr.status from esign.memberships m
        join esign.profiles pr on pr.user_id = m.user_id
       where m.org_id = p.org_id and m.role = 'owner' limit 1) ow on true
   where (p_status is null or p.status = p_status)
     and not (p.method = 'card' and p.status = 'pending' and p.pg_payment_key is null);

  return jsonb_build_object('ok', true, 'payments', v_rows);
end $$;


-- ------------------------------------------------------------
-- 카드 결제 확정 (esign-pay Edge Function 이 서비스 롤로만 부른다)
-- ------------------------------------------------------------
-- 1) 결제 승인 API 를 부르기 전: 주인 · 금액 · 상태를 서버 기준으로 검증하고 paymentKey 를 남긴다
create or replace function public.esign_pay_card_begin(
  p_order_id text, p_user_id uuid, p_payment_key text, p_amount int)
returns jsonb language plpgsql security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
declare v_pay esign.payments%rowtype;
begin
  select * into v_pay from esign.payments where pg_order_id = p_order_id for update;
  if not found or v_pay.method <> 'card' then
    return jsonb_build_object('ok',false,'error','ORDER_NOT_FOUND');
  end if;
  if not exists (select 1 from esign.memberships
                  where org_id = v_pay.org_id and user_id = p_user_id
                    and role = 'owner' and status = 'active') then
    return jsonb_build_object('ok',false,'error','OWNER_ONLY');
  end if;
  if v_pay.status = 'confirmed' then
    return jsonb_build_object('ok',false,'error','ALREADY_CONFIRMED');
  end if;
  if v_pay.status <> 'pending' then
    return jsonb_build_object('ok',false,'error','ORDER_CLOSED');
  end if;
  if v_pay.amount <> p_amount then
    return jsonb_build_object('ok',false,'error','AMOUNT_MISMATCH');
  end if;
  update esign.payments set pg_payment_key = p_payment_key where id = v_pay.id;
  return jsonb_build_object('ok', true, 'payment_id', v_pay.id, 'amount', v_pay.amount);
end $$;

-- 2) 결제 승인 API 가 DONE 을 돌려준 뒤: 결제 확정 + 구독 활성화 + 가입 승인
create or replace function public.esign_pay_card_complete(p_order_id text, p_raw jsonb)
returns jsonb language plpgsql security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
declare v_id uuid;
begin
  select id into v_id from esign.payments where pg_order_id = p_order_id and method = 'card';
  if v_id is null then return jsonb_build_object('ok',false,'error','ORDER_NOT_FOUND'); end if;
  update esign.payments
     set pg_raw = p_raw,
         pg_payment_key = coalesce(p_raw->>'paymentKey', pg_payment_key),
         received_at = coalesce((p_raw->>'approvedAt')::timestamptz, now())
   where id = v_id;
  return esign.confirm_payment_core(v_id, null);
end $$;

-- 3) 결제 승인 API 가 거절했을 때: 기록만 남기고 닫는다 (돈은 빠져나가지 않은 상태)
create or replace function public.esign_pay_card_fail(p_order_id text, p_raw jsonb)
returns jsonb language plpgsql security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
begin
  update esign.payments
     set status = 'rejected', pg_raw = p_raw,
         memo = coalesce(memo,'') || ' (승인 실패: ' || coalesce(p_raw->>'code','?') || ')'
   where pg_order_id = p_order_id and method = 'card' and status = 'pending';
  return jsonb_build_object('ok', true);
end $$;


-- ------------------------------------------------------------
-- 권한
-- ------------------------------------------------------------
revoke all on function public.esign_pay_config() from public, anon;
revoke all on function public.esign_request_payment_v2(text, text, text, text, text, text) from public, anon;
revoke all on function public.esign_request_payment(text, text, text, text) from public, anon;
revoke all on function public.esign_cancel_payment(uuid, text) from public, anon;
revoke all on function public.esign_payment_info() from public, anon;
revoke all on function public.esign_my_payments() from public, anon;
revoke all on function public.esign_admin_payments(text) from public, anon;
revoke all on function public.esign_admin_confirm_payment(uuid, text, text) from public, anon;
grant execute on function public.esign_pay_config() to authenticated, service_role;
grant execute on function public.esign_request_payment_v2(text, text, text, text, text, text) to authenticated, service_role;
grant execute on function public.esign_request_payment(text, text, text, text) to authenticated, service_role;
grant execute on function public.esign_cancel_payment(uuid, text) to authenticated, service_role;
grant execute on function public.esign_payment_info() to authenticated, service_role;
grant execute on function public.esign_my_payments() to authenticated, service_role;
grant execute on function public.esign_admin_payments(text) to authenticated, service_role;
grant execute on function public.esign_admin_confirm_payment(uuid, text, text) to authenticated, service_role;

revoke all on function public.esign_pay_card_begin(text, uuid, text, int) from public, anon, authenticated;
revoke all on function public.esign_pay_card_complete(text, jsonb) from public, anon, authenticated;
revoke all on function public.esign_pay_card_fail(text, jsonb) from public, anon, authenticated;
grant execute on function public.esign_pay_card_begin(text, uuid, text, int) to service_role;
grant execute on function public.esign_pay_card_complete(text, jsonb) to service_role;
grant execute on function public.esign_pay_card_fail(text, jsonb) to service_role;
