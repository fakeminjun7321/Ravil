# RAVIL 개인 워크스페이스

**현재 목표(2026-10-19):** 내가 남긴 기록을 AI가 분석·정리하고 필요한 순간에 생각과 행동을 돕는 [개인용 세컨드 브레인 워크스페이스](product-goal.md).
아래는 2026-10-04부터의 구현·검증 기록이다. 과목·시험 중심의 당시 예시는 활용 사례이며 현재 기록·프로젝트 사용의 필수 조건이 아니다. 현재 우선순위는 [공식 로드맵](canonical-roadmap.md)을 따른다.

기준일: 2026-10-04. 기록 중심 입력, 과목·프로젝트 연결, 기기별 화면,
Cloudflare 공통 저장, RAVIL 내부 활동을 통한 개인화를 구현한다.

## 데이터와 사용자 흐름

- 원본 기록은 하나이며 subjectIDs, projectIDs로 여러 맥락에 연결한다.
- 원문을 그대로 저장하고 날짜·단원·반복 횟수를 별도 할 일로 정리한다.
- Mac은 SwiftUI와 보호된 로컬 JSON 저장소, 웹·PWA는 IndexedDB를 사용한다.
- 계정별 캐시를 분리하고 로그인 전 기록은 직접 연결한다. Mac 세션은 Keychain,
  웹 세션은 Better Auth 쿠키로 관리한다.
- D1 엔티티는 사용자 ID로 제한한다. 수정은 revision을 비교하고 충돌 시
  다른 기기 수정 또는 내 수정의 별도 보존을 선택한다.
- R2 파일은 사용자별 SHA-256 키로 보관하며 기존 파일 ID를 덮어쓰지 않는다.
- 시험 백업은 원문, 연결, 할 일, 활동, 첨부파일을 포함한다. 내려받은 파일을
  다시 검사한 후 공간을 정리한다. 백업 이후 변경은 정리를 막으며 과목별 기록은 남는다.
- 공부 시작·마침, 읽기, 완료, 계획 변경과 정정을 기록한다. 같은 활동의
  시간 기록이 세 번 이상이면 중앙값을 새 할 일 예상 시간에 반영한다.
- AI 도움은 선택한 기록과 RAVIL 활동 요약을 Workers AI에 보낸다.
  모델을 다시 훈련하거나 Mac 전체 화면·다른 앱을 관찰하지 않는다.
- Google Calendar는 Mac의 Desktop OAuth로 권한을 연결한다. 서버는
  실제 Calendar 접근을 확인한 뒤 연결 정보를 AES-GCM으로 저장한다.
  시간 충돌을 피하고 지정 날짜를 보존한다. 자동 배치는 시간 기준 설정으로 켠다.
- 백업 알림은 사용자가 권한을 켠 기기에만 제공한다. PWA 알림은
  Web Push와 매일 21:00 Asia/Seoul 서버 작업을 사용한다.

## 구성과 검증 환경

- apps/cloud: Worker, Better Auth, D1 스키마, R2, Calendar, 알림.
- apps/website/src/workspace: 입력, 계획, 개인화, 백업, IndexedDB 동기화.
- apps/macos/Ravil/Models/WorkspaceModels.swift: 공통 JSON과 계획 파서.
- apps/macos/Ravil/Stores/PersonalWorkspace.swift: Mac 저장·계정·동기화.
- apps/macos/Ravil/Views/WorkspaceView.swift: 기기 내 작업 화면.

기존 소개 사이트에서 이어지는 웹: https://ravil-website.pages.dev/workspace/
이 주소의 운영 반영은 사용자 승인 후 진행한다.

동일 Pages 프로젝트의 연결 미리보기: https://workspace-preview.ravil-website.pages.dev/
소개 `/`와 작업 공간 `/workspace/`, API `/api/*`가 한 주소에서 동작한다.
Pages Function의 서비스 바인딩으로 기존 Worker에 요청을 전달하고 로그인 쿠키는
Pages 주소에 보관한다. 허용된 사이트 주소는 서버 설정에 명시한다.

Mac 공통 API: https://ravil-workspace-preview.fakeminjun7321-f03.workers.dev

