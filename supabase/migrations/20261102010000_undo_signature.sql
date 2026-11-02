-- ============================================================
-- 서명 되돌리기 (서명자가 빠뜨린 것을 고치기 위해)
--
-- 서명자가 서명한 뒤 30분 안에, 문서가 아직 완료되지 않았을 때(다른 서명자가 남아 있을 때)
-- 자기 서명만 되돌린다. 기입 항목 값 · 직접 추가한 항목은 지우지 않는다 — 고친 뒤 다시 서명한다.
-- 되돌린 기록은 esign.signature_undos 에 남는다 (처음 서명의 감사 기록도 그대로 남는다).
-- 마지막 서명자는 서명과 동시에 문서가 완료되므로 되돌릴 수 없다 (화면이 서명 전에 한 번 더 확인한다).
-- ============================================================
create table if not exists esign.signature_undos (
  id          uuid primary key default gen_random_uuid(),
  document_id uuid not null references esign.documents(id) on delete cascade,
  signer_id   uuid not null references esign.signers(id) on delete cascade,
  signed_at   timestamptz,
  sig_method  text,
  undone_at   timestamptz not null default now()
);
create index if not exists idx_esign_undos_doc on esign.signature_undos(document_id, undone_at);
alter table esign.signature_undos enable row level security;   -- 정책 없음: 함수로만 기록
comment on table esign.signature_undos is '서명자가 서명 후 30분 안에 서명을 되돌린 기록';

create or replace function public.esign_undo_signature(p_token text)
returns jsonb language plpgsql security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
declare
  v_s   esign.signers%rowtype;
  v_doc esign.documents%rowtype;
begin
  select * into v_s from esign.signers where sign_token = p_token for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'INVALID_TOKEN'); end if;
  if v_s.status <> 'signed' then return jsonb_build_object('ok', false, 'error', 'NOT_SIGNED'); end if;

  select * into v_doc from esign.documents where id = v_s.document_id for update;
  if v_doc.status = 'complete' then
    return jsonb_build_object('ok', false, 'error', 'DOC_COMPLETE');
  end if;
  if v_doc.status in ('cancelled', 'expired') or v_doc.deleted_at is not null then
    return jsonb_build_object('ok', false, 'error', 'DOC_CLOSED');
  end if;
  if v_doc.deadline is not null and v_doc.deadline < now() then
    return jsonb_build_object('ok', false, 'error', 'DEADLINE_PASSED');
  end if;
  if v_s.signed_at is null or v_s.signed_at < now() - interval '30 minutes' then
    return jsonb_build_object('ok', false, 'error', 'UNDO_TIME_PASSED');
  end if;

  insert into esign.signature_undos (document_id, signer_id, signed_at, sig_method)
  values (v_s.document_id, v_s.id, v_s.signed_at, v_s.sig_method);

  update esign.signers
     set status = 'viewed', sig_method = null, sig_data = null,
         consent_agreed = false, consent_at = null, signed_at = null
   where id = v_s.id;

  update esign.fields set filled = false where signer_id = v_s.id;

  update esign.documents d
     set status = case when exists (select 1 from esign.signers s where s.document_id = d.id and s.status = 'signed')
                       then 'progress' else 'waiting' end
   where d.id = v_doc.id;

  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.esign_undo_signature(text) from public;
grant execute on function public.esign_undo_signature(text) to anon, authenticated, service_role;
