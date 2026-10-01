# Ravil-ASMR 0.5 효율 개선 — 2026-10-01

## 변경과 판단

한국어·영어 품질 기준인 Qwen 1.7B를 유지하면서 경량 Qwen 0.6B, 영어 전용 Parakeet BF16, 최소 메모리 Redux를 추가했다. 모든 모델을 같은 로컬 PCM 파일로 비교했다. [조사 기록](asr-research-2026-10-01.md)은 추가 후보 8개, 관련 연구, dot·로컬·GPU 환경의 차이와 선택 근거를 설명한다. [모델 카드](../config/ravil-asmr-0.5-MODEL_CARD.md)에 출처·라이선스·변환 사실을 명시했다.

이번 변경은 공개 가중치 선택과 실행·저장 최적화다. 새 가중치 학습이나 앱 기본 모델 교체·배포를 수행하지 않았다. 정확도와 속도·메모리의 교환이 있으므로 한 모델이 모든 조건에서 우월하다고 주장하지 않는다.

## 같은 100문장씩 비교

한국어 총 1,278.72초, 영어 총 993.56초. 모델별 동일 첫 파일 1회 워밍업은 제외했다. 수치는 ASR 단계이며 Qwen에는 별도 정렬 모델을 로드하지 않았다. Parakeet은 자체 시각 출력 비용이 포함된다. 로드·해시 시간은 보고서에 별도로 있다. 최대 메모리는 MLX 활성 메모리이며 전체 프로세스 RSS나 배터리가 아니다.

| 언어·후보 | 오류율 | 100문장 전사 시간 | 최대 활성 MLX 메모리 |
|---|---:|---:|---:|
| 한국어 Qwen 1.7B 6비트 | CER 3.30% | 73.049초 | 3.127GB |
| 한국어 Qwen 0.6B 8비트 | CER 3.94% | 37.707초 | 1.937GB |
| 영어 Qwen 1.7B 6비트 | WER 5.35% | 54.791초 | 3.054GB |
| 영어 Qwen 0.6B 8비트 | WER 6.14% | 28.087초 | 1.863GB |
| 영어 Parakeet v3 BF16 | WER 6.27% | 6.760초 | 1.580GB |
| 영어 Redux / MLX | WER 7.59% | 15.077초 | 0.659GB |

한국어 경량 모델은 약 1.94배 빠르며 CER가 약 0.64%p 높았다. 영어 Parakeet은 약 8.11배 빠르며 WER가 약 0.92%p 높았다. Redux는 최소 메모리 후보지만 이 MLX 실행에서 가장 빠른 모델은 아니었다. 한 번의 기기 실행에서 얻은 관측치이며 신뢰구간이나 보편적 순위가 아니다.

원본 결과: `tmp/model-research-20261001/{qwen-large-ko,qwen-small-ko,qwen-large-en,qwen-small-en,parakeet-en,redux-en}.json`. 각 보고서에는 모델 리비전·해시, 입력 매니페스트 해시, 문장별 오류·시간이 있다.

## 구현

- `script/asr_candidates.py`: 원본 체크섬 확인, 고정 로컬 모델 로드, 명시적 지원 범위 검사.
- `script/evaluate_asr_candidates.py`: 동일 자료·워밍업 조건, 한국어 CER와 영어 WER, 시간·메모리 비교.
- `script/transcribe_mlx_qwen_longform.py --asr-variant small8bit`: 0.4의 분할·언어 재시도·정렬 검사를 재사용하는 0.5 경량 경로.
- `script/transcribe_mlx_parakeet.py`: 영어만 허용하는 별도 CLI. 자체 토큰 시각을 단어로 묶고, 오버랩의 단어 소유권·역전·범위를 검사한다. 별도 Qwen 정렬기를 생략한다. 영어로 명시하지 않으면 실행하지 않으며 `auto`나 `ko`는 거부한다. 긴 파일에서 누락이 관측되어 30초 초과 입력은 검증된 VAD 엔진·모델을 지정해야 실행한다.
- `script/convert_parakeet_bf16.py`: FP32 2,508,288,736바이트를 BF16 1,254,184,497바이트로 저장한다. 원본과 고지를 보존한다. 재로드한 20문장 전사가 변환 전 BF16 실행과 20/20 동일했다.
- `script/fetch_asr_candidate.py`: 저장된 리비전과 제한된 파일 패턴으로 다운로드하고 가중치 해시를 검증한다. 로컬 BF16 변환본은 다운로드 대신 변환 스크립트를 사용한다.

## 긴 음성과 실제 녹음

구성된 영어 233.06초를 기본 분할 Parakeet으로 처리하자 76/479단어 오류가 나왔다. 짧은 문장 속도만으로 긴 음성 품질을 보장할 수 없었다. Silero의 **발화 사이를 분할 지점으로만 사용하고 오디오를 삭제하지 않는** 옵션을 추가한 뒤 37/479 = 7.72%로 줄었다. 전사·자체 시각 출력 1.591초, 로드·해시 1.000초, 최대 활성 MLX 메모리 1.657GB. 이 시간에는 사전 VAD 실행과 최종 JSON 저장 시간이 포함되지 않는다. 41개 구간을 저장하고 실제 Ravil 디코더가 다시 읽었다. 구성된 낭독 자료이며 실제 수업이나 검수된 단어 시각 정답을 대신하지 않는다.

