-- 가입 승인 알림톡용 회원 정보 (esign-notify Edge Function 이 service_role 로만 호출)
create or replace function public.esign_member_notify_info(p_user_id uuid)
returns jsonb
language sql
stable
security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
  select coalesce(
    (select jsonb_build_object('ok', true,
              'name', p.name, 'phone', p.phone, 'username', p.username,
              'email', nullif(p.email, ''), 'status', p.status, 'approved_at', p.approved_at)
       from esign.profiles p where p.user_id = p_user_id),
    jsonb_build_object('ok', false, 'error', 'NOT_FOUND'));
$$;

revoke all on function public.esign_member_notify_info(uuid) from public, anon, authenticated;
grant execute on function public.esign_member_notify_info(uuid) to service_role;
