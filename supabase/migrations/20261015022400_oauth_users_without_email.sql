-- 카카오 등 이메일을 주지 않는 소셜 로그인 대비
-- profiles.email 은 NOT NULL 이므로 이메일이 없으면 빈 문자열로 둔다.
-- 이름은 소셜 계정의 표시 이름(name / full_name / nickname)을 먼저 쓴다.
--
-- 이 수정이 없으면 이메일 없이 들어온 카카오 사용자는 auth.users 의
-- 가입 트리거(trg_esign_new_user)에서 NOT NULL 오류가 나서 로그인 자체가 실패한다.

create or replace function esign.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path to 'esign', 'public', 'pg_temp'
as $function$
declare
  v_first boolean;
  v_email text := coalesce(new.email, new.raw_user_meta_data->>'email', '');
begin
  select count(*) = 0 into v_first from esign.profiles;
  insert into esign.profiles (user_id, email, name, role, status)
  values (new.id, v_email,
          coalesce(nullif(new.raw_user_meta_data->>'name',''),
                   nullif(new.raw_user_meta_data->>'full_name',''),
                   nullif(new.raw_user_meta_data->>'nickname',''),
                   nullif(split_part(v_email,'@',1),''),
                   '사용자'),
          case when v_first then 'admin' else 'user' end,
          case when v_first then 'active' else 'pending' end)
  on conflict (user_id) do nothing;
  return new;
end $function$;

create or replace function public.esign_me()
returns jsonb
language plpgsql
security definer
set search_path to 'esign', 'public', 'pg_temp'
as $function$
declare v_p esign.profiles%rowtype;
begin
  if auth.uid() is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED'); end if;
  select * into v_p from esign.profiles where user_id = auth.uid();
  if not found then
    insert into esign.profiles (user_id, email, name, status)
    select auth.uid(),
           coalesce(u.email, u.raw_user_meta_data->>'email', ''),
           coalesce(nullif(u.raw_user_meta_data->>'name',''),
                    nullif(u.raw_user_meta_data->>'full_name',''),
                    nullif(u.raw_user_meta_data->>'nickname',''),
                    nullif(split_part(coalesce(u.email,''),'@',1),''),
                    '사용자'),
           'pending'
      from auth.users u where u.id = auth.uid()
    returning * into v_p;
  end if;
  return jsonb_build_object('ok',true,'profile',to_jsonb(v_p),
    'is_admin',(v_p.role='admin'),
    'needs_signup',(v_p.privacy_agreed is not true),
    'approved',(v_p.status='active'));
end $function$;
