-- ============================================================
-- esign 스키마용 public 래퍼 함수
--
-- 배경
--   esign 스키마는 PostgREST 의 노출 스키마 목록에 없다(의도된 설계).
--   그래서 엣지 함수가 admin.schema('esign').rpc(...) / .from(...) 로
--   직접 접근하면 PostgREST 가 PGRST106 을 돌려준다.
--     → 화면에는 "문서를 불러오지 못했습니다. (Invalid schema: esign)" 로 보인다.
--
-- 해결
--   나머지 기능(esign_* 60여 개)과 동일하게 public 에 SECURITY DEFINER
--   래퍼를 두고, 엣지 함수는 그 래퍼만 호출한다.
--   래퍼는 서버(엣지 함수) 전용이므로 실행 권한을 service_role 에만 준다.
--   브라우저의 publishable 키(anon)로는 호출할 수 없다.
-- ============================================================

-- ── 1) 파일 접근 권한 확인 · esign-file ──────────────────────
create or replace function public.esign_file_access(
  p_path text,
  p_sign_token text,
  p_uid uuid
) returns jsonb
language sql
stable
security definer
set search_path = public, esign
as $$
  select esign.file_access(p_path, p_sign_token, p_uid);
$$;

revoke all on function public.esign_file_access(text, text, uuid) from public;
revoke all on function public.esign_file_access(text, text, uuid) from anon, authenticated;
grant execute on function public.esign_file_access(text, text, uuid) to service_role;

-- ── 2) 알림톡 발송 대상 조회 · esign-notify ──────────────────
create or replace function public.esign_notify_targets(
  p_kind text,
  p_document_id uuid
) returns jsonb
language sql
stable
security definer
set search_path = public, esign
as $$
  select esign.notify_targets(p_kind, p_document_id);
$$;

revoke all on function public.esign_notify_targets(text, uuid) from public;
revoke all on function public.esign_notify_targets(text, uuid) from anon, authenticated;
grant execute on function public.esign_notify_targets(text, uuid) to service_role;

-- ── 3) 삭제 예정 안내 대상 조회 · esign-retention ────────────
create or replace function public.esign_notify_retention_due()
returns jsonb
language sql
stable
security definer
set search_path = public, esign
as $$
  select esign.notify_retention_due();
$$;

revoke all on function public.esign_notify_retention_due() from public;
revoke all on function public.esign_notify_retention_due() from anon, authenticated;
grant execute on function public.esign_notify_retention_due() to service_role;

-- ── 4) 알림톡 발송 기록 적재 · esign-notify / esign-retention ─
create or replace function public.esign_alimtalk_log(p_rows jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, esign
as $$
declare v_count int;
begin
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    return jsonb_build_object('ok', false, 'error', 'ROWS_REQUIRED');
  end if;

  insert into esign.alimtalk_logs
    (org_id, document_id, kind, template_id, to_phone,
     variables, status, error, response, sent_at)
  select r.org_id, r.document_id, r.kind, r.template_id, r.to_phone,
         coalesce(r.variables, '{}'::jsonb),
         coalesce(nullif(btrim(r.status), ''), 'queued'),
         r.error, r.response, r.sent_at
    from jsonb_to_recordset(p_rows) as r(
      org_id      uuid,
      document_id uuid,
      kind        text,
      template_id text,
      to_phone    text,
      variables   jsonb,
      status      text,
      error       text,
      response    jsonb,
      sent_at     timestamptz);

  get diagnostics v_count = row_count;
  return jsonb_build_object('ok', true, 'inserted', v_count);
end $$;

revoke all on function public.esign_alimtalk_log(jsonb) from public;
revoke all on function public.esign_alimtalk_log(jsonb) from anon, authenticated;
grant execute on function public.esign_alimtalk_log(jsonb) to service_role;

-- ── 5) 스토리지 정리 대기 목록 · esign-retention ─────────────
create or replace function public.esign_purge_pending(p_limit int default 500)
returns jsonb
language sql
stable
security definer
set search_path = public, esign
as $$
  select jsonb_build_object('ok', true, 'items', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', t.id, 'file_path', t.file_path, 'signed_path', t.signed_path))
      from (select p.id, p.file_path, p.signed_path
              from esign.purge_log p
             where p.storage_cleared_at is null
             order by p.purged_at
             limit greatest(1, least(coalesce(p_limit, 500), 1000))) t
  ), '[]'::jsonb));
$$;

revoke all on function public.esign_purge_pending(int) from public;
revoke all on function public.esign_purge_pending(int) from anon, authenticated;
grant execute on function public.esign_purge_pending(int) to service_role;

-- ── 6) 스토리지 정리 완료 표시 · esign-retention ─────────────
create or replace function public.esign_purge_mark_cleared(p_ids uuid[])
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, esign
as $$
declare v_count int;
begin
  if p_ids is null or array_length(p_ids, 1) is null then
    return jsonb_build_object('ok', true, 'updated', 0);
  end if;

  update esign.purge_log
     set storage_cleared_at = now()
   where id = any(p_ids)
     and storage_cleared_at is null;

  get diagnostics v_count = row_count;
  return jsonb_build_object('ok', true, 'updated', v_count);
end $$;

revoke all on function public.esign_purge_mark_cleared(uuid[]) from public;
revoke all on function public.esign_purge_mark_cleared(uuid[]) from anon, authenticated;
grant execute on function public.esign_purge_mark_cleared(uuid[]) to service_role;

notify pgrst, 'reload schema';
