# Ravil 모델 개발 이력과 가중치 보존 기준

2026-10-22 사용자 결정: 과거 모델을 모두 가중치·압축본으로 보관하지 않는다. **개발 과정, 고정된 출처, 코드·설정, 평가 결과와 재현 방법**을 남기고, 사용하지 않는 과거 가중치와 중간 변환본은 삭제한다. 별도 **Ravil Ai** 프로젝트는 이 정리 대상이 아니다.

## 남기는 것

- 현재 연구의 품질·경량 경로: Qwen3-ASR 1.7B 6비트, 0.6B 8비트.
- 정렬: Qwen3 ForcedAligner 0.6B 4비트. 영어 전사: Parakeet BF16 변환본. Silero VAD도 유지한다.
- 직접 학습한 최종 결과: Whisper Tiny v1 LoRA 약 0.29MiB, Qwen 0.6B 선택 epoch 2 LoRA 약 4.39MiB. Qwen은 `adapter/`의 단일 사본만 남긴다.
- 기반 모델·데이터 리비전, 코드, 의존성, 실험 설정·학습 로그·평가 JSON·모델 카드와 라이선스 고지.
- 원본 녹음, 학습·평가 데이터, 현재 앱 번들·사용자 데이터, 기존 작업 파일.

최종 어댑터 두 개는 합계 약 4.68MiB다. 이는 기반 모델 전체가 아니라 학습으로 얻은 작은 변경분이다. 학습 기록과 seed만으로 같은 가중치를 비트 단위까지 재현할 수 있다고 보장하지 않으므로 최종 변경분만 보존한다. 선택된 최종 checkpoint라는 뜻이며 모든 평가에서 가장 좋은 모델이라는 뜻은 아니다.

## 개발 흐름

아래 수치는 기존 실험 기록에서 가져왔다. 이번 정리에서 새로 학습하거나 평가하지 않았다.

| 단계 | 바꾼 것 | 남긴 근거와 결과 | 큰 파일 보존 여부 |
|---|---|---|---|
| Whisper Tiny 초기 v0 | 공개 FLEURS 한국어로 소규모 LoRA 시험. 학습 64개·평가 12개 | `experiment.json`, 어댑터 설정, seed 240930. CER 12.86% → 13.24%로 이 표본에서는 악화 | v0 어댑터 삭제, 기록 유지 |
| Whisper Tiny v1 / ASMR 0.1 | rank 4, alpha 8, 학습률 1e-4, 3회, 129개 학습. 기본 가중치 고정 후 attention q/v 학습 | `train_whisper_ko_adapter.py`, `experiment.json`, 모델 카드. 공개 test 100개 CER 16.73% → 16.07% | 최종 작은 LoRA만 유지 |
| Whisper GGML 출력 | 기반 모델+v1 LoRA를 병합하고 고정 whisper.cpp로 GGML f16 변환 | `export_whisper_ko_adapter.py`, `export.json`, 변환 로그와 별도 실행 평가. 일부 출력의 잘못된 UTF-8 문제가 있어 배포 승인되지 않음 | 병합 전체 가중치·GGML·Tiny 기준선 삭제 |
| Qwen 원본 PyTorch 평가 | Qwen3-ASR 1.7B HF 원본을 MPS에서 평가 | `evaluate_qwen3_asr.py`, FLEURS 평가 JSON, 기반 리비전·해시 | 원본 HF 캐시의 대형 압축본 삭제 |
| ASMR 0.2 | Qwen 1.7B 4비트와 강제 정렬 결합. 자체 Qwen 가중치 학습은 아님 | 0.2 모델 카드, `transcribe_mlx_qwen_aligned.py`, 평가 JSON. 한국어 100개 CER 3.71% | 과거 4비트 ASR 가중치 삭제. 정렬기는 유지 |
| ASMR 0.3~0.4 | Qwen 6비트 비교, 긴 녹음 분할·문맥·시각 검사 추가 | 0.3/0.4 모델 카드, longform CLI와 평가 기록. 동일 한국어 기준 6비트 CER 3.30% | 6비트 후보 유지. 단순 파이프라인 버전마다 가중치를 복제하지 않음 |
| ASMR 0.5 | Qwen 0.6B 경량 경로, Parakeet 영어 경로, Redux 비교. Parakeet FP32를 BF16 파일로 변환 | `asr-candidates-20261001.json`, `convert_parakeet_bf16.py`, 동일 입력의 평가 JSON. 영어 BF16 WER 6.27%, Redux 7.59%; 한국어·혼용에 영어 모델을 적용하지 않음 | 경량 Qwen·Parakeet BF16 유지. Redux·FP32 원본 압축본 삭제 |
| Qwen 0.6B LoRA pilot | decoder q/v rank 8, alpha 16, dropout .05, 학습률 2e-5, seed 261001. 공개 96개+동의된 비공개 의사 라벨 4개, 50 updates, 선택 epoch 2 | `train_qwen_asr_adapter.py`, 분리된 데이터 목록, `experiment.json`, 모델 카드. 의사 라벨은 사람이 검수한 정답이 아님. 실제 수업 정확도·앱 통합은 미검증 | 최종 `adapter/`만 유지. epoch 1과 중복 epoch 2 가중치 삭제 |

