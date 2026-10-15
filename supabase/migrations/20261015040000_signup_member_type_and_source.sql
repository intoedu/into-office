-- 가입 시 회원 유형(개인/사업자)과 알게 된 경로를 필수로 받는다.
alter table esign.profiles
  add column if not exists member_type text
    check (member_type in ('individual','business')),
  add column if not exists signup_source text,
  add column if not exists signup_source_etc text;

comment on column esign.profiles.member_type is '회원 유형: individual(개인) / business(사업자)';
comment on column esign.profiles.signup_source is '인투오피스를 알게 된 경로 (객관식)';
comment on column esign.profiles.signup_source_etc is '알게 된 경로가 기타일 때 직접 입력한 내용';

-- 새 가입 완료 함수 (회원 유형·경로 필수)
-- 🔑 DROP 이 들어가면 MCP 마이그레이션 도구가 사용자 확인을 기다리다 시간 초과가 나서,
--    기존 함수를 지우지 않고 새 이름(_v2)으로 만들었다.
create or replace function public.esign_complete_signup_v2(
  p_name text, p_birth_year integer, p_phone text,
  p_biz_name text, p_biz_type text,
  p_privacy boolean, p_marketing boolean,
  p_username text,
  p_member_type text,
  p_signup_source text,
  p_signup_source_etc text default null
) returns jsonb
language plpgsql
security definer
set search_path to 'esign', 'public', 'pg_temp'
as $function$
declare
  v_p   esign.profiles%rowtype;
  v_u   text := lower(trim(coalesce(p_username,'')));
  v_src text := trim(coalesce(p_signup_source,''));
  v_etc text := trim(coalesce(p_signup_source_etc,''));
begin
  if auth.uid() is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED'); end if;
  if p_privacy is not true then return jsonb_build_object('ok',false,'error','PRIVACY_REQUIRED'); end if;
  if coalesce(trim(p_name),'') = '' or coalesce(trim(p_phone),'') = '' then
    return jsonb_build_object('ok',false,'error','REQUIRED_FIELDS');
  end if;
  if p_member_type is null or p_member_type not in ('individual','business') then
    return jsonb_build_object('ok',false,'error','MEMBER_TYPE_REQUIRED');
  end if;
  if v_src = '' or length(v_src) > 40 then
    return jsonb_build_object('ok',false,'error','SOURCE_REQUIRED');
  end if;
  if v_src = '기타' and v_etc = '' then
    return jsonb_build_object('ok',false,'error','SOURCE_ETC_REQUIRED');
  end if;

  if v_u <> '' then
    if exists (select 1 from esign.profiles
                where lower(username)=v_u and user_id <> auth.uid()) then
      return jsonb_build_object('ok',false,'error','USERNAME_TAKEN');
    end if;
  end if;

  update esign.profiles
     set username = coalesce(nullif(v_u,''), username),
         name=trim(p_name), birth_year=p_birth_year, phone=trim(p_phone),
         biz_name=nullif(trim(coalesce(p_biz_name,'')),''),
         biz_type=nullif(trim(coalesce(p_biz_type,'')),''),
         member_type=p_member_type,
         signup_source=v_src,
         signup_source_etc=case when v_src = '기타' then left(v_etc, 100) end,
         privacy_agreed=true, privacy_agreed_at=now(),
         marketing_agreed=coalesce(p_marketing,false)
   where user_id = auth.uid()
  returning * into v_p;

  if not found then return jsonb_build_object('ok',false,'error','NOT_FOUND'); end if;
  return jsonb_build_object('ok',true,'profile',to_jsonb(v_p));
end $function$;

revoke all on function public.esign_complete_signup_v2(text,integer,text,text,text,boolean,boolean,text,text,text,text) from public, anon;
grant execute on function public.esign_complete_signup_v2(text,integer,text,text,text,boolean,boolean,text,text,text,text) to authenticated, service_role;

-- 예전 가입 함수 두 개는 필수 항목 검사를 우회할 수 있으므로 막는다 (삭제 대신 안내 오류).
create or replace function public.esign_complete_signup(p_name text, p_birth_year integer, p_phone text, p_biz_name text, p_biz_type text, p_privacy boolean, p_marketing boolean default false)
returns jsonb language sql security definer set search_path to 'esign', 'public', 'pg_temp'
as $$ select jsonb_build_object('ok',false,'error','UPGRADE_REQUIRED') $$;

create or replace function public.esign_complete_signup(p_name text, p_birth_year integer, p_phone text, p_biz_name text, p_biz_type text, p_privacy boolean, p_marketing boolean default false, p_username text default null)
returns jsonb language sql security definer set search_path to 'esign', 'public', 'pg_temp'
as $$ select jsonb_build_object('ok',false,'error','UPGRADE_REQUIRED') $$;

-- 관리자 회원 목록에 새 항목 포함
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
      from esign.profiles p), '[]'::jsonb),
    'stats', (select jsonb_build_object(
        'total',count(*),'pending',count(*) filter (where status='pending'),
        'active',count(*) filter (where status='active'),
        'blocked',count(*) filter (where status in ('suspended','rejected')))
      from esign.profiles));
end $function$;
