-- ============================================================================
-- INTO OFFICE — 구독 / 요금제 / 사용량 스키마
-- ============================================================================
--
-- ⚠️ 이 마이그레이션은 아직 운영 DB에 적용되지 않았습니다.
--    적용 전에 반드시 아래를 확인하세요.
--
--    1. billing.plans 의 가격·한도가 docs/02-요금제-설계.md 및
--       index.html 의 PLANS 상수와 일치하는지
--    2. 적용 직후에는 한도 강제(enforce_quota)가 꺼져 있습니다.
--       기존 이용자에게 영향이 없는 상태로 배포된 뒤, 구독 데이터를 채우고
--       충분히 확인한 다음 켜야 합니다. (파일 하단 "활성화 절차" 참고)
--
-- 적용 방법
--    supabase db push
--    또는 Supabase 대시보드 SQL Editor 에 붙여넣기
--
-- 설계 원칙
--    · 카드번호·CVC 는 절대 저장하지 않습니다. PG 가 발급한 빌링키 참조값만 보관합니다.
--    · 사용량은 별도 카운터가 아니라 esign.documents 를 직접 세어 계산합니다.
--      카운터 드리프트가 생기지 않고, 환불·삭제 시에도 값이 저절로 맞습니다.
--    · 모든 쓰기는 SECURITY DEFINER 함수 또는 service_role 을 통해서만 이루어집니다.
--      클라이언트는 publishable key 로 조회만 할 수 있습니다.
-- ============================================================================

create schema if not exists billing;

-- ---------------------------------------------------------------------------
-- 0. 약관 동의 기록 (기존 esign.profiles 확장)
--    privacy_agreed 는 이미 있으나, 이용약관 동의는 별도로 기록해야 합니다.
--    index.html 회원가입 화면에 [필수] 이용약관 동의 체크박스가 추가되었습니다.
-- ---------------------------------------------------------------------------
alter table esign.profiles add column if not exists terms_agreed     boolean not null default false;
alter table esign.profiles add column if not exists terms_agreed_at  timestamptz;

comment on column esign.profiles.terms_agreed is '이용약관 동의 여부 (필수)';

-- ---------------------------------------------------------------------------
-- 1. 요금제
-- ---------------------------------------------------------------------------
create table if not exists billing.plans (
  code               text primary key,
  name               text        not null,
  description        text,
  sort_order         integer     not null default 0,
  price_monthly      integer     not null default 0,   -- 월 결제 금액 (원, VAT 별도)
  price_yearly       integer,                          -- 연 결제 1년 총액 (원, VAT 별도). null = 연 결제 미지원
  monthly_doc_limit  integer,                          -- 월 서명요청 한도. null = 무제한
  max_users          integer,                          -- 조직 최대 인원. null = 무제한
  retention_days     integer,                          -- 문서 보관일수. null = 무제한
  features           jsonb       not null default '{}'::jsonb,
  is_public          boolean     not null default true, -- 요금 안내 페이지 노출 여부
  is_active          boolean     not null default true, -- 신규 가입 가능 여부
  created_at         timestamptz not null default now()
);

comment on table  billing.plans is '요금제 정의. index.html 의 PLANS 상수와 값을 일치시킬 것.';
comment on column billing.plans.monthly_doc_limit is 'null 이면 무제한. 0 이면 발송 불가.';

insert into billing.plans
  (code, name, description, sort_order, price_monthly, price_yearly,
   monthly_doc_limit, max_users, retention_days, features)
values
  ('free',      '무료',        '서비스를 먼저 써보고 싶은 분',            10,     0,       null,    3,    1,   30,
   '{"reminder":false,"kakao":false,"templates":0,"bulk_send":false,"student_history":false,"api":false}'::jsonb),
  ('starter',   '스타터',      '원장님 혼자 또는 소수가 쓰는 곳',          20, 19900,   191040,   30,    3,  365,
   '{"reminder":true,"kakao":true,"templates":3,"bulk_send":false,"student_history":false,"api":false}'::jsonb),
  ('business',  '비즈니스',    '계약이 꾸준히 오가는 학원·유학원',        30, 49900,   479040,  150,   10, 1095,
   '{"reminder":true,"kakao":true,"templates":null,"bulk_send":true,"student_history":true,"api":false}'::jsonb),
  ('enterprise','엔터프라이즈','규모가 크거나 시스템 연동이 필요한 곳',    40,     0,       null, null, null, null,
   '{"reminder":true,"kakao":true,"templates":null,"bulk_send":true,"student_history":true,"api":true,"quote_only":true}'::jsonb)
