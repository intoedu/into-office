-- ============================================================
-- 서명 후 안내 (문구 200자 + 참고 링크)
--
-- 요청자가 문서에 「서명 후 안내」를 남기면, 서명을 마친 서명자에게만 서명 완료 화면과
-- 다시 연 서명 링크에 보인다. 예) 「추가 서류는 아래 링크로 제출해 주세요」 + 설문 · 업로드 링크
--   · 문구 200자까지, 링크는 http(s) 주소만 500자까지. 둘 다 비우면 지운다
--   · 보낸 뒤에도 문서 메뉴에서 고칠 수 있다
-- ============================================================
alter table esign.documents add column if not exists after_note text;
alter table esign.documents add column if not exists after_link text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'documents_after_note_len') then
    alter table esign.documents add constraint documents_after_note_len check (after_note is null or char_length(after_note) <= 200);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'documents_after_link_fmt') then
    alter table esign.documents add constraint documents_after_link_fmt
      check (after_link is null or (char_length(after_link) <= 500 and after_link ~* '^https?://[^[:space:]<>"]+$'));
  end if;
end $$;
comment on column esign.documents.after_note is '서명 후 안내 문구 (서명을 마친 서명자에게만 보인다, 200자)';
comment on column esign.documents.after_link is '서명 후 참고 링크 (http/https)';

-- 요청자: 저장 (둘 다 비우면 지운다)
create or replace function public.esign_set_after_note(p_document_id uuid, p_note text, p_link text)
returns jsonb language plpgsql security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
declare
  v_note text := nullif(btrim(regexp_replace(coalesce(p_note, ''), '\r', '', 'g')), '');
  v_link text := nullif(btrim(coalesce(p_link, '')), '');
begin
  if not esign.can_manage_doc(p_document_id) then
    return jsonb_build_object('ok', false, 'error', 'FORBIDDEN');
  end if;
  if v_note is not null and char_length(v_note) > 200 then
    return jsonb_build_object('ok', false, 'error', 'NOTE_TOO_LONG');
  end if;
  if v_link is not null and (char_length(v_link) > 500 or v_link !~* '^https?://[^[:space:]<>"]+$') then
    return jsonb_build_object('ok', false, 'error', 'BAD_LINK');
  end if;
  update esign.documents set after_note = v_note, after_link = v_link
   where id = p_document_id and deleted_at is null;
  if not found then return jsonb_build_object('ok', false, 'error', 'NOT_FOUND'); end if;
  return jsonb_build_object('ok', true, 'note', v_note, 'link', v_link);
end $$;
revoke all on function public.esign_set_after_note(uuid, text, text) from public, anon;
grant execute on function public.esign_set_after_note(uuid, text, text) to authenticated, service_role;

-- 요청자: 고치기 전에 불러오기
create or replace function public.esign_get_after_note(p_document_id uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
begin
  if not esign.can_manage_doc(p_document_id) then
    return jsonb_build_object('ok', false, 'error', 'FORBIDDEN');
  end if;
  return coalesce((select jsonb_build_object('ok', true, 'note', after_note, 'link', after_link, 'title', title)
                     from esign.documents where id = p_document_id and deleted_at is null),
                  jsonb_build_object('ok', false, 'error', 'NOT_FOUND'));
end $$;
revoke all on function public.esign_get_after_note(uuid) from public, anon;
grant execute on function public.esign_get_after_note(uuid) to authenticated, service_role;

-- 서명자: 서명을 마친 뒤에만
create or replace function public.esign_after_note(p_token text)
returns jsonb language sql stable security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
  select coalesce((
    select jsonb_build_object('ok', true, 'note', d.after_note, 'link', d.after_link)
      from esign.signers s join esign.documents d on d.id = s.document_id
     where s.sign_token = p_token and s.status = 'signed' and d.deleted_at is null
     limit 1), jsonb_build_object('ok', true, 'note', null, 'link', null));
$$;
revoke all on function public.esign_after_note(text) from public;
grant execute on function public.esign_after_note(text) to anon, authenticated, service_role;
