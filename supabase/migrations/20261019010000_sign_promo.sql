-- ============================================================
-- 서명 화면 인투오피스 안내(광고) 노출 여부
--
-- 서명자 화면 하단 띠 · 서명 완료 카드에 「인투오피스 써 보기」 안내를 보여 줄지 정한다.
-- 유료 고객(결제한 개인 · 조직) 문서에는 보이지 않는다. 무료 체험 · 조직 없는 문서에만 보인다.
-- 이 함수가 없거나 오류면 화면은 안내를 보여 주지 않는다 (유료 고객 문서에 잘못 나가지 않도록).
-- ============================================================
create or replace function public.esign_sign_promo(p_token text)
returns jsonb language sql stable security definer
set search_path to 'esign', 'public', 'pg_temp'
as $$
  select jsonb_build_object('ok', true, 'show', coalesce((
    select o.id is null or o.status = 'trial' or o.plan_code = 'free_trial'
      from esign.signers s
      join esign.documents d on d.id = s.document_id
      left join esign.organizations o on o.id = d.org_id
     where s.sign_token = p_token
     limit 1), false));
$$;

revoke all on function public.esign_sign_promo(text) from public;
grant execute on function public.esign_sign_promo(text) to anon, authenticated, service_role;
