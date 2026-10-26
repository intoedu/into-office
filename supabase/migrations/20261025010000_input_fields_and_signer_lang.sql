-- ============================================================
-- 1) 기입 항목 — 서명과 함께 서명자에게 연락처 · 주소 · 날짜 등을 받는다
-- 2) 서명자 언어 — 외국어 알림톡 · 서명 화면 언어
--
-- 기존 함수(esign_create_document · esign_submit_signature …)는 고치지 않는다.
-- 문서를 만든 직후 esign_set_doc_inputs · esign_set_signer_langs 로 덧붙이고,
-- 서명자는 서명 직전에 esign_submit_inputs 로 값을 낸다.
-- 필수 항목을 비운 채 서명하면 signers 트리거가 서명을 막는다 (화면을 우회해도 막힘).
-- ============================================================

-- ---------- 기입 항목 ----------
create table if not exists esign.input_fields (
  id          uuid primary key default gen_random_uuid(),
  document_id uuid not null references esign.documents(id) on delete cascade,
  signer_id   uuid not null references esign.signers(id) on delete cascade,
  kind        text not null
              check (kind in ('phone','address','date','email','name','number','text','custom')),
  label       text not null check (char_length(label) between 1 and 30),
  purpose     text check (purpose is null or char_length(purpose) <= 80),
  -- digits 숫자만 · letters 글자만(숫자 불가) · mixed 글자+숫자 · phone · email · date
  input_mode  text not null
              check (input_mode in ('digits','letters','mixed','phone','email','date')),
  required    boolean not null default true,
  max_len     int not null default 100 check (max_len between 1 and 300),
  page        int not null default 1,
  x_ratio     numeric(10,8) not null,
  y_ratio     numeric(10,8) not null,
  w_ratio     numeric(10,8) not null,
  h_ratio     numeric(10,8) not null,
  sort_order  int not null default 0,
  value       text,
  filled_at   timestamptz,
  created_at  timestamptz not null default now()
);
create index if not exists idx_esign_inputs_doc on esign.input_fields(document_id, sort_order);
create index if not exists idx_esign_inputs_signer on esign.input_fields(signer_id);
alter table esign.input_fields enable row level security;   -- 정책 없음: 아래 함수로만 접근
comment on table esign.input_fields is '서명자가 서명과 함께 적는 기입 항목(연락처 · 주소 · 날짜 · 사용자 정의). 값은 서명 전까지 본인만 고칠 수 있다';

-- ---------- 서명자 언어 ----------
alter table esign.signers add column if not exists lang text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'signers_lang_check') then
    alter table esign.signers add constraint signers_lang_check
      check (lang is null or lang in ('ko','en','zh','ja','vi'));
  end if;
end $$;
comment on column esign.signers.lang is '서명자 언어. 알림톡 템플릿 · 서명 화면 기본 언어 (null = 한국어)';

-- ---------- 값 검사 ----------
create or replace function esign.input_value_ok(p_mode text, p_value text, p_max int)
returns boolean language plpgsql immutable
set search_path to 'esign', 'public', 'pg_temp'
as $$
begin
  if p_value is null or char_length(btrim(p_value)) not between 1 and coalesce(p_max, 100) then
    return false;
  end if;
  return case p_mode
    when 'digits'  then p_value ~ '^[0-9]+$'
    when 'phone'   then p_value ~ '^0[0-9]{8,10}$'
    when 'letters' then p_value !~ '[0-9]'
    when 'mixed'   then true
    when 'email'   then p_value ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
    when 'date'    then p_value ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
                    and to_char(p_value::date, 'YYYY-MM-DD') = p_value
    else false
  end;
exception when others then
  return false;   -- 2026-02-30 같은 없는 날짜
end $$;

-- 요청자인지 — 문서 목록 · 서명본과 같은 규칙(esign.doc_visible: 소유자, 또는 같은 조직의 owner · admin)
create or replace function esign.can_manage_doc(p_document_id uuid)
returns boolean language sql stable security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
  select exists (
    select 1 from esign.documents d
     where d.id = p_document_id
       and esign.doc_visible(d.owner_id, d.org_id, auth.uid()));
