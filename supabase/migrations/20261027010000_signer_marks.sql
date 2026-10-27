-- ============================================================
-- 서명자 직접 추가 (체크 · 텍스트 상자 · 서명란)
--
-- 요청자가 서명자별로 허락하면(signers.allow_marks) 그 서명자는 문서 어디에나
-- 체크 · 텍스트 · 서명란을 직접 놓을 수 있다. 서명 직전에 esign_submit_marks 로 내고,
-- 서명을 마친 뒤에는 고칠 수 없다. 요청자는 항목마다 확인(reviewed_at)한다.
-- ============================================================

alter table esign.signers add column if not exists allow_marks boolean not null default false;
comment on column esign.signers.allow_marks is '요청자가 허락하면 서명자가 체크 · 텍스트 · 서명란을 직접 추가할 수 있다';

create table if not exists esign.signer_marks (
  id          uuid primary key default gen_random_uuid(),
  document_id uuid not null references esign.documents(id) on delete cascade,
  signer_id   uuid not null references esign.signers(id) on delete cascade,
  kind        text not null check (kind in ('check','text','signature')),
  page        int not null default 1,
  x_ratio     numeric(10,8) not null,
  y_ratio     numeric(10,8) not null,
  w_ratio     numeric(10,8) not null,
  h_ratio     numeric(10,8) not null,
  value       text check (value is null or char_length(value) <= 200),
  sort_order  int not null default 0,
  created_at  timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid
);
create index if not exists idx_esign_marks_doc on esign.signer_marks(document_id, sort_order);
create index if not exists idx_esign_marks_signer on esign.signer_marks(signer_id);
alter table esign.signer_marks enable row level security;   -- 정책 없음: 아래 함수로만 접근
comment on table esign.signer_marks is '서명자가 직접 추가한 체크 · 텍스트 · 서명란. 요청자가 항목마다 확인한다';

-- 화면의 기능 확인 — version 2 부터 서명자 직접 추가 지원
create or replace function public.esign_inputs_ready()
returns jsonb language sql stable
as $$ select jsonb_build_object('ok', true, 'version', 2, 'marks', true); $$;
grant execute on function public.esign_inputs_ready() to anon, authenticated, service_role;

-- ---------- 요청자: 서명자별 직접 추가 허락 ----------
-- p_perms: [{ sign_token, allow_marks }]
create or replace function public.esign_set_signer_perms(p_document_id uuid, p_perms jsonb)
returns jsonb language plpgsql security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
declare v_n int := 0; v_p jsonb;
begin
  if not esign.can_manage_doc(p_document_id) then
    return jsonb_build_object('ok', false, 'error', 'FORBIDDEN');
  end if;
  if jsonb_typeof(p_perms) <> 'array' then
    return jsonb_build_object('ok', false, 'error', 'BAD_PERMS');
  end if;
  for v_p in select * from jsonb_array_elements(p_perms) loop
    update esign.signers
       set allow_marks = coalesce((v_p->>'allow_marks')::boolean, false)
     where document_id = p_document_id and sign_token = v_p->>'sign_token' and status <> 'signed';
    if found then v_n := v_n + 1; end if;
  end loop;
  return jsonb_build_object('ok', true, 'count', v_n);
end $$;
revoke all on function public.esign_set_signer_perms(uuid, jsonb) from public, anon;
grant execute on function public.esign_set_signer_perms(uuid, jsonb) to authenticated, service_role;

-- ---------- 서명자: 허락 여부와 내 항목 ----------
-- 서명 전에는 내 항목만, 문서가 완료되면 전원 항목(완료본 합성용)을 돌려준다.
create or replace function public.esign_sign_marks(p_token text)
returns jsonb language sql stable security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
  with me as (
    select s.id, s.document_id, s.allow_marks, d.status as doc_status
      from esign.signers s join esign.documents d on d.id = s.document_id
     where s.sign_token = p_token
     limit 1)
  select case when not exists (select 1 from me)
    then jsonb_build_object('ok', false, 'error', 'INVALID_TOKEN')
    else jsonb_build_object(
      'ok', true,
      'allow', (select allow_marks from me),
      'marks', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'id', m.id, 'signer_id', m.signer_id, 'mine', m.signer_id = me.id, 'kind', m.kind,
                 'page', m.page, 'x', m.x_ratio, 'y', m.y_ratio, 'w', m.w_ratio, 'h', m.h_ratio,
                 'value', m.value) order by m.sort_order)
          from esign.signer_marks m, me
         where m.document_id = me.document_id
           and (m.signer_id = me.id or me.doc_status = 'complete')), '[]'::jsonb))
  end;
$$;
revoke all on function public.esign_sign_marks(text) from public;
grant execute on function public.esign_sign_marks(text) to anon, authenticated, service_role;

-- ---------- 서명자: 추가한 항목 제출 (서명 직전, 다시 내면 통째로 바뀐다) ----------
-- p_marks: [{ kind, page, x, y, w, h, value }]
create or replace function public.esign_submit_marks(p_token text, p_marks jsonb)
returns jsonb language plpgsql security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
declare
  v_s   esign.signers%rowtype;
  v_doc esign.documents%rowtype;
  v_m   jsonb;
  v_val text;
  v_i   int := 0;
