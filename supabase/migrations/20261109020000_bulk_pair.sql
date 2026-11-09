-- ============================================================
-- 대량발송: 갑(모든 문서에 같은 사람, 보내기 전 한 번 서명) + 을(명단의 각 사람) 2인 문서
--
-- esign_create_bulk_pair 는 명단 한 줄마다 [갑, 을] 두 사람 문서를 만든다.
--   · 갑은 보내기 전에 한 번 한 서명으로 모든 문서에서 이미 서명한 상태(presigned)로 들어간다
--   · 을은 서명 대기 — 알림톡은 을에게만 간다 (notify_targets 의 request · remind 는 서명 안 한 사람만)
--   · 을이 서명하면 문서가 완료된다. 미리 서명한 갑에게는 문서마다 완료 알림톡이 가지 않게 한다
-- 기존 esign_create_bulk(1인 문서)는 그대로 둔다.
-- 문서의 조직 · 사용량 집계 · 한도는 documents 트리거가 그대로 처리한다.
-- ============================================================
alter table esign.signers add column if not exists presigned boolean not null default false;
comment on column esign.signers.presigned is '대량발송에서 보내기 전에 미리 서명한 갑 (완료 알림톡을 문서마다 보내지 않는다)';

-- 완료 알림톡: 미리 서명한 갑은 뺀다 (요청 · 리마인드는 원래대로 서명 안 한 사람만)
create or replace function esign.notify_targets(p_kind text, p_document_id uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'esign', 'public'
as $function$
declare v_doc record; v_rows jsonb;
begin
  select d.id, d.org_id, d.title, d.deadline, d.requester_name, d.completed_at,
         coalesce(o.name, d.requester_name, '인투오피스') as org_name
    into v_doc
    from esign.documents d
    left join esign.organizations o on o.id = d.org_id
   where d.id = p_document_id and d.deleted_at is null;

  if not found then return jsonb_build_object('ok', false, 'error', 'NOT_FOUND'); end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'signer_id', s.id, 'name', s.name, 'phone', s.phone,
           'sign_token', s.sign_token, 'status', s.status)), '[]'::jsonb)
    into v_rows
    from esign.signers s
   where s.document_id = p_document_id
     and ( (p_kind = 'done' and not coalesce(s.presigned, false)) or s.status <> 'signed' );

  return jsonb_build_object('ok', true,
    'document', jsonb_build_object(
      'id', v_doc.id, 'org_id', v_doc.org_id, 'org_name', v_doc.org_name,
      'title', v_doc.title, 'deadline', v_doc.deadline,
      'requester_name', coalesce(v_doc.requester_name, v_doc.org_name),
      'completed_at', v_doc.completed_at,
      'signer_names', (select string_agg(s.name, ', ' order by s.order_index)
                         from esign.signers s where s.document_id = p_document_id)),
    'targets', v_rows);
end $function$;

-- p_party_a: { name, phone, sig_method: draw|typed|upload, sig_data }
-- p_fields : [{ signer_index: 0(갑) | 1(을), field_type, page, x, y, w, h }]
create or replace function public.esign_create_bulk_pair(
  p_title text, p_requester_name text, p_file_path text, p_file_name text, p_file_type text,
  p_file_size bigint, p_file_hash text, p_deadline timestamptz,
  p_rows jsonb, p_fields jsonb, p_party_a jsonb,
  p_access_code text default null, p_require_phone boolean default false
)
returns jsonb language plpgsql security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
declare
  v_uid uuid := auth.uid();
  v_batch uuid := gen_random_uuid();
  v_row jsonb; v_field jsonb;
  v_doc uuid; v_a uuid; v_b uuid;
  v_n int; v_hash text; v_enc bytea; v_code text;
  v_a_name text := btrim(coalesce(p_party_a->>'name', ''));
  v_a_phone text := btrim(coalesce(p_party_a->>'phone', ''));
  v_a_method text := coalesce(p_party_a->>'sig_method', '');
  v_a_sig text := coalesce(p_party_a->>'sig_data', '');
