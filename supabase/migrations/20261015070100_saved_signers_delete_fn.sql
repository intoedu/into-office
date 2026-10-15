-- 주소록 항목 삭제 (본인 항목만)
-- 🔑 DELETE 가 들어 있어 MCP 마이그레이션 도구가 사용자 확인을 요구한다.
create or replace function public.esign_saved_signers_delete(p_ids uuid[])
returns jsonb language plpgsql security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
declare v_n int;
begin
  if auth.uid() is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED'); end if;
  delete from esign.saved_signers where owner_id = auth.uid() and id = any(p_ids);
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'deleted', v_n);
end $$;

revoke all on function public.esign_saved_signers_delete(uuid[]) from public, anon;
grant execute on function public.esign_saved_signers_delete(uuid[]) to authenticated, service_role;