$$;
revoke all on function esign.can_manage_doc(uuid) from public, anon;
grant execute on function esign.can_manage_doc(uuid) to authenticated, service_role;

-- 화면이 기능 준비 여부를 미리 확인한다 (이 함수가 없으면 기입 항목을 보내지 않는다)
create or replace function public.esign_inputs_ready()
returns jsonb language sql stable
as $$ select jsonb_build_object('ok', true, 'version', 1); $$;
grant execute on function public.esign_inputs_ready() to anon, authenticated, service_role;

-- ---------- 요청자: 기입 항목 저장 (문서 만든 직후 1회) ----------
-- p_fields: [{ sign_token, kind, label, purpose, mode, required, max_len, page, x, y, w, h }]
create or replace function public.esign_set_doc_inputs(p_document_id uuid, p_fields jsonb)
returns jsonb language plpgsql security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
declare
  v_doc  esign.documents%rowtype;
  v_f    jsonb;
  v_sid  uuid;
  v_kind text; v_mode text; v_label text;
  v_i    int := 0;
begin
  if not esign.can_manage_doc(p_document_id) then
    return jsonb_build_object('ok', false, 'error', 'FORBIDDEN');
  end if;
  select * into v_doc from esign.documents where id = p_document_id;
  if v_doc.status in ('complete','cancelled','expired') then
    return jsonb_build_object('ok', false, 'error', 'DOC_CLOSED');
  end if;
  if exists (select 1 from esign.signers where document_id = p_document_id and status = 'signed') then
    return jsonb_build_object('ok', false, 'error', 'ALREADY_SIGNED');
  end if;
  if exists (select 1 from esign.input_fields where document_id = p_document_id) then
    return jsonb_build_object('ok', false, 'error', 'ALREADY_SET');
  end if;
  if jsonb_typeof(p_fields) <> 'array' or jsonb_array_length(p_fields) > 60 then
    return jsonb_build_object('ok', false, 'error', 'BAD_FIELDS');
  end if;

  for v_f in select * from jsonb_array_elements(p_fields) loop
    select s.id into v_sid from esign.signers s
     where s.document_id = p_document_id and s.sign_token = v_f->>'sign_token';
    if v_sid is null then
      raise exception 'SIGNER_NOT_IN_DOC';
    end if;
    v_kind  := coalesce(v_f->>'kind', 'custom');
    v_mode  := case v_kind
                 when 'phone' then 'phone' when 'email' then 'email' when 'date' then 'date'
                 when 'number' then 'digits' when 'name' then 'letters'
                 when 'address' then 'mixed' when 'text' then 'mixed'
                 else coalesce(nullif(v_f->>'mode', ''), 'mixed') end;
    v_label := left(btrim(coalesce(v_f->>'label', '')), 30);
    if v_label = '' then v_label := '기입 항목'; end if;

    insert into esign.input_fields
      (document_id, signer_id, kind, label, purpose, input_mode, required, max_len,
       page, x_ratio, y_ratio, w_ratio, h_ratio, sort_order)
    values
      (p_document_id, v_sid, v_kind, v_label,
       nullif(left(btrim(coalesce(v_f->>'purpose', '')), 80), ''),
       v_mode, coalesce((v_f->>'required')::boolean, true),
       least(300, greatest(1, coalesce((v_f->>'max_len')::int, 100))),
       greatest(1, coalesce((v_f->>'page')::int, 1)),
       least(1, greatest(0, coalesce((v_f->>'x')::numeric, 0))),
       least(1, greatest(0, coalesce((v_f->>'y')::numeric, 0))),
       least(1, greatest(0, coalesce((v_f->>'w')::numeric, 0.2))),
       least(1, greatest(0, coalesce((v_f->>'h')::numeric, 0.04))),
       v_i);
    v_i := v_i + 1;
  end loop;

  return jsonb_build_object('ok', true, 'count', v_i);
