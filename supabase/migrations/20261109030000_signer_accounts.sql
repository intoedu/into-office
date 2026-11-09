-- ============================================================
-- 서명자 간편 가입 (카카오 · 구글) + 내 정보 자동 기입
--
-- 서명자는 서명 화면에서 카카오 · 구글로 가입하면 내 정보(기본 정보 필수 + 여러 선택 정보)를
-- 계정에 저장해 두고, 다음 문서부터 기입 항목이 자동으로 채워진다.
--   · 서명자 계정은 요청자(유료 회원)와 구분한다: profiles.account_kind = 'signer'
--     관리자 회원 목록 · 승인 대기 수에 나오지 않는다
--   · 내 정보는 esign.signer_profiles 에 본인만 읽고 쓴다 (함수로만 접근, RLS 정책 없음)
--   · 주민등록번호 · 여권번호 같은 고유식별정보는 받지 않는다
-- ============================================================
alter table esign.profiles add column if not exists account_kind text not null default 'member';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_account_kind_check') then
    alter table esign.profiles add constraint profiles_account_kind_check check (account_kind in ('member', 'signer'));
  end if;
end $$;
comment on column esign.profiles.account_kind is 'member: 요청자(회원) / signer: 서명 화면에서 간편 가입한 서명자 (승인 · 결제 없음)';

create table if not exists esign.signer_profiles (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  name       text check (name is null or char_length(name) <= 30),
  phone      text check (phone is null or phone ~ '^0[0-9]{8,10}$'),
  email      text check (email is null or char_length(email) <= 120),
  birthdate  date,
  info       jsonb not null default '{}'::jsonb,   -- 선택 정보 (정해진 키만)
  extra      jsonb not null default '[]'::jsonb,   -- 직접 추가한 항목 [{label, value}]
  agreed_at  timestamptz,
  updated_at timestamptz not null default now()
);
alter table esign.signer_profiles enable row level security;
comment on table esign.signer_profiles is '서명자 내 정보 — 다음 문서의 기입 항목을 자동으로 채운다. 본인만 함수로 읽고 쓴다';

-- 선택 정보로 받을 수 있는 키 (고유식별정보 제외)
create or replace function esign.signer_info_keys()
returns text[] language sql immutable as $$
  select array['name_en','gender','nationality','address','address_detail','zipcode',
               'company','job_title','school','grade','student_no','employee_no','car_no',
               'emergency_name','emergency_relation','emergency_phone','guardian_name','guardian_relation','guardian_phone',
               'bank_name','bank_account','bank_holder','website','memo'];
$$;

-- 서명 화면에서 간편 가입한 직후: 새 계정이면 서명자 계정으로 표시 (기존 회원은 그대로)
create or replace function public.esign_signer_register()
returns jsonb language plpgsql security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
declare v_uid uuid := auth.uid(); v_p esign.profiles%rowtype;
begin
  if v_uid is null then return jsonb_build_object('ok', false, 'error', 'AUTH_REQUIRED'); end if;
  select * into v_p from esign.profiles where user_id = v_uid;
  if not found then
    insert into esign.profiles (user_id, email, name, status, account_kind)
    select v_uid, coalesce(u.email, u.raw_user_meta_data->>'email', ''),
           coalesce(nullif(u.raw_user_meta_data->>'name',''), nullif(u.raw_user_meta_data->>'full_name',''),
                    nullif(u.raw_user_meta_data->>'nickname',''), '서명자'),
           'pending', 'signer'
      from auth.users u where u.id = v_uid
    returning * into v_p;
  elsif v_p.account_kind = 'member' and v_p.status = 'pending' and v_p.privacy_agreed is not true
        and v_p.role <> 'admin'
        and not exists (select 1 from esign.memberships m where m.user_id = v_uid) then
    update esign.profiles set account_kind = 'signer' where user_id = v_uid returning * into v_p;
  end if;
  insert into esign.signer_profiles (user_id) values (v_uid) on conflict (user_id) do nothing;
  return jsonb_build_object('ok', true, 'kind', v_p.account_kind);
end $$;
revoke all on function public.esign_signer_register() from public, anon;
grant execute on function public.esign_signer_register() to authenticated, service_role;

