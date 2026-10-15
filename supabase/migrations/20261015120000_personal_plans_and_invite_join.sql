-- ============================================================
-- 개인 요금제 · 조직 요금제 분리 + 초대 코드로 가입하면 바로 팀 합류
--
-- 1) plans.audience  : 'personal'(1명, 초대 불가) | 'org'(조직장이 결제, 팀원 초대)
--    개인 요금제 3종 추가 (초안 가격 — 운영하면서 이 테이블 값만 바꾸면 화면에 그대로 반영된다)
-- 2) organizations.kind : 'personal' | 'org'. 결제가 확정될 때 요금제의 audience 로 맞춘다
-- 3) 초대 코드로 합류하면 플랫폼 관리자 승인 없이 바로 이용 (조직장이 이미 결제했으므로)
--    · 가입 화면 · 승인 대기 화면 · ?invite=코드 링크 어디서든 합류할 수 있다
--    · 기존 버그 수정: 초대 코드 생성이 gen_random_bytes 를 찾지 못해 항상 실패하던 문제
--    · 기존 버그 수정: 초대를 받아들일 때 그 초대 자신을 자리 수에 한 번 더 세어
--      마지막 한 자리를 초대받은 사람이 SEAT_LIMIT 으로 막히던 문제
-- ============================================================

alter table esign.plans add column if not exists audience text not null default 'org';
do $$ begin
  alter table esign.plans add constraint plans_audience_check check (audience in ('personal','org'));
exception when duplicate_object then null; end $$;

alter table esign.organizations add column if not exists kind text not null default 'org';
do $$ begin
  alter table esign.organizations add constraint organizations_kind_check check (kind in ('personal','org'));
exception when duplicate_object then null; end $$;

insert into esign.plans
  (code, name, description, audience, price_monthly, price_yearly,
   doc_quota_monthly, doc_quota_yearly, seat_quota, overage_price, sort_order, is_active)
values
  ('personal_lite',  '개인 라이트', '가끔 계약서 · 동의서를 보내는 개인',      'personal', 3900, 39000, 10, 120, 1, 300, 11, true),
  ('personal_basic', '개인 베이직', '매달 꾸준히 서명을 받는 프리랜서 · 강사', 'personal', 5900, 59000, 30, 360, 1, 250, 12, true),
  ('personal_pro',   '개인 프로',   '발송이 많은 1인 사업자',                  'personal', 9900, 99000, 80, 960, 1, 200, 13, true)
on conflict (code) do nothing;


-- 결제 화면 설정: 요금제에 audience, 내 조직 상태를 함께 준다
create or replace function public.esign_pay_config()
returns jsonb language plpgsql stable security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
declare v_key text; v_org esign.organizations%rowtype; v_members int := 0; v_role text;
begin
  if auth.uid() is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED'); end if;
  select value into v_key from esign.app_settings where key = 'toss_client_key';
  select o.* into v_org from esign.organizations o where o.id = esign.my_org_id(auth.uid());
  if found then
    select count(*) into v_members from esign.memberships where org_id = v_org.id and status = 'active';
    v_role := esign.my_org_role(auth.uid());
  end if;
  return jsonb_build_object('ok', true,
    'card', v_key is not null,
    'client_key', v_key,
    'transfer', (select count(*) = 3 from esign.app_settings
                  where key in ('bank_name','bank_account','bank_holder') and value is not null),
    'org', case when v_org.id is null then null else jsonb_build_object(
             'name', v_org.name, 'kind', v_org.kind, 'members', v_members, 'my_role', v_role,
             'plan_code', v_org.plan_code, 'status', v_org.status) end,
    'plans', coalesce((select jsonb_agg(jsonb_build_object(
                'code', code, 'name', name, 'description', description, 'audience', audience,
                'price_monthly', price_monthly, 'price_yearly', price_yearly,
                'doc_quota_monthly', doc_quota_monthly, 'doc_quota_yearly', doc_quota_yearly,
                'seat_quota', seat_quota, 'overage_price', overage_price)
                order by audience desc, sort_order)
              from esign.plans where is_active and code <> 'free_trial'), '[]'::jsonb));
