-- ============================================================
-- 문서 재요청 — 요청자가 「어디를 다시 해 달라」는 내용과 함께 다시 서명을 받는다
--
-- 요청자(문서 소유자 또는 같은 조직의 owner · admin)가 서명자를 골라 재요청하면
--   · 이미 서명한 사람은 서명만 되돌린다 (기입 항목 값 · 직접 추가한 항목은 그대로 — 고친 뒤 다시 서명)
--   · 재요청 내용(signers.rerequest_note)이 서명자 화면 맨 위에 보인다
--   · 완료된 문서였다면 완료를 풀고 다시 진행 중으로 (고른 사람이 다시 서명해야 다시 완료)
--   · p_minutes 를 주면 서명 기한을 지금부터 그만큼으로 다시 정한다 (기한이 지났으면 반드시 줘야 한다)
-- 알림톡(리마인드)은 화면이 이 함수가 끝난 뒤 고른 사람에게만 보낸다.
-- 되돌린 서명은 esign.signature_undos 에 남는다 (처음 서명의 감사 기록도 그대로).
-- ============================================================
alter table esign.signers add column if not exists rerequest_note text;
alter table esign.signers add column if not exists rerequest_at timestamptz;
comment on column esign.signers.rerequest_note is '요청자가 재요청하며 남긴 내용 (어디를 다시 해 달라는지)';

create table if not exists esign.signature_undos (
  id          uuid primary key default gen_random_uuid(),
  document_id uuid not null references esign.documents(id) on delete cascade,
  signer_id   uuid not null references esign.signers(id) on delete cascade,
  signed_at   timestamptz,
  sig_method  text,
  undone_at   timestamptz not null default now()
);
alter table esign.signature_undos enable row level security;

create or replace function public.esign_rerequest(
  p_document_id uuid,
  p_sign_tokens text[],
  p_note text,
  p_minutes int default null
)
returns jsonb language plpgsql security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
declare
  v_doc   esign.documents%rowtype;
  v_note  text := left(btrim(coalesce(p_note, '')), 300);
  v_s     esign.signers%rowtype;
  v_n     int := 0;
  v_was_complete boolean;
begin
  if auth.uid() is null or not esign.doc_visible(
       (select owner_id from esign.documents where id = p_document_id),
       (select org_id from esign.documents where id = p_document_id), auth.uid()) then
    return jsonb_build_object('ok', false, 'error', 'FORBIDDEN');
  end if;
  select * into v_doc from esign.documents where id = p_document_id for update;
  if not found or v_doc.deleted_at is not null or v_doc.status = 'cancelled' then
    return jsonb_build_object('ok', false, 'error', 'DOC_CLOSED');
  end if;
  if v_note = '' then
    return jsonb_build_object('ok', false, 'error', 'NOTE_REQUIRED');
  end if;
  if coalesce(array_length(p_sign_tokens, 1), 0) = 0 then
    return jsonb_build_object('ok', false, 'error', 'NO_SIGNERS');
  end if;
  if p_minutes is not null and (p_minutes < 30 or p_minutes > 43200) then
    return jsonb_build_object('ok', false, 'error', 'BAD_MINUTES');
  end if;
  if p_minutes is null and v_doc.deadline is not null and v_doc.deadline < now() then
    return jsonb_build_object('ok', false, 'error', 'NEED_NEW_DEADLINE');
  end if;
  v_was_complete := v_doc.status = 'complete';

  for v_s in select * from esign.signers
              where document_id = p_document_id and sign_token = any(p_sign_tokens) for update loop
    if v_s.status = 'signed' then
      insert into esign.signature_undos (document_id, signer_id, signed_at, sig_method)
      values (v_s.document_id, v_s.id, v_s.signed_at, v_s.sig_method);
      update esign.fields set filled = false where signer_id = v_s.id;
    end if;
    update esign.signers
       set status = case when status = 'signed' then 'viewed' else status end,
           sig_method = case when status = 'signed' then null else sig_method end,
           sig_data = case when status = 'signed' then null else sig_data end,
           consent_agreed = case when status = 'signed' then false else consent_agreed end,
           consent_at = case when status = 'signed' then null else consent_at end,
           signed_at = case when status = 'signed' then null else signed_at end,
           rerequest_note = v_note,
           rerequest_at = now()
     where id = v_s.id;
    v_n := v_n + 1;
  end loop;

  if v_n = 0 then
    return jsonb_build_object('ok', false, 'error', 'NO_SIGNERS');
  end if;

  update esign.documents d
     set status = case when exists (select 1 from esign.signers s where s.document_id = d.id and s.status = 'signed')
                       then 'progress' else 'waiting' end,
         completed_at = null,
         signed_file_path = null,
         deadline = case when p_minutes is not null then now() + make_interval(mins => p_minutes) else d.deadline end
   where d.id = p_document_id;

  return jsonb_build_object('ok', true, 'count', v_n, 'was_complete', v_was_complete,
    'deadline', (select deadline from esign.documents where id = p_document_id));
end $$;
revoke all on function public.esign_rerequest(uuid, text[], text, int) from public, anon;
grant execute on function public.esign_rerequest(uuid, text[], text, int) to authenticated, service_role;

-- 서명자 화면: 재요청 내용 (서명하기 전까지만 보인다)
create or replace function public.esign_rerequest_info(p_token text)
returns jsonb language sql stable security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
  select coalesce((
    select jsonb_build_object('ok', true, 'note', s.rerequest_note, 'at', s.rerequest_at)
      from esign.signers s
     where s.sign_token = p_token and s.status <> 'signed' and s.rerequest_note is not null
     limit 1), jsonb_build_object('ok', true, 'note', null));
$$;
revoke all on function public.esign_rerequest_info(text) from public;
grant execute on function public.esign_rerequest_info(text) to anon, authenticated, service_role;