on conflict (code) do update set
  name              = excluded.name,
  description       = excluded.description,
  sort_order        = excluded.sort_order,
  price_monthly     = excluded.price_monthly,
  price_yearly      = excluded.price_yearly,
  monthly_doc_limit = excluded.monthly_doc_limit,
  max_users         = excluded.max_users,
  retention_days    = excluded.retention_days,
  features          = excluded.features;

-- ---------------------------------------------------------------------------
-- 2. 구독
-- ---------------------------------------------------------------------------
create table if not exists billing.subscriptions (
  id                    uuid        primary key default gen_random_uuid(),
  owner_id              uuid        not null unique references auth.users(id) on delete cascade,
  plan_code             text        not null references billing.plans(code),
  status                text        not null default 'active'
                                    check (status in ('active','past_due','canceled','paused')),
  billing_cycle         text        not null default 'monthly'
                                    check (billing_cycle in ('monthly','yearly')),
  current_period_start  timestamptz not null default date_trunc('month', now()),
  current_period_end    timestamptz not null default (date_trunc('month', now()) + interval '1 month'),
  cancel_at_period_end  boolean     not null default false,

  -- PG 연동 식별자. 카드번호·유효기간·CVC 는 절대 저장하지 않습니다.
  pg_provider           text,       -- 'tosspayments' | 'portone' 등
  pg_customer_key       text,
  billing_key_ref       text,       -- PG 가 발급한 빌링키. 유출 시 무단 결제가 가능하므로 취급 주의
  billing_key_issued_at timestamptz,

  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

create index if not exists subscriptions_plan_idx   on billing.subscriptions (plan_code);
create index if not exists subscriptions_status_idx on billing.subscriptions (status);

comment on column billing.subscriptions.billing_key_ref is
  'PG 발급 빌링키. 이 값만으로 고객 개입 없이 결제가 가능하므로 service_role 외 노출 금지.';

-- ---------------------------------------------------------------------------
-- 3. 결제 이력
-- ---------------------------------------------------------------------------
create table if not exists billing.payments (
  id              uuid        primary key default gen_random_uuid(),
  owner_id        uuid        not null references auth.users(id) on delete cascade,
  subscription_id uuid        references billing.subscriptions(id) on delete set null,
  plan_code       text        references billing.plans(code),
  amount          integer     not null,          -- 실제 청구액 (VAT 포함, 원)
  vat             integer     not null default 0,
  status          text        not null default 'paid'
                              check (status in ('paid','failed','refunded','canceled')),
  period_start    timestamptz,
  period_end      timestamptz,
  pg_provider     text,
  pg_order_id     text        unique,            -- 멱등 키. 웹훅 중복 수신 시 재처리를 막습니다
  pg_payment_key  text,
  receipt_url     text,
  failure_reason  text,
  paid_at         timestamptz,
  created_at      timestamptz not null default now()
);

create index if not exists payments_owner_idx on billing.payments (owner_id, created_at desc);

-- ---------------------------------------------------------------------------
-- 4. 운영 설정
--    한도 강제를 스위치로 분리해 두었습니다. 마이그레이션을 적용해도
--    enforce_quota 가 false 인 동안에는 기존 동작이 전혀 바뀌지 않습니다.
-- ---------------------------------------------------------------------------
create table if not exists billing.settings (
  id             boolean primary key default true check (id),
  enforce_quota  boolean not null default false,
  default_plan   text    not null default 'free' references billing.plans(code),
  updated_at     timestamptz not null default now()
);

insert into billing.settings (id) values (true) on conflict (id) do nothing;

comment on table billing.settings is
  '단일 행 설정 테이블. enforce_quota 를 true 로 바꾸면 월 한도 초과 발송이 차단됩니다.';

-- ---------------------------------------------------------------------------
-- 5. 내부 헬퍼
-- ---------------------------------------------------------------------------

-- 구독 행이 없는 이용자는 기본 요금제(free)를 쓰는 것으로 간주합니다.
-- 이렇게 하면 기존 회원 전원에게 구독 행을 미리 만들어 넣지 않아도 됩니다.
create or replace function billing.effective_plan(p_owner uuid)
returns billing.plans
language sql
stable
security definer
set search_path to 'billing', 'public', 'pg_temp'
as $$
  select p.*
    from billing.plans p
   where p.code = coalesce(
           (select s.plan_code
              from billing.subscriptions s
             where s.owner_id = p_owner
               and s.status in ('active','past_due')),
           (select default_plan from billing.settings where id)
         );
$$;

-- 현재 청구 주기의 시작 시각. 구독이 없으면 이번 달 1일.
create or replace function billing.period_start(p_owner uuid)
returns timestamptz
language sql
stable
security definer
set search_path to 'billing', 'public', 'pg_temp'
as $$
  select coalesce(
    (select s.current_period_start
       from billing.subscriptions s
      where s.owner_id = p_owner
        and s.status in ('active','past_due')),
    date_trunc('month', now())
  );
$$;

-- 사용량은 실제 문서 건수를 셉니다. 별도 카운터를 두지 않으므로 값이 어긋나지 않습니다.
create or replace function billing.docs_used(p_owner uuid)
returns integer
language sql
stable
security definer
set search_path to 'billing', 'esign', 'public', 'pg_temp'
as $$
  select count(*)::integer
    from esign.documents d
   where d.owner_id = p_owner
     and d.created_at >= billing.period_start(p_owner);
$$;

-- ---------------------------------------------------------------------------
-- 6. 클라이언트용 RPC — 기존 public.esign_* 규약을 따릅니다.
-- ---------------------------------------------------------------------------

-- 요금 안내 페이지용. 비로그인 상태에서도 조회할 수 있어야 합니다.
create or replace function public.esign_list_plans()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'billing', 'public', 'pg_temp'
as $function$
begin
  return jsonb_build_object('ok', true, 'plans', coalesce((
    select jsonb_agg(to_jsonb(p) order by p.sort_order)
      from billing.plans p
     where p.is_public
  ), '[]'::jsonb));
end $function$;

-- 내 구독 상태 + 이번 달 사용량.
create or replace function public.esign_my_subscription()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'billing', 'esign', 'public', 'pg_temp'
as $function$
declare
  v_plan  billing.plans;
  v_sub   billing.subscriptions;
  v_used  integer;
  v_limit integer;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'AUTH_REQUIRED');
  end if;

  v_plan  := billing.effective_plan(auth.uid());
  v_used  := billing.docs_used(auth.uid());
  v_limit := v_plan.monthly_doc_limit;

  select * into v_sub from billing.subscriptions where owner_id = auth.uid();

  return jsonb_build_object(
    'ok', true,
    'plan', to_jsonb(v_plan),
    -- 빌링키는 절대 클라이언트로 내보내지 않습니다.
    'subscription', case when v_sub.id is null then null else jsonb_build_object(
        'status',               v_sub.status,
        'billing_cycle',        v_sub.billing_cycle,
        'current_period_start', v_sub.current_period_start,
        'current_period_end',   v_sub.current_period_end,
        'cancel_at_period_end', v_sub.cancel_at_period_end,
        'has_billing_key',      (v_sub.billing_key_ref is not null)
      ) end,
    'usage', jsonb_build_object(
      'period_start', billing.period_start(auth.uid()),
      'used',         v_used,
      'limit',        v_limit,
      'remaining',    case when v_limit is null then null else greatest(v_limit - v_used, 0) end,
      'exceeded',     (v_limit is not null and v_used >= v_limit)
    ),
    'enforced', (select enforce_quota from billing.settings where id)
  );