end $$;


-- 결제 신청: 개인 요금제는 조직 이름이 필요 없고, 팀원이 있는 조직은 개인 요금제로 바꿀 수 없다
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
  v_name   text;
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
    -- 개인 요금제는 내 이름으로, 조직 요금제는 입력한 조직 이름으로 만든다
    v_name := case when v_plan.audience = 'personal'
                   then coalesce(nullif(btrim(v_prof.name),''), nullif(btrim(p_org_name),''), '개인')
                   else nullif(btrim(p_org_name),'') end;
    if v_name is null then return jsonb_build_object('ok',false,'error','NO_ORG'); end if;
    v_res := public.esign_org_create(v_name, null, null);
    if not coalesce((v_res->>'ok')::boolean, false) then return v_res; end if;
    v_org := (v_res->>'org_id')::uuid;
    update esign.organizations set kind = v_plan.audience where id = v_org;
  end if;
  if esign.my_org_role(v_uid) <> 'owner' then
    return jsonb_build_object('ok',false,'error','OWNER_ONLY');
  end if;
  if v_plan.audience = 'personal' and (
       (select count(*) from esign.memberships where org_id = v_org and status = 'active') > 1
    or exists (select 1 from esign.org_invites where org_id = v_org and status = 'pending')) then
    return jsonb_build_object('ok',false,'error','PERSONAL_HAS_MEMBERS');
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


-- 결제 확정 시 조직 종류를 요금제에 맞춘다 (개인 → 조직 요금제로 올리면 팀원 초대가 열린다)
create or replace function esign.sync_org_kind_on_plan()
returns trigger language plpgsql security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
begin
  if new.plan_code is distinct from old.plan_code then
    select coalesce((select audience from esign.plans where code = new.plan_code
                      and code <> 'free_trial'), new.kind) into new.kind;
  end if;
  return new;
end $$;

do $$ begin
  create trigger trg_sync_org_kind before update of plan_code on esign.organizations
    for each row execute function esign.sync_org_kind_on_plan();
exception when duplicate_object then null; end $$;


-- 팀원 초대: 개인 요금제 조직은 초대할 수 없다
create or replace function public.esign_org_invite(p_name text, p_email text, p_phone text, p_role text default 'member')
returns jsonb language plpgsql security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
declare v_org uuid; v_code text; v_id uuid;
begin
  if auth.uid() is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED'); end if;
  v_org := esign.my_org_id(auth.uid());
  if v_org is null then return jsonb_build_object('ok',false,'error','NO_ORG'); end if;
  if esign.my_org_role(auth.uid()) not in ('owner','admin') then
    return jsonb_build_object('ok',false,'error','FORBIDDEN');
  end if;
  if (select kind from esign.organizations where id = v_org) = 'personal' then
    return jsonb_build_object('ok',false,'error','PERSONAL_PLAN');
  end if;
  if p_role not in ('admin','member') then
    return jsonb_build_object('ok',false,'error','BAD_ROLE');
  end if;
  if not esign.seat_available(v_org) then
    return jsonb_build_object('ok',false,'error','SEAT_LIMIT');
  end if;

  -- gen_random_bytes 는 extensions 스키마에 있다 (기존 함수는 search_path 에 없어 초대가 항상 실패했다)
  v_code := upper(encode(extensions.gen_random_bytes(6),'hex'));

  insert into esign.org_invites (org_id, name, email, phone, role, code, invited_by)
  values (v_org, nullif(btrim(p_name),''), nullif(btrim(p_email),''),
          nullif(btrim(p_phone),''), p_role, v_code, auth.uid())
  returning id into v_id;

  return jsonb_build_object('ok',true,'id',v_id,'code',v_code,
    'org_name', (select name from esign.organizations where id = v_org));
end $$;