-- 내 정보 읽기
create or replace function public.esign_signer_profile_get()
returns jsonb language plpgsql stable security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
declare v_uid uuid := auth.uid(); v_sp esign.signer_profiles%rowtype; v_p esign.profiles%rowtype;
begin
  if v_uid is null then return jsonb_build_object('ok', false, 'error', 'AUTH_REQUIRED'); end if;
  select * into v_sp from esign.signer_profiles where user_id = v_uid;
  select * into v_p from esign.profiles where user_id = v_uid;
  return jsonb_build_object('ok', true,
    'kind', coalesce(v_p.account_kind, 'member'),
    'account_email', (select email from auth.users where id = v_uid),
    'account_name', v_p.name,
    'profile', case when v_sp.user_id is null then null else jsonb_build_object(
      'name', v_sp.name, 'phone', v_sp.phone, 'email', v_sp.email, 'birthdate', v_sp.birthdate,
      'info', v_sp.info, 'extra', v_sp.extra, 'agreed_at', v_sp.agreed_at, 'updated_at', v_sp.updated_at) end,
    'complete', v_sp.user_id is not null and v_sp.name is not null and v_sp.phone is not null
                and v_sp.email is not null and v_sp.birthdate is not null and v_sp.agreed_at is not null);
end $$;
revoke all on function public.esign_signer_profile_get() from public, anon;
grant execute on function public.esign_signer_profile_get() to authenticated, service_role;

-- 내 정보 저장 (p_mode: 'replace' = 내 정보 화면에서 통째로 저장 / 'merge' = 서명하며 입력한 값을 덧붙이기)
-- p: { name, phone, email, birthdate, info: {키: 값}, extra: [{label, value}], agree: true }
create or replace function public.esign_signer_profile_save(p jsonb, p_mode text default 'replace')
returns jsonb language plpgsql security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
declare
  v_uid uuid := auth.uid();
  v_old esign.signer_profiles%rowtype;
  v_name text; v_phone text; v_email text; v_birth date;
  v_info jsonb := '{}'::jsonb; v_extra jsonb := '[]'::jsonb;
  v_k text; v_v text; v_e jsonb; v_lbl text; v_n int := 0;
begin
  if v_uid is null then return jsonb_build_object('ok', false, 'error', 'AUTH_REQUIRED'); end if;
  if p_mode not in ('replace', 'merge') then return jsonb_build_object('ok', false, 'error', 'BAD_MODE'); end if;
  select * into v_old from esign.signer_profiles where user_id = v_uid;

  v_name  := nullif(left(btrim(coalesce(p->>'name', '')), 30), '');
  v_phone := nullif(regexp_replace(coalesce(p->>'phone', ''), '[^0-9]', '', 'g'), '');
  v_email := nullif(left(btrim(coalesce(p->>'email', '')), 120), '');
  begin
    v_birth := nullif(btrim(coalesce(p->>'birthdate', '')), '')::date;
  exception when others then
    return jsonb_build_object('ok', false, 'error', 'BAD_BIRTHDATE');
  end;
  if v_phone is not null and v_phone !~ '^0[0-9]{8,10}$' then return jsonb_build_object('ok', false, 'error', 'BAD_PHONE'); end if;
  if v_email is not null and v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    return jsonb_build_object('ok', false, 'error', 'BAD_EMAIL');
  end if;

  -- 선택 정보: 정해진 키만, 값 200자까지
  if jsonb_typeof(p->'info') = 'object' then
    for v_k, v_v in select key, value #>> '{}' from jsonb_each(p->'info') loop
      if v_k = any(esign.signer_info_keys()) and nullif(btrim(coalesce(v_v, '')), '') is not null then
        v_info := v_info || jsonb_build_object(v_k, left(btrim(v_v), 200));
      end if;
    end loop;
  end if;
  -- 직접 추가한 항목: 30개까지, 이름 30자 · 값 200자
  if jsonb_typeof(p->'extra') = 'array' then
    for v_e in select * from jsonb_array_elements(p->'extra') loop
      v_lbl := nullif(left(btrim(coalesce(v_e->>'label', '')), 30), '');
      v_v := nullif(left(btrim(coalesce(v_e->>'value', '')), 200), '');
      if v_lbl is not null and v_v is not null and v_n < 30 then
        v_extra := v_extra || jsonb_build_array(jsonb_build_object('label', v_lbl, 'value', v_v));
        v_n := v_n + 1;
      end if;
    end loop;
  end if;

  if p_mode = 'replace' then
    if v_name is null or v_phone is null or v_email is null or v_birth is null then
      return jsonb_build_object('ok', false, 'error', 'REQUIRED_MISSING');
    end if;
    if coalesce((p->>'agree')::boolean, false) is not true then
      return jsonb_build_object('ok', false, 'error', 'AGREE_REQUIRED');
    end if;
    insert into esign.signer_profiles (user_id, name, phone, email, birthdate, info, extra, agreed_at, updated_at)
    values (v_uid, v_name, v_phone, v_email, v_birth, v_info, v_extra, coalesce(v_old.agreed_at, now()), now())
    on conflict (user_id) do update
      set name = excluded.name, phone = excluded.phone, email = excluded.email, birthdate = excluded.birthdate,
          info = excluded.info, extra = excluded.extra, agreed_at = excluded.agreed_at, updated_at = now();
  else
    -- 덧붙이기: 동의한 사람만, 비어 있는 기본 정보는 채우고 선택 정보 · 직접 항목은 새 값으로 덮어쓴다
    if v_old.agreed_at is null then return jsonb_build_object('ok', false, 'error', 'AGREE_REQUIRED'); end if;
    update esign.signer_profiles sp
       set name = coalesce(v_name, sp.name), phone = coalesce(v_phone, sp.phone),
           email = coalesce(v_email, sp.email), birthdate = coalesce(v_birth, sp.birthdate),
           info = sp.info || v_info,
           extra = (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
                      select x from jsonb_array_elements(sp.extra) x
                       where not exists (select 1 from jsonb_array_elements(v_extra) y where y->>'label' = x->>'label')
                      union all
                      select y from jsonb_array_elements(v_extra) y) z(x)),
           updated_at = now()
     where sp.user_id = v_uid;
  end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.esign_signer_profile_save(jsonb, text) from public, anon;