end $function$;

-- 문서 생성 화면에서 사전 확인용. 실제 차단은 아래 트리거가 담당합니다.
create or replace function public.esign_check_quota()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'billing', 'esign', 'public', 'pg_temp'
as $function$
declare
  v_plan  billing.plans;
  v_used  integer;
  v_limit integer;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'error', 'AUTH_REQUIRED');
  end if;

  v_plan  := billing.effective_plan(auth.uid());
  v_used  := billing.docs_used(auth.uid());
  v_limit := v_plan.monthly_doc_limit;

  if v_limit is not null and v_used >= v_limit then
    return jsonb_build_object(
      'ok', true, 'allowed', false, 'reason', 'QUOTA_EXCEEDED',
      'plan', v_plan.code, 'used', v_used, 'limit', v_limit,
      'message', format('%s 요금제의 이번 달 발송 한도(%s건)를 모두 사용하셨습니다. 요금제를 변경하시면 바로 이어서 보낼 수 있습니다.',
                        v_plan.name, v_limit)
    );
  end if;

  return jsonb_build_object(
    'ok', true, 'allowed', true,
    'plan', v_plan.code, 'used', v_used, 'limit', v_limit,
    'remaining', case when v_limit is null then null else v_limit - v_used end
  );
end $function$;

-- ---------------------------------------------------------------------------
-- 7. 한도 강제 (트리거)
--    클라이언트 검사만으로는 우회가 가능하므로 DB 에서 최종 차단합니다.
--    billing.settings.enforce_quota 가 false 인 동안에는 아무 일도 하지 않습니다.
-- ---------------------------------------------------------------------------
create or replace function billing.enforce_document_quota()
returns trigger
language plpgsql
security definer
set search_path to 'billing', 'esign', 'public', 'pg_temp'
as $function$
declare
  v_plan  billing.plans;
  v_used  integer;