-- 초대 코드 미리보기 — 가입 전(로그인 전)에도 「○○ 팀으로 초대되었습니다」를 보여 준다
create or replace function public.esign_invite_peek(p_code text)
returns jsonb language plpgsql stable security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
declare v_inv esign.org_invites%rowtype; v_org esign.organizations%rowtype;
begin
  select * into v_inv from esign.org_invites where code = upper(btrim(coalesce(p_code,'')));
  if not found then return jsonb_build_object('ok',false,'error','INVALID_CODE'); end if;
  if v_inv.status <> 'pending' then return jsonb_build_object('ok',false,'error','USED'); end if;
  if v_inv.expires_at < now() then return jsonb_build_object('ok',false,'error','EXPIRED'); end if;
  select * into v_org from esign.organizations where id = v_inv.org_id;
  return jsonb_build_object('ok', true, 'org_name', v_org.name, 'role', v_inv.role,
    'invitee', v_inv.name, 'expires_at', v_inv.expires_at,
    'org_active', v_org.status in ('active','trial') and v_org.purge_at is null);
end $$;


-- 초대 수락: 승인 대기 회원도 바로 합류 + 가입 승인
create or replace function public.esign_org_accept_invite(p_code text)
returns jsonb language plpgsql security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
declare
  v_uid  uuid := auth.uid();
  v_inv  esign.org_invites%rowtype;
  v_org  esign.organizations%rowtype;
  v_prof esign.profiles%rowtype;
  v_cur  uuid;
  v_quota int;
  v_used  int;
  v_approved boolean := false;
begin
  if v_uid is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED'); end if;
  select * into v_prof from esign.profiles where user_id = v_uid;
  if not found or v_prof.status not in ('pending','active') then
    return jsonb_build_object('ok',false,'error','FORBIDDEN');
  end if;

  select * into v_inv from esign.org_invites
   where code = upper(btrim(coalesce(p_code,''))) and status = 'pending' for update;
  if not found then return jsonb_build_object('ok',false,'error','INVALID_CODE'); end if;
  if v_inv.expires_at < now() then
    update esign.org_invites set status='expired' where id = v_inv.id;
    return jsonb_build_object('ok',false,'error','EXPIRED');
  end if;

  select * into v_org from esign.organizations where id = v_inv.org_id;
  if v_org.status not in ('active','trial') or v_org.purge_at is not null then
    return jsonb_build_object('ok',false,'error','ORG_INACTIVE');
  end if;

  -- 이미 다른 조직에 속해 있으면 막는다 (혼자 쓰는 체험 · 개인 조직이라도 문서가 섞이지 않도록)
  v_cur := esign.my_org_id(v_uid);
  if v_cur is not null and v_cur <> v_inv.org_id then
    return jsonb_build_object('ok',false,'error','ALREADY_IN_ORG');
  end if;

  -- 자리 확인 — 지금 받아들이는 이 초대는 대기 초대 수에서 뺀다
  select pl.seat_quota into v_quota from esign.plans pl where pl.code = v_org.plan_code;
  select (select count(*) from esign.memberships m
           where m.org_id = v_org.id and m.status in ('active','invited') and m.user_id <> v_uid)
       + (select count(*) from esign.org_invites i
           where i.org_id = v_org.id and i.status = 'pending' and i.id <> v_inv.id)
    into v_used;
  if v_quota is not null and v_used + 1 > v_quota then
    return jsonb_build_object('ok',false,'error','SEAT_LIMIT');
  end if;

  insert into esign.memberships (org_id, user_id, role, status, invited_by, invited_at)
  values (v_inv.org_id, v_uid, v_inv.role, 'active', v_inv.invited_by, v_inv.created_at)
  on conflict (org_id, user_id) do update set status='active', role=excluded.role;

  update esign.org_invites
     set status='accepted', accepted_by=v_uid, accepted_at=now()
   where id = v_inv.id;

  -- 조직장이 초대한 사람은 플랫폼 관리자 승인 없이 바로 이용
  update esign.profiles
     set current_org_id = v_inv.org_id,
         status = case when status = 'pending' then 'active' else status end,
         approved_at = case when status = 'pending' then now() else approved_at end,
         approved_by = case when status = 'pending' then v_inv.invited_by else approved_by end
   where user_id = v_uid;
  v_approved := v_prof.status = 'pending';

  -- 내 문서가 있다면 합류한 조직으로 귀속
  update esign.documents set org_id = v_inv.org_id where owner_id = v_uid and org_id is null;

  return jsonb_build_object('ok', true, 'org_id', v_inv.org_id, 'org_name', v_org.name,
                            'role', v_inv.role, 'approved', v_approved);