grant execute on function public.esign_signer_profile_save(jsonb, text) to authenticated, service_role;

-- 관리자 회원 목록 · 승인 대기 수에서 서명자 계정은 뺀다
create or replace function public.esign_list_members()
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'esign', 'public', 'pg_temp'
as $function$
begin
  if not esign.is_admin() then return jsonb_build_object('ok',false,'error','ADMIN_ONLY'); end if;
  return jsonb_build_object('ok',true,
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
        'user_id',p.user_id,'email',p.email,'username',p.username,'name',p.name,
        'birth_year',p.birth_year,'phone',p.phone,
        'biz_name',p.biz_name,'biz_type',p.biz_type,
        'member_type',p.member_type,
        'signup_source',p.signup_source,'signup_source_etc',p.signup_source_etc,
        'role',p.role,'status',p.status,
        'privacy_agreed',p.privacy_agreed,'marketing_agreed',p.marketing_agreed,
        'created_at',p.created_at,'approved_at',p.approved_at,
        'is_me',(p.user_id = auth.uid())
      ) order by
        case p.status when 'pending' then 0 when 'active' then 1 else 2 end,
        p.created_at desc)
      from esign.profiles p where p.account_kind <> 'signer'), '[]'::jsonb),
    'stats', (select jsonb_build_object(
        'total',count(*),'pending',count(*) filter (where status='pending'),
        'active',count(*) filter (where status='active'),
        'blocked',count(*) filter (where status in ('suspended','rejected')),
        'signers',(select count(*) from esign.profiles where account_kind = 'signer'))
      from esign.profiles where account_kind <> 'signer'));
end $function$;

-- 내 정보 모두 지우기 (자동 기입 해제). 값을 비우고 동의도 거둔다
create or replace function public.esign_signer_profile_clear()
returns jsonb language plpgsql security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then return jsonb_build_object('ok', false, 'error', 'AUTH_REQUIRED'); end if;
  update esign.signer_profiles
     set name = null, phone = null, email = null, birthdate = null,
         info = '{}'::jsonb, extra = '[]'::jsonb, agreed_at = null, updated_at = now()
   where user_id = v_uid;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.esign_signer_profile_clear() from public, anon;
grant execute on function public.esign_signer_profile_clear() to authenticated, service_role;

-- 서명자 계정이 직접 문서를 보내려고 요청자(회원) 가입을 시작할 때: 회원으로 바꾼다 (이후 가입 · 승인 절차는 기존 그대로)
create or replace function public.esign_signer_become_member()
returns jsonb language plpgsql security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then return jsonb_build_object('ok', false, 'error', 'AUTH_REQUIRED'); end if;
  update esign.profiles set account_kind = 'member' where user_id = v_uid and account_kind = 'signer';
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.esign_signer_become_member() from public, anon;
grant execute on function public.esign_signer_become_member() to authenticated, service_role;
