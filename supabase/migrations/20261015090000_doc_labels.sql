-- 문서 라벨: 계정마다 자기 문서 목록을 정리하는 용도 (문서당 최대 5개, 라벨당 20자)
-- 라벨은 붙인 사람에게만 보인다. 문서가 삭제되면 라벨도 함께 지워진다.
create table if not exists esign.doc_labels (
  owner_id     uuid not null references auth.users(id) on delete cascade,
  document_id  uuid not null references esign.documents(id) on delete cascade,
  label        text not null check (length(trim(label)) between 1 and 20),
  created_at   timestamptz not null default now(),
  primary key (owner_id, document_id, label)
);
comment on table esign.doc_labels is '계정별 문서 라벨. 본인만 조회·변경 (public RPC 경유)';
create index if not exists idx_doc_labels_owner on esign.doc_labels (owner_id, label);

-- 테이블 직접 접근은 막고 함수로만 다룬다 (RLS 켜고 정책 없음)
alter table esign.doc_labels enable row level security;

-- 내 라벨 전부: [{document_id, labels:[...]}]
create or replace function public.esign_doc_labels_get()
returns jsonb language plpgsql stable security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
begin
  if auth.uid() is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED'); end if;
  return jsonb_build_object('ok', true, 'items', coalesce((
    select jsonb_agg(jsonb_build_object('document_id', x.document_id, 'labels', x.labels))
      from (select document_id, array_agg(label order by created_at, label) as labels
              from esign.doc_labels where owner_id = auth.uid()
             group by document_id) x), '[]'::jsonb));
end $$;

-- 여러 문서의 라벨을 한 번에 「통째로 바꾼다」 (빈 배열이면 라벨 제거)
create or replace function public.esign_doc_labels_set(p_document_ids uuid[], p_labels text[])
returns jsonb language plpgsql security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
declare v_uid uuid := auth.uid(); v_labels text[];
begin
  if v_uid is null then return jsonb_build_object('ok',false,'error','AUTH_REQUIRED'); end if;
  if p_document_ids is null or cardinality(p_document_ids) = 0 then
    return jsonb_build_object('ok',false,'error','DOCUMENTS_REQUIRED');
  end if;
  if cardinality(p_document_ids) > 500 then
    return jsonb_build_object('ok',false,'error','TOO_MANY_DOCUMENTS');
  end if;

  -- 공백 정리 · 20자 제한 · 중복 제거 · 최대 5개
  select coalesce(array_agg(l order by first_pos), '{}') into v_labels
    from (select l, min(pos) as first_pos
            from (select left(regexp_replace(trim(t), '\s+', ' ', 'g'), 20) as l, pos
                    from unnest(coalesce(p_labels, '{}')) with ordinality as u(t, pos)) a
           where l <> ''
           group by l
           order by min(pos)
           limit 5) b;

  delete from esign.doc_labels
   where owner_id = v_uid and document_id = any(p_document_ids);

  insert into esign.doc_labels (owner_id, document_id, label)
  select v_uid, d.id, l
    from esign.documents d
    cross join unnest(v_labels) as u(l)
   where d.id = any(p_document_ids)
  on conflict do nothing;

  return jsonb_build_object('ok', true, 'labels', to_jsonb(v_labels));
end $$;

revoke all on function public.esign_doc_labels_get() from public, anon;
revoke all on function public.esign_doc_labels_set(uuid[], text[]) from public, anon;
grant execute on function public.esign_doc_labels_get() to authenticated, service_role;
grant execute on function public.esign_doc_labels_set(uuid[], text[]) to authenticated, service_role;
