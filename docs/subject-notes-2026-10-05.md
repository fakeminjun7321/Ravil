# 과목 노트 입력과 문서 출력

## 이번 범위

기존 소개 사이트에 이어진 로그인 작업 공간을 확장한다. Quilo와 Mac 앱 UI는 이번 변경 대상이 아니다.
손글씨는 이미 작성한 사진·PDF를 가져오는 방식으로 결정됐다. 문서 편집기에서 입력한 노트와
손글씨 원본을 과목·프로젝트에 연결하고 PDF/DOCX로 출력한다.

## 구현

- Tiptap 문서 편집기: 제목, 글자 서식, 목록, 체크박스, 표, 행·열, 실행 취소와 수식.
- 기존 일반 텍스트 원문 보존, Markdown 직렬화, frontmatter 보존, 특수 Obsidian 문법의 원문 편집.
- PNG/JPEG/WebP 사진과 PDF 원본을 기존 소유자 전용 파일 API에 저장. PDF는 미리보기와 원본을 연결.
- PDF 출력은 첨부 PDF 전체 페이지를 원본 상태로 결합. DOCX는 글·표·기본 수식을 편집 가능한 형식으로
  생성하고 사진/PDF 전체 페이지를 이미지로 포함. 복잡한 수식은 이미지로 보존.
- Nanum Gothic 글꼴 포함, Letter/A4 선택, 선택적 Markdown/첨부 ZIP 출력.
- 노트·계획·활동 구분. 자동 계획 추출은 계획 종류에만 적용하며 기존 계획의 날짜·반복 횟수를 유지.
- 한글 조합 중 저장/재렌더 억제, 일반 저장 시 문서 선택 영역 보존.

## 검증

**Implemented**: 위 코드와 UI가 존재한다.

**Unit-verified**: 노트 형식/명령/동기화 검사 6개, 클라우드/계획/로그인/출력 전달 검사 14개 통과.
Astro 41개 파일과 Pages/Worker TypeScript 검사 통과. npm production audit 취약점 0개.
같은 출력 코드로 실제 PDF/DOCX/ZIP을 생성해 본문, 표, Word 수식 OMML, 미디어,
첨부 PDF 원본이 포함되는 것을 검사했다. 수식의 이미지 출력 경로도 실제 DOCX로 검사했다.

**로컬 브라우저 경로 검증**: 별도의 합성 계정으로 가입·로그인 → 한글 노트 입력 → 서식 제목·표 입력
→ 사진/PDF 업로드 → 저장 → 재접속 → 과목/프로젝트 조회 → PDF/DOCX 내려받기를 수행했다.
실제 파일 업로드와 sync 응답을 확인했고 로컬 D1에서 Markdown 본문, 과목·프로젝트 연결,
첨부 3개가 저장된 것을 조회했다. 내려받은 PDF/DOCX 각 4페이지를 모두 렌더해 한글·수식·사진과
첨부 PDF 2페이지가 표시되는 것을 확인했다. 실제 Word 글과 수식은 XML에서도 편집 가능한 형태로 확인했다.

검수 파일: `output/note-export-2026-10-05/`. `browser-note.pdf`, `browser-note.docx`는 실제 UI에서
내려받은 파일이며, `note.pdf`, `note.docx`는 형식 변환 테스트 산출물이다. 합성 자료이며 사용자 노트가 아니다.
`editor-desktop.png`, `editor-mobile.png`는 실제 편집 화면이다.

**Simulator-verified**: 미검증. 브라우저에서 반응형 화면을 확인한 것은 iOS Simulator 검증이 아니다.

**Physical-device-verified**: 미검증. 실제 iPhone/iPad의 파일 선택·PWA 설치·다운로드,
Apple Pencil, 네이티브 Word/Google Docs 편집, 실제 한글 IME 입력은 검증하지 않았다.
이미지 OCR, Google Docs 계정 연결, DOCX 가져오기는 구현 범위에 포함하지 않는다.

## 배포

고정 검수 주소: https://workspace-preview.ravil-website.pages.dev/workspace/
현재 작업의 검수 배포 결과와 라이브 검증은 아래에 추가한다. 운영 Pages `main`과 DNS/구매 변경은 진행하지 않는다.

## 명령과 아이콘 중심 입력

기능 이름을 나열한 버튼 줄과 설명 문구를 줄이고, 작은 아이콘 도구·선택한 글 옆 서식 도구·
`/` 명령 메뉴로 바꿨다. `+`는 같은 메뉴를 검색창으로 열어 터치에서도 사용한다.
`/h1`, `/h2`, `/표`, `/수식`, `/PDF`, `/과목`에 한국어/영어 검색, 방향키, Enter, Esc를 지원한다.
날짜와 URL 안의 슬래시는 명령으로 취급하지 않는다. 출력·연결·새 기록은 상단 아이콘에,
원문·가져오기·계획 정리·AI·수동 저장은 문서 메뉴에 보관한다. 아이콘의 이름은 접근성 레이블과
툴팁으로 유지한다. 표 행/열 도구는 표 안에서만 나타난다.

참고와 실제 확인을 구분했다:

- [Notion 공식 도움말](https://www.notion.com/help/writing-and-editing-basics): `/`·`+` 블록 메뉴,
  선택한 글의 서식 도구. 모바일은 `+` 도구를 사용하는 안내를 확인했다.
- [Craft 공식 도움말](https://support.craft.do/en/write-and-edit/styling): 선택한 글의 도구,
  Aa, 점 세 개 메뉴, `/style`을 확인했다.
- [BlockNote 공식 데모](https://www.blocknotejs.org/docs/react/components/suggestion-menus):
  실제 임시 데모 편집기에 `/`를 입력해 메뉴를 열고 `table` 입력으로 표 항목만 남는 것을 확인했다.
  Notion/Craft 계정의 개인 문서를 직접 조작하지 않았다.

RAVIL 로컬 브라우저에서 `/h2` → 제목 입력, `/표` → 실제 표 생성과 명령어 제거,
선택한 글의 도구 표시, 표 문맥 도구를 확인했다. 기존 노트의 글/표/과목/프로젝트를 유지한 채
같은 내용으로 화면을 비교했다. 수정 화면은 `editor-command-desktop.png`에 저장했다.

## 라이브에서 발견한 저장 문제와 수정

빠른 입력과 업로드가 저장 응답을 기다리는 동안 겹치면 에디터가 자신의 저장 응답 판본을 이어받지 못해
잘못된 동시 수정 충돌이 생겼다. 저장 호출을 직렬화하고, 소유자 기록의 저장 응답 판본을 편집기에 전달하며,
진행 중인 동기화를 기다린 뒤 추가 변경까지 최대 3회 처리하도록 수정했다. 저장 전 본문은 포커스가
버튼으로 옮겨져도 갱신으로 덮어쓰지 않는다. 지연 응답 중 수식·첨부를 더한 경우와 실제 원격 충돌을
분리한 IndexedDB 검사 2개가 통과했다. 실제 다른 기기의 수정은 여전히 두 판본을 보관한다.

## 최종 검수 사이트 경로

- Pages 배포: `3340c1cd.ravil-website.pages.dev`, 고정 주소의 `workspace-preview` 브랜치.
- Worker: `e2e7ae5e-764c-42fe-b137-1c3477e7df26`.
- D1 `0003_note_exports.sql`은 CLI가 7403 권한 오류를 반환해 연결된 Cloudflare API 도구로
  같은 계정·같은 검수 DB에 적용했다. SQL 결과의 성공과 테이블/인덱스 생성을 확인했다.
- 검수 계정으로 로그인 → `/h2`, `/수식` → `+` 검색 → 사진/PDF 선택 → 원본 업로드/저장 →
  재접속 → 과목 연결 → PDF/DOCX 생성 → 계정 보호 HTTPS 파일 링크 다운로드를 실행했다.
- 실제 `/api/workspace` 응답에서 수식과 PDF 원본 주소, 첨부 3개, 과목 연결을 확인했다.
  별도 노트의 표와 과목 연결도 서버 응답에 있었다. 미리보기 PNG를 제외한 원본 파일 링크는 두 개다.
- 실제 내려받은 `preview-note.pdf`와 `preview-note.docx` 각 4페이지를 모두 렌더해 확인했다.
  사진, 원본 PDF 두 페이지, 한글 본문과 수식이 표시됐다. DOCX는 편집 가능한 본문과 이미지 5개,
  포함 글꼴 3개를 XML/ZIP에서도 확인했다. 기본 수식·표는 별도 변환 검사의 편집 가능한 요소로 확인했다.
- 브라우저의 SVG ImageBitmap 변환 실패는 HTML 이미지 디코더를 사용하는 출력으로 수정했다.
  메모리 URL 다운로드가 검수 브라우저에서 시작되지 않아 HTTPS 전달로 수정했으며 실제 완료 경로가
  `/Users/minjun/Downloads/명령 입력 검수.pdf`, `.docx`로 반환됐다.
- 출력 전달은 소유자 전용이며 링크는 1시간 만료, 생성 파일만 다음 정리 작업에서 제거한다.
  원본 파일/노트와 구분한 저장 경로이며 소유자·만료·원본 보호 정리 검사가 통과했다.
- `editor-final-desktop.png`는 실제 데스크톱 편집 화면, `editor-final-mobile.png`와
  `editor-final-mobile-menu.png`는 작은 브라우저 화면과 명령 검색 화면이다. 작은 화면의 실제 CSS 너비는
  353px였으며 클라이언트 배율을 반영한 캡처는 392px다. iOS Simulator/실기기 검증으로 분류하지 않는다.

관찰된 검수 API 요청 수는 `output/note-export-2026-10-05/live-verification.json`에 기록한다.
작성 중 자동 동기화 요청을 포함한다. 운영 소개 사이트의 직접 브라우저/HTTP 요청은 0회다.
운영 Pages main 반영과 DNS/구매는 별도 승인 범위다.

최종 관찰: 검수 API 요청 169회(자동 동기화 포함), API 오류 0회, 운영 사이트 요청 0회. 검수 계정 로그아웃과 로그인 화면 이동을 확인하고 작업 탭을 정리했다.
