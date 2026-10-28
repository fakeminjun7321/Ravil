# Ravil → Quilo 통합 결정

기준일: 2026-10-28. 사용자가 확정한 방향:

> Ravil을 Quilo로 통합한다. 별도 제품이 아니라 같은 프로그램 안에서 동작하게 한다.

- 기준본은 Quilo다. 통합 계획의 원본은 Quilo 저장소 `docs/ravil-integration-plan.md`이며, 이 문서는 Ravil 쪽 포인터다.
- Ravil의 기록 워크스페이스(`apps/cloud`, `apps/website/src/workspace`, `Stores/PersonalWorkspace.swift`)는 Quilo 웹의 "내 기록" 기능으로 이식한다.
- Ravil Mac 앱은 Quilo Mac 앱으로 전환한다. 녹음·전사·Alt 가져오기·Goodnotes/Drive PDF·OCR·시험 범위·로컬 모델 연결은 Mac 로컬에 그대로 둔다.
- Ravil 계정·Worker·D1·R2·ravil.app은 데이터 이관 후 폐기한다. Node 단계 CLI와 `apps/api`는 폐기한다. ASR 연구 자료는 `docs/model-research-history.md` 규칙대로 Git 밖에 보존한다.
- 통합이 끝나기 전까지 이 저장소의 기존 데이터·PDF 판본·전사 이력·검증 문서는 삭제하지 않는다. `docs/product-goal.md`의 기록 보존·AI 해석 분리 원칙은 Quilo "내 기록"의 원칙으로 승계한다.

이 문서는 결정 기록이다. 어떤 단계도 완료된 것으로 표시하지 않는다.