D1과 R2 이름: ravil-workspace-preview. 기존 다른 서비스와 구분한 저장소다.
정식 도메인 후보는 ravil.app이며 결제는 사용자 승인 후 별도 수행한다.

## 검사

프로젝트 기존 검사:

    npm test

클라우드:

    cd apps/cloud
    npm test
    npm run check
    node --experimental-strip-types test/api-flow.ts

웹:

    cd apps/website
    npm run check
    npm run build

Mac:

    swift build --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
    .build/debug/Ravil --workspace-check /absolute/path/to/synthetic-plan.txt
    .build/debug/Ravil --workspace-cloud-check /absolute/path/to/private-qa-fixture.json

검사용 계정은 합성 입력만 사용한다. 비밀번호·토큰·알림 서명 키는 로그나 Git에
넣지 않는다. .dev.vars, .env.preview, .env.push와 .wrangler는 제외한다.

## 현재 제한과 검증 경계

- 파일당 20MB, 시험 백업 첨부파일 합계 32MB, 계정당 엔티티 5,000개,
  동기화 묶음 100개, Calendar 배치 50개 제한을 둔다.
- 기존 PDF·녹음 전체를 자동 업로드하지 않는다. 선택한 파일을 기록에 연결한다.
- 검색은 본문·제목·주제·연결을 사용한다. 임베딩 의미 검색은 아직 없다.
- 이메일·비밀번호 가입이며 이메일 소유 확인·비밀번호 재설정 메일은 아직 없다.
- Google 실제 계정 권한·일정 반영, 실제 iPhone·iPad PWA 설치·알림,
  새 Mac GUI 경로는 별도 검증이 필요하다.
- 개발용 ad-hoc 서명 앱이며 공증·일반 사용자 배포 검증은 하지 않았다.

## 소개 사이트 연결 검증 (2026-10-05)

- Implemented: 기존 `ravil-website` 소스의 `/workspace/`와 `/api/*` 서비스 바인딩,
  모바일 진입 메뉴, 소개로 돌아가는 링크, 주소별 인증 쿠키를 반영했다.
- Unit-verified: 클라우드 테스트 8개 통과. 등록하지 않은 주소와 전달된 호스트 헤더를
  인증 주소로 사용하지 않는다. 웹·Pages Function 타입 검사와 양쪽 빌드가 통과했다.
- 미리보기 배포: `fd8d30a1-af8f-4253-b738-8126c8abc3fc`, 고정 주소
  `https://workspace-preview.ravil-website.pages.dev`.
- 실제 서비스 API 검증: `test/site-flow.ts`의 순차 요청 12회로 Pages 회원가입,
  호스트 한정 HttpOnly 쿠키, 로그인 유지, D1 저장·재조회, 다른 출처 요청 거부,
  Mac 공통 API의 동일 기록 조회, 로그아웃 세션 폐기를 확인했다. 합성 입력만 사용했다.
- 백그라운드 브라우저: 소개의 ‘내 작업 시작’으로 같은 사이트의 `/workspace/`에
  들어가 실제 입력 화면이 표시됨을 확인했다. 페이지 이동 2회. 1440×1000과
  393×852에서 화면을 렌더링해 가로 넘침과 주요 링크·버튼을 점검했다.
- Not verified: 실제 iPhone·iPad PWA 설치와 푸시, Mac GUI의 사용자 경로,
  Google Calendar 목적지의 일정 반영은 이 검증에 포함하지 않았다.
- 운영 배포는 승인 전이다. 기존 운영 배포 ID
  `34450414-abb8-46d6-b511-6c13fbd8d7b3`를 API로 다시 확인했으며 이번 검증에서
  운영 주소로 직접 요청한 횟수는 0회다. 도메인 구매와 DNS 변경도 수행하지 않았다.

## 소개 사이트 로그인 (2026-10-05)

- Implemented: 소개 사이트에 로그인 진입점, `/login/`, `/signup/` 화면을 추가했다.
  로그인 후 같은 주소의 `/workspace/`로 이동한다. 세션이 있으면 공개 메뉴는
  ‘내 작업’으로 바뀐다. Pages와 Worker 웹 경로 모두 서버에서 세션을 확인한다.
- 로그인 전에 계정별 IndexedDB 기록을 불러오지 않는다. 로그아웃·세션 만료에는
  기록 화면과 열린 대화상자를 비우며 저장된 파일을 삭제하지 않는다.