begin
  if not coalesce((select enforce_quota from billing.settings where id), false) then
    return new;
  end if;

  v_plan := billing.effective_plan(new.owner_id);

  if v_plan.monthly_doc_limit is null then
    return new;
  end if;

  v_used := billing.docs_used(new.owner_id);

  if v_used >= v_plan.monthly_doc_limit then
    raise exception using
      errcode = 'P0001',
      message = format('QUOTA_EXCEEDED: %s 요금제의 이번 달 발송 한도(%s건)를 모두 사용했습니다.',
                       v_plan.name, v_plan.monthly_doc_limit);
  end if;

  return new;
end $function$;

drop trigger if exists trg_enforce_document_quota on esign.documents;
create trigger trg_enforce_document_quota
  before insert on esign.documents
  for each row execute function billing.enforce_document_quota();

-- ---------------------------------------------------------------------------
-- 8. RLS
--    billing 스키마는 클라이언트에 직접 노출하지 않습니다.
--    조회는 위의 SECURITY DEFINER 함수를 통해서만 이루어집니다.
-- ---------------------------------------------------------------------------
alter table billing.plans         enable row level security;
alter table billing.subscriptions enable row level security;
alter table billing.payments      enable row level security;
alter table billing.settings      enable row level security;

-- 정책을 하나도 만들지 않으면 service_role 을 제외한 모든 접근이 거부됩니다.
-- 결제 이력만은 본인이 직접 조회할 수 있도록 열어 둡니다.
drop policy if exists payments_select_own on billing.payments;
create policy payments_select_own on billing.payments
  for select to authenticated
  using (owner_id = auth.uid());

-- ---------------------------------------------------------------------------
-- 9. 권한
-- ---------------------------------------------------------------------------
revoke all on schema billing from anon, authenticated;
grant usage on schema billing to service_role;

grant execute on function public.esign_list_plans()     to anon, authenticated;
grant execute on function public.esign_my_subscription() to authenticated;
grant execute on function public.esign_check_quota()     to authenticated;

-- ============================================================================
-- 활성화 절차 (마이그레이션 적용 이후, 순서대로)
-- ============================================================================
--
-- 1) 적용 직후 확인 — 아무것도 차단되지 않는 상태여야 합니다.
--      select * from billing.settings;              -- enforce_quota = false
--      select public.esign_list_plans();
--
-- 2) 기존 회원에게 구독 행 생성 (원하는 요금제로).
--    구독 행이 없으면 자동으로 free 로 간주되므로, 유료 전환 대상만 넣으면 됩니다.
--      insert into billing.subscriptions (owner_id, plan_code, billing_cycle)
--      select user_id, 'business', 'monthly' from esign.profiles where email = '...'
--      on conflict (owner_id) do update set plan_code = excluded.plan_code;
--
-- 3) 실제 사용량이 어떻게 잡히는지 확인.
--      select p.email, billing.docs_used(p.user_id) as used,
--             (billing.effective_plan(p.user_id)).code as plan
--        from esign.profiles p where p.status = 'active';
--
-- 4) 한도를 넘긴 이용자가 없는지, 요금제 배정이 맞는지 확인한 뒤 강제를 켭니다.
--      update billing.settings set enforce_quota = true, updated_at = now() where id;
--
-- 5) 되돌릴 때.
--      update billing.settings set enforce_quota = false, updated_at = now() where id;
--
-- ============================================================================
