# RAVIL 도메인 배포와 검증

상태: 2026-10-06 사용자의 “배포해” 승인에 따라 운영 배포와 DNS 연결을 적용했다.
`ravil.app`과 `www.ravil.app`의 Pages 도메인 상태·인증서 검증은 모두 active이다.
실제 Mac Chrome에서 소개 → 로그인 → 노트 저장 → 재접속 → 로그아웃 경로를 확인했다.

## 운영 대상

- Cloudflare 계정: `cf03cf471c6eb89a4ababd4f1f023469` — `Fakeminjun7321@gmail.com's Account`
- Zone: `ravil.app`, `c690125a9ae0dfa12e5dfa07bae499b4`
- Pages: `ravil-website`, production branch `main`
- Pages deployment: `9ae98e97-3ded-4be6-86b9-d5417afea470`
- Worker: `ravil-workspace-preview`, version `2c2cd987-6f7b-4447-a525-a359a77e8e0f`
- Production service binding: `WORKSPACE_API → ravil-workspace-preview` 확인
- D1/R2: 기존 작업 공간의 계정별 저장소 사용
- Registrar 등록은 사용자가 직접 결제했으며 만료는 `2027-10-06T03:00:21Z`, auto_renew=false이다.
  당시 최종 checkout은 1년 Due today USD 8.20을 표시했다. 영수증 상세 내역은 조회하지 않았다.

## 적용한 연결

| 이름 | DNS | 대상 | 상태 |
| --- | --- | --- | --- |
| ravil.app | CNAME, proxied | ravil-website.pages.dev | Pages active, 실제 HTTPS 200 |
| www.ravil.app | CNAME, proxied | ravil-website.pages.dev | Pages active, 실제 HTTPS 308 |

`www`는 경로와 쿼리를 유지해 `https://ravil.app`으로 이동한다.
인증서 검증을 위해 `/.well-known/`은 이동 규칙에서 제외했다.
실제 검증용 ACME 주소는 Location 없이 404를 반환해 검증 경로의 이동이 차단되지 않음을 확인했다.

- Redirect ruleset: `654e03741ff94d059be7a909f5255421`
- Rule: `f8844e72a08f4d79aa28fad01a15c196`, `ravil_www_to_apex`
- 인증 허용 주소에 apex/www 추가, canonical/social/robots/sitemap을 `https://ravil.app`으로 배포
- Pages Functions middleware는 API/작업 경로에서 www→apex 이동을 보조한다.
- 설치된 Wrangler가 지원하는 `--commit-dirty=true`로 배포 스크립트의 `--force`를 교체했다.
- 추가 구매 요청이나 유료 요금제 변경은 수행하지 않았다.

## 검증 범위

- **Implemented**: Worker·Pages 운영 배포, 두 custom domain, DNS, canonical redirect가 실제 Cloudflare에 존재한다.
- **Unit-verified**: Cloud의 집중 테스트 14개 통과. 앞서 웹/Cloud 타입 검사를 통과했고, 이번 운영 웹 빌드도 통과했다.
- **Physical-device-verified (Mac Chrome 웹)**: 실제 ravil.app에서 로그인하고 노트를 저장한 뒤 새로 접속해 같은 제목·본문을 열었다.
  별도 QA 계정의 D1 기록 `45f5df6c-5f3f-4f8c-8810-2dede7389844`가 revision=2로 보존된 것을 직접 조회했다.
  로그아웃 후 작업 주소를 다시 열면 로그인 URL로 이동한다.
- **Not verified / 미검증**: 이번 작업에서 iPhone/iPad PWA의 실제 기기·시뮬레이터 경로와 네이티브 Mac 앱 경로는 실행하지 않았다.
  PDF/Word·파일 입력 전체 경로는 이번 도메인 배포 검증에서 다시 실행하지 않았다.

의도적인 직접 HTTP 요청 5회, 브라우저의 상위 화면 이동 6회를 수행했다.
정적 자산과 앱 자체 세션·동기화 요청의 개별 횟수는 측정하지 않았다.
CDP Network 이벤트가 제공되지 않아 전체 요청 수를 계측한 것으로 보고하지 않는다.
Cloudflare 제어판 API와 D1의 읽기 전용 조회는 위 웹 요청 횟수와 별도이다.

테스트 계정은 로그아웃했고 작업 전용 탭만 닫았다. 사용자 개인 탭·전경 앱·클립보드는 조작하지 않았다.
생성한 QA 임시 비밀번호 파일은 브라우저 입력 직후 삭제했으며 결과 파일에 비밀번호나 토큰을 저장하지 않았다.
QA 기록은 별도 테스트 계정에 있다.

## 근거 파일

- `output/domain-launch-2026-10-06/launch-verification.json`
- `output/domain-launch-2026-10-06/browser-verification.json`
- `output/domain-launch-2026-10-06/live-homepage.png`
- `output/domain-launch-2026-10-06/live-workspace-persisted.png`
- `output/domain-launch-2026-10-06/apex-response-headers.txt`
- `output/domain-launch-2026-10-06/www-final-headers.txt`
- `output/domain-launch-2026-10-06/www-validation-headers.txt`

참고: [Pages custom domains](https://developers.cloudflare.com/pages/configuration/custom-domains/),
[Single Redirects API](https://developers.cloudflare.com/rules/url-forwarding/single-redirects/create-api/),
[Certificate validation troubleshooting](https://developers.cloudflare.com/ssl/edge-certificates/changing-dcv-method/troubleshooting/).
