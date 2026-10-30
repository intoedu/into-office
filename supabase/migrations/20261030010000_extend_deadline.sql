-- ============================================================
-- 서명 기한 연장
--
-- 요청자(문서 소유자 또는 같은 조직의 owner · admin — esign.doc_visible)가
-- 서명 대기 · 진행 · 만료 문서의 기한을 늘린다.
--   새 기한 = max(지금 기한, 지금) + p_minutes
--   (기한이 이미 지났으면 지금부터 센다)
-- 만료(expired) 문서는 서명한 사람이 있으면 progress, 없으면 waiting 으로 되살린다.
-- 완료 · 취소 · 삭제된 문서는 건드리지 않는다.
--
-- p_document_ids 로 여러 문서를, p_batch_id 로 대량발송 묶음 전체를 한 번에 연장할 수 있다.
-- ============================================================
create or replace function public.esign_extend_deadline(
  p_document_ids uuid[],
  p_minutes int,
  p_batch_id uuid default null
)
returns jsonb language plpgsql security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
declare
  v_uid  uuid := auth.uid();
  v_doc  record;
  v_new  timestamptz;
  v_out  jsonb := '[]'::jsonb;
  v_skip int := 0;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'error', 'LOGIN_REQUIRED');
  end if;
  -- 30분 ~ 30일
  if p_minutes is null or p_minutes < 30 or p_minutes > 43200 then
    return jsonb_build_object('ok', false, 'error', 'BAD_MINUTES');
  end if;
  if coalesce(array_length(p_document_ids, 1), 0) = 0 and p_batch_id is null then
    return jsonb_build_object('ok', false, 'error', 'NO_DOCUMENTS');
  end if;

  for v_doc in
    select d.id, d.deadline, d.status, d.owner_id, d.org_id, d.deleted_at
      from esign.documents d
     where (d.id = any(coalesce(p_document_ids, '{}'::uuid[]))
            or (p_batch_id is not null and d.bulk_batch_id = p_batch_id))
     limit 1000
  loop
    if not esign.doc_visible(v_doc.owner_id, v_doc.org_id, v_uid)
       or v_doc.deleted_at is not null
       or v_doc.status not in ('waiting', 'progress', 'expired') then
      v_skip := v_skip + 1;
      continue;
    end if;

    v_new := greatest(coalesce(v_doc.deadline, now()), now()) + make_interval(mins => p_minutes);

    update esign.documents d
       set deadline = v_new,
           status = case
             when d.status <> 'expired' then d.status
             when exists (select 1 from esign.signers s where s.document_id = d.id and s.status = 'signed') then 'progress'
             else 'waiting'
           end
     where d.id = v_doc.id;

    v_out := v_out || jsonb_build_object('id', v_doc.id, 'deadline', v_new);
  end loop;

  return jsonb_build_object('ok', true, 'count', jsonb_array_length(v_out), 'skipped', v_skip, 'documents', v_out);
end $$;

revoke all on function public.esign_extend_deadline(uuid[], int, uuid) from public, anon;
grant execute on function public.esign_extend_deadline(uuid[], int, uuid) to authenticated, service_role;