begin
  select * into v_s from esign.signers where sign_token = p_token;
  if not found then return jsonb_build_object('ok', false, 'error', 'INVALID_TOKEN'); end if;
  if v_s.status = 'signed' then return jsonb_build_object('ok', false, 'error', 'ALREADY_SIGNED'); end if;
  if not v_s.allow_marks then return jsonb_build_object('ok', false, 'error', 'NOT_ALLOWED'); end if;
  select * into v_doc from esign.documents where id = v_s.document_id;
  if v_doc.status in ('complete','cancelled','expired') then
    return jsonb_build_object('ok', false, 'error', 'DOC_CLOSED');
  end if;
  if v_doc.deadline is not null and v_doc.deadline < now() then
    return jsonb_build_object('ok', false, 'error', 'DEADLINE_PASSED');
  end if;
  if jsonb_typeof(p_marks) <> 'array' or jsonb_array_length(p_marks) > 50 then
    return jsonb_build_object('ok', false, 'error', 'BAD_MARKS');
  end if;

  delete from esign.signer_marks where signer_id = v_s.id;

  for v_m in select * from jsonb_array_elements(p_marks) loop
    if coalesce(v_m->>'kind', '') not in ('check','text','signature') then
      raise exception 'BAD_MARK_KIND';
    end if;
    v_val := case when v_m->>'kind' = 'text' then nullif(btrim(left(coalesce(v_m->>'value', ''), 200)), '') end;
    if v_m->>'kind' = 'text' and v_val is null then
      raise exception 'EMPTY_TEXT';
    end if;
    insert into esign.signer_marks
      (document_id, signer_id, kind, page, x_ratio, y_ratio, w_ratio, h_ratio, value, sort_order)
    values
      (v_s.document_id, v_s.id, v_m->>'kind',
       greatest(1, coalesce((v_m->>'page')::int, 1)),
       least(1, greatest(0, coalesce((v_m->>'x')::numeric, 0))),
       least(1, greatest(0, coalesce((v_m->>'y')::numeric, 0))),
       least(1, greatest(0.005, coalesce((v_m->>'w')::numeric, 0.05))),
       least(1, greatest(0.005, coalesce((v_m->>'h')::numeric, 0.03))),
       v_val, v_i);
    v_i := v_i + 1;
  end loop;

  return jsonb_build_object('ok', true, 'count', v_i);
end $$;
revoke all on function public.esign_submit_marks(text, jsonb) from public;
grant execute on function public.esign_submit_marks(text, jsonb) to anon, authenticated, service_role;

-- ---------- 요청자: 문서의 추가 항목 ----------
create or replace function public.esign_doc_marks(p_document_id uuid)
returns jsonb language plpgsql stable security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
begin
  if not esign.can_manage_doc(p_document_id) then
    return jsonb_build_object('ok', false, 'error', 'FORBIDDEN');
  end if;
  return jsonb_build_object('ok', true, 'marks', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', m.id, 'signer_id', m.signer_id, 'signer_name', s.name, 'signer_status', s.status,
             'signer_index', s.order_index, 'kind', m.kind, 'page', m.page,
             'x', m.x_ratio, 'y', m.y_ratio, 'w', m.w_ratio, 'h', m.h_ratio,
             'value', m.value, 'created_at', m.created_at, 'reviewed_at', m.reviewed_at)
             order by s.order_index, m.page, m.y_ratio, m.x_ratio)
      from esign.signer_marks m join esign.signers s on s.id = m.signer_id
     where m.document_id = p_document_id), '[]'::jsonb));
end $$;
revoke all on function public.esign_doc_marks(uuid) from public, anon;
grant execute on function public.esign_doc_marks(uuid) to authenticated, service_role;

-- ---------- 요청자: 항목 확인 표시 ----------
create or replace function public.esign_review_marks(p_document_id uuid, p_mark_ids uuid[], p_reviewed boolean)
returns jsonb language plpgsql security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
declare v_n int;
begin
  if not esign.can_manage_doc(p_document_id) then
    return jsonb_build_object('ok', false, 'error', 'FORBIDDEN');
  end if;
  update esign.signer_marks
     set reviewed_at = case when p_reviewed then now() end,
         reviewed_by = case when p_reviewed then auth.uid() end
   where document_id = p_document_id and id = any(p_mark_ids);
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'count', v_n);
end $$;
revoke all on function public.esign_review_marks(uuid, uuid[], boolean) from public, anon;
grant execute on function public.esign_review_marks(uuid, uuid[], boolean) to authenticated, service_role;

-- ---------- 요청자: 확인할 항목이 남은 문서 { document_id: 건수 } ----------
-- 서명을 마친 서명자의 항목만 센다 (서명 전 항목은 아직 바뀔 수 있다)
create or replace function public.esign_marks_pending()
returns jsonb language sql stable security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
  select coalesce(jsonb_object_agg(x.document_id, x.n), '{}'::jsonb)
    from (select m.document_id, count(*) as n
            from esign.signer_marks m
            join esign.signers s on s.id = m.signer_id and s.status = 'signed'
            join esign.documents d on d.id = m.document_id
           where m.reviewed_at is null
             and esign.doc_visible(d.owner_id, d.org_id, auth.uid())
           group by m.document_id) x;
$$;
revoke all on function public.esign_marks_pending() from public, anon;
grant execute on function public.esign_marks_pending() to authenticated, service_role;
