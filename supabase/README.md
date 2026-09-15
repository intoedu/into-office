# Supabase 백엔드 (인투오피스)

프로젝트 ref: `lplektkqodrncigysfan`

이 폴더는 브라우저(`/index.html`)가 호출하는 서버 쪽 코드를 형상 관리하기 위한 것이다.
실제 실행본은 Supabase 에 배포되어 있고, 여기 파일은 그 사본이다.

```
supabase/
  functions/     엣지 함수 소스
  migrations/    DB 마이그레이션 SQL
```

## 스키마 접근 규칙 ★

업무 데이터는 전부 **`esign` 스키마**에 있고, 이 스키마는
**PostgREST 의 노출(Exposed) 스키마 목록에 들어 있지 않다.** 의도된 설계다.
`esign` 의 테이블에는 anon / authenticated / service_role 어느 쪽에도 권한이 없다.

따라서 **브라우저든 엣지 함수든 `esign` 스키마를 직접 호출하면 안 된다.**

```ts
// ✗ 하면 안 된다 — PostgREST 가 PGRST106 을 돌려준다
//   화면에는 "문서를 불러오지 못했습니다. (Invalid schema: esign)" 로 보인다
await admin.schema("esign").rpc("file_access", { ... });
await admin.schema("esign").from("alimtalk_logs").insert(rows);

// ✓ public 래퍼를 부른다
await admin.rpc("esign_file_access", { ... });
await admin.rpc("esign_alimtalk_log", { p_rows: rows });
```

`public.esign_*` 함수는 전부 `SECURITY DEFINER` 이고 `search_path` 가 고정되어 있다.
새 기능을 붙일 때도 `esign` 스키마를 노출시키지 말고 래퍼를 하나 더 만든다.

### 래퍼의 실행 권한

| 대상 | 실행 권한 |
|---|---|
| 브라우저에서 부르는 것 (`esign_list_documents` 등) | `authenticated` / 필요 시 `anon` |
| **엣지 함수 전용** (`esign_file_access`, `esign_alimtalk_log`, `esign_notify_targets`, `esign_notify_retention_due`, `esign_purge_pending`, `esign_purge_mark_cleared`) | **`service_role` 만** |

엣지 함수 전용 래퍼는 호출자의 uid 나 대상 목록을 인자로 받기 때문에
브라우저 키(anon)로 부를 수 있으면 권한 우회가 된다. 반드시 `service_role` 에만 준다.

## 엣지 함수

| 이름 | verify_jwt | 하는 일 |
|---|---|---|
| `esign-sign` | false | 서명 처리 (비로그인 서명자) |
| `esign-auth` | false | 가입 · 로그인 보조 |
| `esign-admin` | false | 플랫폼 관리자 기능 |
| `esign-file` | **false** | 비공개 버킷 문서의 30분짜리 서명 URL 발급 |
| `esign-notify` | true | 카카오 알림톡 발송 |
| `esign-retention` | true | 보관 정책 마무리 (pg_cron 이 호출) |

`esign-file` 과 `esign-sign` 은 **비로그인 서명자**가 서명 토큰으로 접근해야 하므로
`verify_jwt` 가 꺼져 있다. 함수 내부에서 직접 권한을 검사한다.
**재배포할 때 이 설정이 켜지지 않도록 주의한다.**

## 배포

이 폴더의 파일을 고친 뒤 Supabase CLI 또는 대시보드로 배포한다.
파일만 고치고 배포하지 않으면 운영에는 반영되지 않는다.

```bash
supabase functions deploy esign-file --project-ref lplektkqodrncigysfan --no-verify-jwt
supabase db push --project-ref lplektkqodrncigysfan
```