end $$;


-- 내 조직 정보에 kind · audience 추가 (화면에서 개인/조직을 구분)
create or replace function public.esign_my_org()
returns jsonb language plpgsql security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
declare
  v_org   esign.organizations%rowtype;
  v_plan  esign.plans%rowtype;
  v_role  text;
  v_used  integer := 0;
  v_quota integer;
  v_seats integer;
  v_period text;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'AUTH_REQUIRED');
  end if;

  select o.* into v_org
    from esign.organizations o
    join esign.memberships m on m.org_id = o.id
   where m.user_id = auth.uid() and m.status = 'active'
   order by case when m.role = 'owner' then 0 when m.role = 'admin' then 1 else 2 end
   limit 1;

  if not found then
    return jsonb_build_object('ok', true, 'has_org', false);
  end if;

  select role into v_role from esign.memberships
   where org_id = v_org.id and user_id = auth.uid();

  select * into v_plan from esign.plans where code = v_org.plan_code;

  v_period := esign.period_label(v_org.id);
  select coalesce(doc_count, 0) into v_used
    from esign.usage_counters where org_id = v_org.id and period = v_period;
  v_used := coalesce(v_used, 0);

  v_quota := case when v_org.billing_cycle = 'yearly'
                  then v_plan.doc_quota_yearly else v_plan.doc_quota_monthly end;

  select count(*) into v_seats from esign.memberships
   where org_id = v_org.id and status = 'active';

  return jsonb_build_object(
    'ok', true,
    'has_org', true,
    'org', jsonb_build_object(
      'id', v_org.id, 'name', v_org.name, 'biz_no', v_org.biz_no,
      'biz_type', v_org.biz_type, 'status', v_org.status, 'kind', v_org.kind,
      'billing_cycle', v_org.billing_cycle,
      'trial_ends_at', v_org.trial_ends_at,
      'period_start', v_org.period_start, 'period_end', v_org.period_end),
    'my_role', v_role,
    'plan', jsonb_build_object(
      'code', v_plan.code, 'name', v_plan.name, 'audience', v_plan.audience,
      'price_monthly', v_plan.price_monthly, 'price_yearly', v_plan.price_yearly,
      'overage_price', v_plan.overage_price),
    'usage', jsonb_build_object(
      'period', v_period, 'used', v_used, 'quota', v_quota,
      'remaining', case when v_quota is null then null else greatest(v_quota - v_used, 0) end,
      'over', case when v_quota is null then 0 else greatest(v_used - v_quota, 0) end),
    'seats', jsonb_build_object('used', v_seats, 'quota', v_plan.seat_quota),
    'retention', jsonb_build_object(
      'purge_at', v_org.purge_at,
      'purged_at', v_org.purged_at,
      'in_grace', (v_org.purge_at is not null and v_org.purged_at is null),
      'days_left', case when v_org.purge_at is null then null
                        else greatest(0, extract(day from v_org.purge_at - now())::int) end)
  );
end $$;


revoke all on function public.esign_invite_peek(text) from public;
grant execute on function public.esign_invite_peek(text) to anon, authenticated, service_role;
revoke all on function public.esign_org_accept_invite(text) from public, anon;
grant execute on function public.esign_org_accept_invite(text) to authenticated, service_role;
revoke all on function public.esign_org_invite(text, text, text, text) from public, anon;
grant execute on function public.esign_org_invite(text, text, text, text) to authenticated, service_role;
revoke all on function public.esign_my_org() from public, anon;
grant execute on function public.esign_my_org() to authenticated, service_role;
revoke all on function public.esign_pay_config() from public, anon;
grant execute on function public.esign_pay_config() to authenticated, service_role;
revoke all on function public.esign_request_payment_v2(text, text, text, text, text, text) from public, anon;
grant execute on function public.esign_request_payment_v2(text, text, text, text, text, text) to authenticated, service_role;
revoke all on function esign.sync_org_kind_on_plan() from public, anon, authenticated;