Whisper rank/alpha 등의 실제 값은 저장된 `adapter_config.json`과 코드 스냅샷을 우선한다. 초기 v0의 정확한 실행 명령은 기록만으로 확정되지 않으므로 재실행해 같은 결과를 보장하지 않는다.

## 기록의 실제 위치

- `research/history/2026-10-22-record-only/source-snapshot/`: 정리 당시 연구 스크립트, 모델 카드, 의존성 파일과 관련 문서의 사본 및 파일별 해시.
- 같은 폴더의 `evidence/`: 직접 학습 실험 설정·로그·평가 결과. 비공개 전사나 경로가 포함될 수 있으므로 Git에 올리지 않는다.
- `data-manifests/`: 고정된 학습·검증·평가 목록. 원본 오디오는 이동·삭제하지 않는다.
- `source-metadata/`, `*-original-manifest.json`: 삭제할 압축본에서 뽑은 작은 원본 설정·토크나이저·고지와 가중치 해시·리비전·내부 링크 목록.
- `plan.json`, `deletion-journal.json`, `deletion-result.json`: 실제 삭제 경로, 삭제 전 크기·해시, 보존 파일 검증 결과. 결과 파일이 없으면 삭제 완료로 간주하지 않는다.
- `config/model-research-recipes.json`: 원본 고정 판본과 재확보/재생성 절차. 네트워크 실행이나 새 학습은 자동으로 하지 않는다.

소스 Git 커밋만으로 미커밋 코드를 복원할 수 없으므로 실제 소스 사본도 남긴다. 데이터 목록과 출처를 남겼다고 학습 데이터 권리나 공개 배포 승인이 새로 생기는 것은 아니다.

## 다시 필요할 때

공개 기반 가중치는 기록한 저장소의 **고정 revision**에서 다시 받아 기존 SHA-256과 비교한다. 예전 압축본은 삭제하므로 인터넷 없는 전체 복원은 제공하지 않는다. 모델의 현재 다운로드 가능 여부는 **미검증**이며, 향후 재확보 시 확인한다.

Parakeet FP32·Redux는 기존 `script/fetch_asr_candidate.py`의 고정 후보를 사용한다. Qwen 4비트는 레시피의 repo/revision을 사용한다. 직접 학습은 보존된 소스·데이터 목록·설정·의존성으로 별도의 새 출력 폴더에서 수행한다. Whisper 병합·GGML은 남겨 둔 v1 LoRA와 `script/export_whisper_ko_adapter.py`로 새 폴더에 생성한다. 재학습이나 재변환의 파일 해시가 옛 결과와 같을지는 **미검증**이다.

과거 후보를 지정한 CLI는 가중치가 없으면 실패하는 것이 정상이다. 먼저 해당 레시피로 가중치를 다시 준비하거나 보존된 현재 후보를 명시해야 한다. 기존 파서의 기본값이나 과거 성능 문서를 이번 파일 정리 때문에 조용히 변경하지 않는다.

## 이후 실험 보관 규칙

1. 실험마다 목적, 기반/데이터 revision, 코드·환경, seed·학습 설정, 데이터 분할·권리, 평가 조건·결과, 채택/탈락 이유를 기록한다.
2. 공개 기반 모델과 병합·양자화·변환 결과는 버전마다 복제하지 않는다. 같은 해시의 파일은 한 벌만 둔다.
3. 사용하지 않는 비교 후보·중간 epoch는 기록 후 가중치를 지운다. 최종 선택된 작은 어댑터는 한 벌만 보존한다.
4. 연구용 현재 후보 목록에서 빠진 모델은 이 문서와 동일한 기준으로 개별 검토한다. 앱이 실제 쓰는 파일·고유 원본 데이터는 이 규칙만으로 자동 삭제하지 않는다.

이번 작업의 검증은 기록 저장·삭제 전 해시 확인·보존 파일 대조다. 새 학습·추론·앱의 전사 사용자 경로는 **Not verified / 미검증**이다. 외부 업로드와 운영 서비스 요청은 하지 않는다.