end $$;
revoke all on function public.esign_set_doc_inputs(uuid, jsonb) from public, anon;
grant execute on function public.esign_set_doc_inputs(uuid, jsonb) to authenticated, service_role;

-- ---------- 요청자: 서명자 언어 저장 ----------
-- p_langs: [{ sign_token, lang }]  (lang: ko · en · zh · ja · vi)
create or replace function public.esign_set_signer_langs(p_document_id uuid, p_langs jsonb)
returns jsonb language plpgsql security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
declare v_n int := 0; v_l jsonb;
begin
  if not esign.can_manage_doc(p_document_id) then
    return jsonb_build_object('ok', false, 'error', 'FORBIDDEN');
  end if;
  if jsonb_typeof(p_langs) <> 'array' then
    return jsonb_build_object('ok', false, 'error', 'BAD_LANGS');
  end if;
  for v_l in select * from jsonb_array_elements(p_langs) loop
    if coalesce(v_l->>'lang', 'ko') not in ('ko','en','zh','ja','vi') then continue; end if;
    update esign.signers
       set lang = nullif(v_l->>'lang', 'ko')
     where document_id = p_document_id and sign_token = v_l->>'sign_token';
    if found then v_n := v_n + 1; end if;
  end loop;
  return jsonb_build_object('ok', true, 'count', v_n);
end $$;
revoke all on function public.esign_set_signer_langs(uuid, jsonb) from public, anon;
grant execute on function public.esign_set_signer_langs(uuid, jsonb) to authenticated, service_role;

-- ---------- 서명자: 내 기입 항목 · 언어 ----------
-- 서명 전에는 본인 항목만, 문서가 완료되면 전원의 항목(완료본 합성용)을 돌려준다.
create or replace function public.esign_sign_inputs(p_token text)
returns jsonb language sql stable security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
  with me as (
    select s.id, s.document_id, s.lang, d.status as doc_status
      from esign.signers s join esign.documents d on d.id = s.document_id
     where s.sign_token = p_token
     limit 1)
  select case when not exists (select 1 from me)
    then jsonb_build_object('ok', false, 'error', 'INVALID_TOKEN')
    else jsonb_build_object(
      'ok', true,
      'lang', (select lang from me),
      'fields', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'id', f.id, 'signer_id', f.signer_id, 'mine', f.signer_id = me.id,
                 'kind', f.kind, 'label', f.label, 'purpose', f.purpose, 'mode', f.input_mode,
                 'required', f.required, 'max_len', f.max_len,
                 'page', f.page, 'x', f.x_ratio, 'y', f.y_ratio, 'w', f.w_ratio, 'h', f.h_ratio,
                 'value', f.value) order by f.sort_order)
          from esign.input_fields f, me
         where f.document_id = me.document_id
           and (f.signer_id = me.id or me.doc_status = 'complete')), '[]'::jsonb))
  end;
$$;
revoke all on function public.esign_sign_inputs(text) from public;
grant execute on function public.esign_sign_inputs(text) to anon, authenticated, service_role;

-- ---------- 서명자: 값 제출 (서명 직전) ----------
-- p_values: { "<field id>": "값", ... }  — 빈 값은 비운다 (필수 항목이면 서명 때 막힌다)
create or replace function public.esign_submit_inputs(p_token text, p_values jsonb)
returns jsonb language plpgsql security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
declare
  v_s   esign.signers%rowtype;
  v_doc esign.documents%rowtype;
  v_f   esign.input_fields%rowtype;
  v_val text;
  v_bad jsonb := '[]'::jsonb;