begin
  if v_uid is null then return jsonb_build_object('ok', false, 'error', 'AUTH_REQUIRED'); end if;
  if v_a_name = '' then return jsonb_build_object('ok', false, 'error', 'PARTY_A_NAME'); end if;
  if v_a_method not in ('draw', 'typed', 'upload') or v_a_sig = '' then
    return jsonb_build_object('ok', false, 'error', 'PARTY_A_SIGNATURE');
  end if;

  v_n := jsonb_array_length(coalesce(p_rows, '[]'::jsonb));
  if v_n < 1   then return jsonb_build_object('ok', false, 'error', 'NO_ROWS'); end if;
  if v_n > 500 then return jsonb_build_object('ok', false, 'error', 'TOO_MANY_ROWS'); end if;

  v_code := btrim(coalesce(p_access_code, ''));
  if v_code <> '' then
    if length(v_code) < 4 then return jsonb_build_object('ok', false, 'error', 'CODE_TOO_SHORT'); end if;
    v_hash := extensions.crypt(v_code, extensions.gen_salt('bf'));
    v_enc  := extensions.pgp_sym_encrypt(v_code, esign.access_key());
  end if;

  for v_row in select * from jsonb_array_elements(p_rows) loop
    if coalesce(btrim(v_row->>'name'), '') = '' or coalesce(btrim(v_row->>'phone'), '') = '' then
      return jsonb_build_object('ok', false, 'error', 'ROW_INCOMPLETE', 'row', v_row);
    end if;

    insert into esign.documents
      (owner_id, title, requester_name, file_path, file_name, file_type, file_size,
       file_hash, deadline, status, access_code_hash, access_code_enc, require_phone_verify,
       bulk_batch_id, bulk_label)
    values
      (v_uid, p_title || ' - ' || (v_row->>'name'), coalesce(p_requester_name, '인투오피스'),
       p_file_path, p_file_name, p_file_type, p_file_size, p_file_hash,
       p_deadline, 'progress', v_hash, v_enc, coalesce(p_require_phone, false),
       v_batch, p_title)
    returning id into v_doc;

    -- 갑: 보내기 전에 한 서명으로 이미 서명한 상태
    insert into esign.signers (document_id, order_index, name, phone, status, sig_method, sig_data,
                               consent_agreed, consent_at, signed_at, presigned)
    values (v_doc, 0, v_a_name, v_a_phone, 'signed', v_a_method, v_a_sig, true, now(), now(), true)
    returning id into v_a;
    -- 을: 명단의 사람
    insert into esign.signers (document_id, order_index, name, phone)
    values (v_doc, 1, btrim(v_row->>'name'), btrim(v_row->>'phone'))
    returning id into v_b;

    for v_field in select * from jsonb_array_elements(coalesce(p_fields, '[]'::jsonb)) loop
      insert into esign.fields
        (document_id, signer_id, field_type, page, x_ratio, y_ratio, w_ratio, h_ratio, filled)
      values
        (v_doc, case when coalesce((v_field->>'signer_index')::int, 1) = 0 then v_a else v_b end,
         coalesce(v_field->>'field_type', 'signature'),
         coalesce((v_field->>'page')::int, 1),
         (v_field->>'x')::numeric, (v_field->>'y')::numeric,
         (v_field->>'w')::numeric, (v_field->>'h')::numeric,
         coalesce((v_field->>'signer_index')::int, 1) = 0);
    end loop;

    insert into esign.audit_logs (document_id, action, metadata)
    values (v_doc, 'doc_created', jsonb_build_object('bulk', true, 'pair', true, 'batch_id', v_batch, 'file_hash', p_file_hash));
    insert into esign.audit_logs (document_id, signer_id, action, metadata)
    values (v_doc, v_a, 'consent_given', jsonb_build_object('legal_basis', '전자서명법 제3조 당사자 약정', 'presigned', true, 'by', v_uid)),
           (v_doc, v_a, 'sig_completed', jsonb_build_object('method', v_a_method, 'presigned', true, 'by', v_uid,
                                                            'note', '대량발송 보내기 전 갑 서명 (모든 문서에 같은 서명)'));
    insert into esign.audit_logs (document_id, action, metadata)
    values (v_doc, 'sig_requested', jsonb_build_object('bulk', true, 'name', v_row->>'name'));
  end loop;

  return jsonb_build_object(
    'ok', true, 'batch_id', v_batch, 'count', v_n,
    'items', (
      select jsonb_agg(jsonb_build_object(
        'document_id', d.id, 'title', d.title,
        'name', s.name, 'phone', s.phone, 'sign_token', s.sign_token
      ) order by d.created_at)
      from esign.documents d join esign.signers s on s.document_id = d.id and s.order_index = 1
      where d.bulk_batch_id = v_batch));
end $$;
revoke all on function public.esign_create_bulk_pair(text, text, text, text, text, bigint, text, timestamptz, jsonb, jsonb, jsonb, text, boolean) from public, anon;
grant execute on function public.esign_create_bulk_pair(text, text, text, text, text, bigint, text, timestamptz, jsonb, jsonb, jsonb, text, boolean) to authenticated, service_role;

-- 묶음 상세: 미리 서명한 갑은 줄마다 나오지 않게 (명단의 을만)
create or replace function public.esign_get_bulk_batch(p_batch_id uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'esign', 'public', 'pg_temp'
as $function$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED'); end if;
  return jsonb_build_object('ok',true,'items', coalesce((
    select jsonb_agg(jsonb_build_object(
      'document_id', d.id, 'title', d.title, 'status', d.status,
      'name', s.name, 'phone', s.phone, 'sign_token', s.sign_token,
      'signed_at', s.signed_at, 'created_at', d.created_at) order by d.created_at)
    from esign.documents d join esign.signers s on s.document_id = d.id and not coalesce(s.presigned, false)
    where esign.doc_visible(d.owner_id, d.org_id, v_uid) and d.bulk_batch_id = p_batch_id), '[]'::jsonb));
end $function$;

-- 묶음 목록: 갑이 미리 서명한 2인 문서는 처음부터 「진행 중」이므로 대기 수에 함께 센다
create or replace function public.esign_list_bulk_batches()
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'esign', 'public', 'pg_temp'
as $function$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED'); end if;
  return jsonb_build_object('ok',true,'batches', coalesce((
    select jsonb_agg(b order by b->>'created_at' desc) from (
      select jsonb_build_object(
        'batch_id', d.bulk_batch_id,
        'label', min(d.bulk_label),
        'created_at', min(d.created_at),
        'total', count(*),
        'complete', count(*) filter (where d.status='complete'),
        'waiting', count(*) filter (where d.status in ('waiting','progress')),
        'cancelled', count(*) filter (where d.status in ('cancelled','expired'))
      ) as b
      from esign.documents d
      where esign.doc_visible(d.owner_id, d.org_id, v_uid) and d.bulk_batch_id is not null and d.deleted_at is null
      group by d.bulk_batch_id) x), '[]'::jsonb));
end $function$;
