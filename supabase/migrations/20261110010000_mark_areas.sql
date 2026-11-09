-- ============================================================
-- 서명자 직접 추가 영역
--
-- 요청자가 문서 위에 서명자별 「직접 추가 영역」(점선 상자)을 놓으면, 그 서명자는
-- 그 영역 안에만 체크 · 텍스트 · 서명란을 넣을 수 있다. 영역을 놓지 않으면 지금처럼 문서 어디에나.
--   · 영역은 signers.mark_areas = [{ page, x, y, w, h }] (페이지 대비 0~1 비율, 최대 20개)
--   · esign_set_signer_perms 의 각 항목에 areas 를 주면 함께 저장한다 (영역이 있으면 허락도 켠다)
--   · 영역 밖 항목은 signer_marks 트리거가 막는다 (esign_submit_marks 는 그대로)
-- ============================================================
alter table esign.signers add column if not exists mark_areas jsonb not null default '[]'::jsonb;
comment on column esign.signers.mark_areas is '서명자 직접 추가 영역 [{page,x,y,w,h}] — 비어 있으면 문서 어디에나';

-- 영역 정리: 숫자만, 0~1 안으로, 너무 작은 영역은 버린다, 최대 20개
create or replace function esign.clean_mark_areas(p jsonb)
returns jsonb language sql immutable
as $$
  select coalesce(jsonb_agg(a order by ord), '[]'::jsonb) from (
    select ord, jsonb_build_object(
             'page', greatest(1, (e->>'page')::int),
             'x', least(1, greatest(0, (e->>'x')::numeric)),
             'y', least(1, greatest(0, (e->>'y')::numeric)),
             'w', least(1, greatest(0, (e->>'w')::numeric)),
             'h', least(1, greatest(0, (e->>'h')::numeric))) as a
      from jsonb_array_elements(case when jsonb_typeof(p) = 'array' then p else '[]'::jsonb end) with ordinality as t(e, ord)
     where jsonb_typeof(e) = 'object'
       and (e->>'page') ~ '^[0-9]{1,4}$'
       and (e->>'x') ~ '^-?[0-9.]+$' and (e->>'y') ~ '^-?[0-9.]+$'
       and (e->>'w') ~ '^[0-9.]+$' and (e->>'h') ~ '^[0-9.]+$'
       and (e->>'w')::numeric >= 0.01 and (e->>'h')::numeric >= 0.005
     order by ord
     limit 20) z;
$$;

-- 항목이 영역 중 하나에 들어가는지 (화면 반올림을 생각해 0.003 여유)
create or replace function esign.mark_in_areas(p_areas jsonb, p_page int, p_x numeric, p_y numeric, p_w numeric, p_h numeric)
returns boolean language sql immutable
as $$
  select coalesce(jsonb_array_length(p_areas), 0) = 0 or exists (
    select 1 from jsonb_array_elements(p_areas) a
     where (a->>'page')::int = p_page
       and p_x >= (a->>'x')::numeric - 0.003
       and p_y >= (a->>'y')::numeric - 0.003
       and p_x + p_w <= (a->>'x')::numeric + (a->>'w')::numeric + 0.003
       and p_y + p_h <= (a->>'y')::numeric + (a->>'h')::numeric + 0.003);
$$;

create or replace function esign.trg_mark_in_area()
returns trigger language plpgsql
set search_path to 'esign', 'public', 'pg_temp'
as $$
declare v_areas jsonb;
begin
  select mark_areas into v_areas from esign.signers where id = new.signer_id;
  if not esign.mark_in_areas(coalesce(v_areas, '[]'::jsonb), new.page, new.x_ratio, new.y_ratio, new.w_ratio, new.h_ratio) then
    raise exception 'OUTSIDE_AREA';
  end if;
  return new;
end $$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'trg_mark_in_area' and tgrelid = 'esign.signer_marks'::regclass) then
    create trigger trg_mark_in_area before insert or update of page, x_ratio, y_ratio, w_ratio, h_ratio on esign.signer_marks
      for each row execute function esign.trg_mark_in_area();
  end if;
end $$;

-- 화면의 기능 확인 — version 3 부터 직접 추가 영역 지원
create or replace function public.esign_inputs_ready()
returns jsonb language sql stable
as $$ select jsonb_build_object('ok', true, 'version', 3, 'marks', true, 'mark_areas', true); $$;
grant execute on function public.esign_inputs_ready() to anon, authenticated, service_role;

-- 요청자: 서명자별 직접 추가 허락 + 영역
-- p_perms: [{ sign_token, allow_marks, areas? }] — areas 를 주지 않으면 영역은 그대로 둔다
create or replace function public.esign_set_signer_perms(p_document_id uuid, p_perms jsonb)
returns jsonb language plpgsql security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
declare v_n int := 0; v_p jsonb; v_areas jsonb;
begin
  if not esign.can_manage_doc(p_document_id) then
    return jsonb_build_object('ok', false, 'error', 'FORBIDDEN');
  end if;
  if jsonb_typeof(p_perms) <> 'array' then
    return jsonb_build_object('ok', false, 'error', 'BAD_PERMS');
  end if;
  for v_p in select * from jsonb_array_elements(p_perms) loop
    v_areas := case when v_p ? 'areas' then esign.clean_mark_areas(v_p->'areas') end;
    update esign.signers
       set allow_marks = coalesce((v_p->>'allow_marks')::boolean, false) or coalesce(jsonb_array_length(v_areas), 0) > 0,
           mark_areas = coalesce(v_areas, mark_areas)
     where document_id = p_document_id and sign_token = v_p->>'sign_token' and status <> 'signed';
    if found then v_n := v_n + 1; end if;
  end loop;
  return jsonb_build_object('ok', true, 'count', v_n);
end $$;
revoke all on function public.esign_set_signer_perms(uuid, jsonb) from public, anon;
grant execute on function public.esign_set_signer_perms(uuid, jsonb) to authenticated, service_role;

-- 서명자: 허락 여부 · 영역 · 내 항목 (완료 문서면 전원 항목)
create or replace function public.esign_sign_marks(p_token text)
returns jsonb language sql stable security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
  with me as (
    select s.id, s.document_id, s.allow_marks, s.mark_areas, d.status as doc_status
      from esign.signers s join esign.documents d on d.id = s.document_id
     where s.sign_token = p_token
     limit 1)
  select case when not exists (select 1 from me)
    then jsonb_build_object('ok', false, 'error', 'INVALID_TOKEN')
    else jsonb_build_object(
      'ok', true,
      'allow', (select allow_marks from me),
      'areas', (select coalesce(mark_areas, '[]'::jsonb) from me),
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
