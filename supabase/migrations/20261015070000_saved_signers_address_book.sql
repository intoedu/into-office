-- 서명자 주소록: 계정마다 자주 쓰는 서명자를 저장해 두고 서명 요청 때 불러온다.
create table if not exists esign.saved_signers (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references auth.users(id) on delete cascade,
  name        text not null check (length(trim(name)) between 1 and 50),
  phone       text not null check (length(regexp_replace(phone, '[^0-9]', '', 'g')) between 9 and 15),
  memo        text check (memo is null or length(memo) <= 100),
  created_at  timestamptz not null default now()
);
comment on table esign.saved_signers is '계정별 서명자 주소록. 본인만 조회·추가·삭제 (public RPC 경유)';

create unique index if not exists idx_saved_signers_uniq
  on esign.saved_signers (owner_id, name, (regexp_replace(phone, '[^0-9]', '', 'g')));
create index if not exists idx_saved_signers_owner on esign.saved_signers (owner_id, name);

-- 테이블 직접 접근은 막고 함수로만 다룬다 (RLS 켜고 정책 없음)
alter table esign.saved_signers enable row level security;

create or replace function public.esign_saved_signers_list()
returns jsonb language plpgsql stable security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
begin
  if auth.uid() is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED'); end if;
  return jsonb_build_object('ok', true, 'items', coalesce((
    select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'phone', s.phone,
                                        'memo', s.memo, 'created_at', s.created_at)
                     order by s.name, s.created_at)
      from esign.saved_signers s where s.owner_id = auth.uid()), '[]'::jsonb));
end $$;

-- 여러 명을 한 번에 저장한다. 이미 있는 사람(같은 이름 + 같은 번호)은 건너뛴다.
create or replace function public.esign_saved_signers_add(p_items jsonb)
returns jsonb language plpgsql security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
declare v_uid uuid := auth.uid(); v_it jsonb; v_added int := 0; v_skipped int := 0; v_total int;
        v_name text; v_phone text; v_memo text;
begin
  if v_uid is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED'); end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    return jsonb_build_object('ok',false,'error','ITEMS_REQUIRED');
  end if;
  select count(*) into v_total from esign.saved_signers where owner_id = v_uid;

  for v_it in select * from jsonb_array_elements(p_items) loop
    v_name  := trim(coalesce(v_it->>'name',''));
    v_phone := trim(coalesce(v_it->>'phone',''));
    v_memo  := nullif(trim(coalesce(v_it->>'memo','')),'');
    if v_name = '' or length(v_name) > 50
       or length(regexp_replace(v_phone,'[^0-9]','','g')) not between 9 and 15 then
      v_skipped := v_skipped + 1; continue;
    end if;
    if v_total + v_added >= 500 then
      return jsonb_build_object('ok', v_added > 0, 'error','LIMIT_REACHED', 'added', v_added, 'skipped', v_skipped);
    end if;
    insert into esign.saved_signers (owner_id, name, phone, memo)
    values (v_uid, v_name, v_phone, left(v_memo, 100))
    on conflict do nothing;
    if found then v_added := v_added + 1; else v_skipped := v_skipped + 1; end if;
  end loop;
  return jsonb_build_object('ok', true, 'added', v_added, 'skipped', v_skipped);
end $$;

revoke all on function public.esign_saved_signers_list() from public, anon;
revoke all on function public.esign_saved_signers_add(jsonb) from public, anon;
grant execute on function public.esign_saved_signers_list() to authenticated, service_role;
grant execute on function public.esign_saved_signers_add(jsonb) to authenticated, service_role;