다른 원본 문장으로 구성한 영어 239.02초는 52/560 = 9.29% WER, 전사·자체 시각 1.652초, 최대 활성 MLX 메모리 1.608GB였다. 그러나 **95.025–99.265초에 정렬된 단어가 없어 `needs_review`, 종료 코드 3**으로 저장됐다. 38구간의 JSON을 Ravil 디코더가 읽었지만 이 사실을 완전한 전사 성공으로 취급하지 않는다. 이 확인 파일의 원본들은 위 짧은 100문장 평가에도 포함되므로 완전히 보지 않은 데이터라고 주장하지 않는다. `english-confirm-native-vad.json`에 검수 시점을 보존했다.

사용자 허가된 한국어 수업 420초를 두 Qwen 경로에서 **같은 기본 분할, auto 언어, VAD 없음**으로 처리했다. 모두 네트워크를 차단했다.

| 항목 | 품질 1.7B | 경량 0.6B |
|---|---:|---:|
| 전사 | 30.033초 | 14.992초 |
| 별도 시각 정렬 | 4.122초 | 4.342초 |
| 합 | 34.155초 | 19.334초 |
| 최대 활성 MLX 메모리 | 4.229GB | 3.202GB |
| 저장된 전사 구간 | 67 | 68 |
| 비무음 빈 구간 검사 | 0개 | 0개 |

실제 수업의 문장 정답은 미검수다. 구간 수·처리 속도·빈 구간 검사만으로 내용 정확도 개선을 주장하지 않는다. 파일은 `tmp/model-research-20261001/physics-{quality,fast}*.json`에 비공개로 저장했다.

## 검증 범위

- **Implemented:** 경량/영어 전용 추론 경로, 체크섬·언어 범위 검사, 자체 시각 변환, 출처가 있는 BF16 모델 파일.
- **Unit-verified:** 기존 15개와 native adapter 4개, 총 19개 검사 통과. 한국어·auto의 영어 엔진 사용 거부, 긴 파일의 분할 설정 누락 차단, 서브워드 결합, 실제 반복 단어 보존, 시각·텍스트 손상 검사를 포함한다.
- **Physical-device-verified — Mac CLI 범위:** 고정 모델의 실제 추론, 네트워크 차단 실행, 로컬 JSON 저장과 Ravil 디코더 재읽기. 설치 GUI 흐름을 의미하지 않는다.
- **Not verified / 미검증:** 설치 앱의 녹음→전사→DB 저장→재열기, 사람 정답 기준 자연 수업 정확도·시각, 배터리, 다른 Mac, 자동 언어별 엔진 라우팅, 새 학습 가중치, 공개 배포.

다음 정확도 개선은 검수된 수업 정답과 과목 용어를 확보한 뒤 측정한다. 연구에 제시된 문맥 보정·혼용 미세조정의 효과를 이 모델에 이미 구현한 것으로 표시하지 않는다.

## 재현 경로

```sh
# 고정 소스 다운로드. local BF16 사본은 아래 변환 명령으로 만든다.
tmp/model-opt/venv/bin/python script/fetch_asr_candidate.py qwen-0.6b-8bit --models tmp/model-opt/models
tmp/model-opt/venv/bin/python script/fetch_asr_candidate.py parakeet-v3-bf16 --models tmp/model-opt/models
tmp/model-opt/venv/bin/python script/convert_parakeet_bf16.py \
  --models tmp/model-opt/models --output /absolute/new/parakeet-bf16-directory

# 같은 매니페스트로 비교; 각 output은 새로운 파일이어야 한다.
tmp/model-opt/venv/bin/python script/evaluate_asr_candidates.py \
  --candidate qwen-0.6b-8bit --models tmp/model-opt/models \
  --manifest tmp/model-opt/bilingual-eval-v2/korean.jsonl --output /absolute/new/ko-report.json

# 영어 전용. 30초를 넘으면 고정 VAD 엔진과 모델을 함께 지정한다.
tmp/model-opt/venv/bin/python script/transcribe_mlx_parakeet.py \
  --audio /absolute/english-only-pcm16.wav --language en --models tmp/model-opt/models \
  --vad-engine tmp/model-opt/whisper-build/bin/whisper-vad-speech-segments \
  --vad-model tmp/model-opt/models/ggml-silero-v6.2.0.bin \
  --output /absolute/new/transcript.json --metrics /absolute/new/metrics.json
```

전사 CLI의 기본 영어 변환본 경로는 registry의 `parakeet-tdt-0.6b-v3-bf16-ravil`이다. 다른 위치로 변환할 때는 명시적으로 registry/모델 루트를 맞춘다. 원본 FP32 파일을 로드 시 BF16으로 사용하는 기존 후보는 `--candidate parakeet-v3-bf16`으로 선택할 수 있다. 변환된 사본과 원본 파일의 SHA-256을 혼용하지 않는다.