begin
  select * into v_s from esign.signers where sign_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'error', 'INVALID_TOKEN'); end if;
  if v_s.status = 'signed' then return jsonb_build_object('ok', false, 'error', 'ALREADY_SIGNED'); end if;
  select * into v_doc from esign.documents where id = v_s.document_id;
  if v_doc.status in ('complete','cancelled','expired') then
    return jsonb_build_object('ok', false, 'error', 'DOC_CLOSED');
  end if;
  if v_doc.deadline is not null and v_doc.deadline < now() then
    return jsonb_build_object('ok', false, 'error', 'DEADLINE_PASSED');
  end if;
  if jsonb_typeof(p_values) <> 'object' then
    return jsonb_build_object('ok', false, 'error', 'BAD_VALUES');
  end if;

  for v_f in select * from esign.input_fields where signer_id = v_s.id order by sort_order loop
    v_val := nullif(btrim(coalesce(p_values->>(v_f.id::text), '')), '');
    if v_f.input_mode = 'phone' and v_val is not null then
      v_val := regexp_replace(v_val, '[^0-9]', '', 'g');
    end if;
    if v_val is null then
      if v_f.required then v_bad := v_bad || jsonb_build_object('id', v_f.id, 'error', 'REQUIRED'); end if;
      update esign.input_fields set value = null, filled_at = null where id = v_f.id;
    elsif not esign.input_value_ok(v_f.input_mode, v_val, v_f.max_len) then
      v_bad := v_bad || jsonb_build_object('id', v_f.id, 'error', 'INVALID');
    else
      update esign.input_fields set value = v_val, filled_at = now() where id = v_f.id;
    end if;
  end loop;

  if jsonb_array_length(v_bad) > 0 then
    return jsonb_build_object('ok', false, 'error', 'INPUTS_INVALID', 'fields', v_bad);
  end if;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.esign_submit_inputs(text, jsonb) from public;
grant execute on function public.esign_submit_inputs(text, jsonb) to anon, authenticated, service_role;

-- ---------- 요청자: 문서의 기입 항목 · 값 ----------
create or replace function public.esign_doc_inputs(p_document_id uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
begin
  if not esign.can_manage_doc(p_document_id) then
    return jsonb_build_object('ok', false, 'error', 'FORBIDDEN');
  end if;
  return jsonb_build_object('ok', true, 'fields', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', f.id, 'signer_id', f.signer_id, 'signer_name', s.name,
             'kind', f.kind, 'label', f.label, 'purpose', f.purpose, 'mode', f.input_mode,
             'required', f.required, 'page', f.page,
             'x', f.x_ratio, 'y', f.y_ratio, 'w', f.w_ratio, 'h', f.h_ratio,
             'value', f.value, 'filled_at', f.filled_at) order by s.order_index, f.sort_order)
      from esign.input_fields f join esign.signers s on s.id = f.signer_id
     where f.document_id = p_document_id), '[]'::jsonb));
end $$;
revoke all on function public.esign_doc_inputs(uuid) from public, anon;
grant execute on function public.esign_doc_inputs(uuid) to authenticated, service_role;

-- ---------- 알림톡: 서명자 언어 (서버 전용) ----------
create or replace function public.esign_signer_langs(p_document_id uuid)
returns jsonb language sql stable security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
  select coalesce(jsonb_object_agg(s.sign_token, coalesce(s.lang, 'ko')), '{}'::jsonb)
    from esign.signers s where s.document_id = p_document_id;
$$;
revoke all on function public.esign_signer_langs(uuid) from public, anon, authenticated;
grant execute on function public.esign_signer_langs(uuid) to service_role;

-- ---------- 필수 항목을 비운 채 서명하지 못하게 ----------
create or replace function esign.block_sign_without_inputs()
returns trigger language plpgsql
set search_path to 'esign', 'public', 'pg_temp'
as $$
begin
  if new.status = 'signed' and old.status is distinct from 'signed'
     and exists (select 1 from esign.input_fields f
                  where f.signer_id = new.id and f.required and f.value is null) then
    raise exception 'INPUTS_REQUIRED' using hint = '필수 기입 항목을 먼저 입력해야 서명할 수 있습니다';
  end if;
  return new;
end $$;

create or replace trigger trg_block_sign_without_inputs
  before update of status on esign.signers
  for each row execute function esign.block_sign_without_inputs();
