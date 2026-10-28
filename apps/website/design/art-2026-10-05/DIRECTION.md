# RAVIL: 조각과 기록지

2026-10-05. 사용자 요청: 입체적이고 예술적인 디자인.
확정 범위: 웹 소개, 로그인, 작업 화면. Mac 앱은 이번 변경에서 제외한다.

## 시안과 구현 재료

- hero-concept.png: 금속·연두 유리의 큰 R, 왼쪽의 실제 소개 문구, 아래 자료 데모.
- login-concept.png: 어두운 작품 영역과 앞쪽의 밝은 로그인 기록지.
- workspace-concept.png: 어두운 도구 영역, 겹친 흰 기록지, 조용한 맥락 패널.
- flow-concept.png: 열린 사용 흐름, 어두운 판본 비교 진열 면과 밝은 원문.
- gallery-scene-source.png, r-sculpture-source.png: built-in image_gen으로 생성한 실제 미술 자산.
  각각 public/art/gallery-scene-v1.webp 및 r-sculpture-v1.webp로 전달 형식만 변환했다.
  크기와 투명도를 유지했다. 두 자산 합계 약 497KB.

R은 장식용 조각이다. 로고, 제목, 입력, 버튼, 자료·기록·검색 등 UI는 실제 HTML이다.
시안 이미지를 작업 화면으로 사용하지 않는다.

## 디자인 시스템

공간 배경 #efefe9, 기록지 #ffffff, 글자·도구 면 #202822, 연두 #d9f18b.
보조 글자는 가독성을 위해 #5c675f: 배경과 불투명 대비 5.11:1.
원문 Pretendard 16px/1.95, 기록 제목 32px, UI 12–14px.
원문의 입력 상태와 기존 과목·프로젝트·계정 구조를 보존한다.

그림자는 도구, 기록지, 버튼의 높이 차이를 설명한다. 본문 위에 장식이나 투명 그림을 올리지 않는다.
소개는 좌우 구도, 로그인은 두 재료 면, 작업은 3열 구조다. 모바일에서는 한 열로 재배치한다.
동작은 버튼 눌림과 작은 호버 변화에 제한하고 prefers-reduced-motion을 반영한다.

## 생성 프롬프트 세트

도구: built-in image_gen. 시안 4개와 자산 추출·재생성 2개.
공통 요청: Korean record-first personal workspace; architectural sculpture gallery;
brushed graphite ribbon and thick translucent pale lime glass forming a capital R;
directional light and physically believable shadows; alabaster ground and white writing paper;
native HTML controls; no chat dashboard, invented metrics or extra product promises.

- 첫 화면: 실제 메뉴와 ‘편하게 남긴 기록이, 다음 작업으로 이어지도록.’, 기존 소개문,
  ‘내 작업 시작’, ‘자료 기능 데모’, 개발 상태, 자료·강의·복습의 실제 데모를 포함.
- 로그인: 기존 이메일·비밀번호·가입 링크와 문구를 유지. 작품과 폼을 두 면으로 구성.
- 작업: 기존 기록·과목·프로젝트·입력·계정 구조, 10.14 광학 입력과 반복 횟수 보존.
- 하단: 기존 사용 흐름 3열과 PDF 판본 비교. 자료 내용과 실제 개발 상태를 유지.
- 공간 자산 편집: 첫 화면 시안에서 모든 글자와 UI를 제거하고 왼쪽 여백과 오른쪽 R을 재생성.
- 투명 조각 편집: 같은 R만 정사각형의 투명 배경으로 재생성하고 형태·재질·그림자를 보존.

## 의도적으로 구현하지 않은 시안 요소

생성 이미지의 임의 영문 벽 문구, 책 제목, 구체적인 새 자료 내용, 불필요한 장식은 추가하지 않는다.
기존 공개 예제와 기능 문구가 시안의 임의 데이터보다 우선한다. 실물 3D 모델 뷰어가 아닌
고품질 렌더 자산과 CSS의 표면·레이어로 공간감을 만든다.

로그인·서버 접근 제한·동기화·백업의 동작은 기존 구현을 사용한다.
실제 렌더 비교와 기능 검증은 QA.md에 별도로 기록한다.