- 작업 HTML은 `private, no-store`. 서비스 워커는 보호된 HTML과 로그인 응답을
  오프라인 캐시로 대체하지 않는다. 처음 작업 화면을 열 때는 로그인 확인에 연결이 필요하다.
- Unit-verified: 테스트 11개, 웹·함수·Worker 타입 검사와 빌드가 통과했다.
- 실제 미리보기 API 검사 16회: 미로그인·로그아웃의 작업 공간 접근 거부,
  쿠키 세션, 기록 저장·재조회, 다른 출처 요청 거부, Mac 공통 API 공유를 확인했다.
- 브라우저 경로: 소개 → 로그인 → 가입 → 작업 공간 → 메모 저장 → 재열기,
  로그아웃 후 직접 접근 거부, 잘못된 비밀번호 안내를 확인했다. 실제
  `/api/workspace` 응답에서 검증용 메모의 본문을 읽어 저장을 확인했다.
- 재로그인 검사에서 세션 조회 API 429가 관측되어 해당 검증을 중단했다.
  로그인 화면의 중복 조회를 제거하고 세션 읽기만 120회/60초로 별도 제한했다.
  비밀번호 시도 제한은 유지한다. Cloudflare가 제공한 클라이언트 IP를 사용하고
  내부 작업 공간 검사에서도 전달해 서버 검사 요청이 하나의 공통 키로 모이지 않게 했다.
- 수정 후 로컬 실제 인증 경로 34회 검사: 세션 읽기 25회, 로그아웃, 잘못된 비밀번호,
  정상 재로그인과 작업 화면 접근을 확인했다. 그 뒤 수정된 배포에서 기존 계정 로그인,
  저장 기록의 실제 서버 응답, 로그아웃을 브라우저로 다시 확인했으며 429는 없었다.
  브라우저 문서/API 요청 관측 수는 초기 27회, 수정 후 10회다. 정적 자산은 제외한다.
- 최종 Pages 미리보기: `b364b704.ravil-website.pages.dev`, 고정 별칭은
  `workspace-preview.ravil-website.pages.dev`. Worker 버전은
  `fa859bb8-6531-4544-b516-fd034ea2d7b1`.
- 시각 검수: 로그인 화면 1440×1000 및 393×852, 가로 넘침 없음.
  실제 iPhone·iPad PWA 설치와 기기 내 로그인은 Not verified이며 운영 배포는 승인 대기다.
  이 범위에서 운영 주소 직접 요청은 0회다. 테스트 계정은 합성 입력만 사용했고
  검증용 세션·쿠키와 숨김 탭을 정리했다.

## 입체적 웹 디자인 (2026-10-05)

사용자 지정 범위: 웹 소개·로그인·작업 화면부터.
금속·연두 유리의 R 작품, 앞으로 나온 로그인 폼, 어두운 도구 면과 겹친 기록지를 반영했다.
미술 자산은 built-in image_gen, UI는 실제 Astro/HTML/CSS/TypeScript다.
실제 문구·입력·계정·과목·프로젝트·저장 동작을 유지했다.

시안·프롬프트 세트·자산과 검수 근거는
`apps/website/design/art-2026-10-05/DIRECTION.md`, `QA.md`에 기록했다.
타입 검사·빌드 통과. 로컬 사용자 경로의 가입, 공부 계획 저장·정리,
반복 완료와 탐색 확인. 시안 크기 1374×1145 및 1505×1045, 모바일 393×852와
320×852에서 실제 렌더를 비교했다. 배포된 미리보기에서도 로그인·기존 기록 재조회·로그아웃을 확인했다.

최종 Pages 미리보기 `797fab70.ravil-website.pages.dev`, 고정 별칭
`https://workspace-preview.ravil-website.pages.dev/`. Worker 버전
`80f45776-9861-46ad-9a3c-e5a892044e8e`.
이번 디자인 검증의 미리보기 문서/API 관측 14회, 운영 주소 직접 요청 0회.
실제 iPhone·iPad PWA는 미검증. Mac 디자인은 이번 요청 범위에서 제외되며,
기존 운영 주소 반영은 사용자 승인 대기다.
