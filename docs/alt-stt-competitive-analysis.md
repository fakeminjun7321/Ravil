# Alt 음성 모델·처리 경로 분석과 Ravil 실험 · 2026-09-30

## 확인한 사실과 범위

설치된 Alt 0.13.0의 파일과 이 Mac의 로컬 자산을 **읽기 전용**으로 확인했다. `Alt.app/Contents/Resources/models.json`은 Whisper large-v3-turbo q5_0 디코더, macOS Core ML 인코더, Windows OpenVINO 인코더, 로컬 LLM 후보를 목록에 둔다. 실제로 이 Mac에 있는 GGML 디코더의 SHA-256은 `394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2`로 [공개 whisper.cpp 배포본](https://huggingface.co/ggerganov/whisper.cpp)과 같다. 약 1.2GB의 Core ML 인코더와 Silero v6.2.0 VAD 파일도 있다. VAD 파일 해시 `2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987`은 [ggml-org 공개본](https://huggingface.co/ggml-org/whisper-vad)과 같다. 로컬 DB에는 speaker profile/voiceprint 테이블이 있다.

이 자산과 테이블의 **존재**만으로 특정 녹음에 어느 모델·설정이 쓰였는지 증명할 수 없다. 모델 목록의 Gemma 계열은 이 Mac의 다운로드 모델 폴더에서 확인되지 않았으므로 설치·실행됐다고 표시하지 않는다. [Alt 제품 사이트](https://www.altalt.io/)는 Core ML 인코더·MLX 디코더와 화자 분리를 홍보하고, [공개 Lightning-SimulWhisper 저장소](https://github.com/altalt-org/Lightning-SimulWhisper)는 MLX/Core ML 동시 전사 구현을 설명한다. 사이트 속도 수치는 Alt의 자체 측정이며 현재 설치 앱의 모든 사용자 경로를 재현한 결과가 아니다.

## 선행연구에서 가져올 실험 가설

- [WhisperX 논문](https://arxiv.org/abs/2303.00747)은 긴 녹음의 반복·환각·시간 표류 문제에 VAD 기반 분할과 강제 정렬을 적용한다. 따라서 Ravil도 **긴 녹음**에서 무음 비율·누락·시각 오차를 측정할 가치가 있다. 짧은 문장까지 VAD를 일괄 적용해야 한다는 뜻은 아니다.
- [SimulStreaming/Whisper 동시 전사 공개 구현](https://github.com/altalt-org/Lightning-SimulWhisper)은 Core ML 인코더와 MLX 디코더로 지연을 줄이는 경로를 보인다. Ravil은 이를 직접 복제한다고 가정하지 않고, 동일 기기·동일 오디오에서 인코더/디코더 시간과 전력 사용을 분리 측정해야 한다.
- [Qwen3-ASR 공식 모델](https://github.com/QwenLM/Qwen3-ASR)은 한국어를 지원하고 별도 ForcedAligner로 시간 정렬을 제공한다. Ravil의 MLX 4비트 ASR 단독 실행에서는 실제 20초 클립에 **0~20초 구간 하나**만 나왔다. 4비트 정렬 모델(약 971MB)을 더해 120초 실제 녹음을 203단어·16구간으로 만들었고 정렬 시간은 약 2.0초였다. 한국어 단어 시각의 정확도는 사람이 확인한 기준으로 검사해야 한다.

## 이번 비교의 실제 결과

FLEURS 한국어 test 100문장·4,667자를 같은 문자 정규화로 비교했다. 이 자료는 읽기 음성이라 교실 잡음·수식·다중 화자를 대표하지 않는다.

| 경로 | 가중치 크기 | 문자 오류 | 오류율 | 100문장 추론 시간 합 |
|---|---:|---:|---:|---:|
| Ravil 기존 Whisper Turbo q5_0, `whisper.cpp` | 574MB | 191 | 4.09% | 108.9초 |
| Qwen3-ASR 1.7B, PyTorch MPS | 4.08GB | 148 | 3.17% | 277.9초 |
| Qwen3-ASR 1.7B 4비트, MLX | 1.60GB | 173 | 3.71% | 75.8초 |

MLX 모델은 [MLX Community 변환본](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-4bit) 리비전 `78a389c776a5483b2d0d4ea5494e11012e0d6159`, SHA-256 `9848eaf7a5c1589c671b35035ac27b72e248dd0c604eacae547e7e403d29db45`이며 Apache-2.0으로 표시된다. 실행 코드는 [mlx-audio](https://github.com/Blaizzy/mlx-audio) 커밋 `94c7716212b2228f178d2f9c7619a591fd1b0b78`(MIT)으로 고정했다. Mac M5에서 MLX 모델 로드 후 활성 메모리는 약 1.61GB, 평가 중 최대 약 2.70GB였다. Qwen 두 경로는 한 번 로드해 연속 추론했고, Turbo는 샘플마다 실행 파일을 새로 시작했으므로 이 시간 합은 동일한 앱 지연 비교가 아니다. MLX 4비트는 원본보다 25글자 더 틀리지만 2.5배 작은 가중치와 이 측정에서 약 3.7배 빠른 추론을 보였다.

Silero VAD도 [원제작자 MIT 저장소](https://github.com/snakers4/silero-vad)와 ggml-org의 고정 파일에서 별도로 받았다. 앞뒤에 무음이 있는 합성 한국어 문장에서 Ravil의 새 소스 빌드 `whisper.cpp`는 VAD 없이 구간을 0~13.24초, VAD를 쓰면 실제 발화인 약 9.99~13.19초로 표시했다. 반면 FLEURS의 짧은 20문장에서는 VAD 없이 13글자, VAD 사용 시 19글자를 틀렸고 시간 합도 21.75초에서 23.08초로 늘었다. **VAD 기본 활성화는 보류한다.**

기존 Ravil 번들 `whisper-cli`는 Homebrew 플러그인을 먼저 읽은 상태에서 VAD 실행 시 종료 신호 11로 충돌했다. Homebrew 플러그인 읽기를 차단하면 번들 플러그인으로 성공했다. `script/build_whisper_runtime.sh`는 공개 `whisper.cpp` 커밋 `6e4ab854f67f743900934a703d5603419384c961`을 빌드해 절대 Homebrew 백엔드 검색 경로가 없는 실행 파일·플러그인·VAD·고지문을 묶는다. 격리된 Ravil 앱에 넣고 Homebrew 읽기를 차단한 헤드리스 전사에서 정상 작동했다. 기존 설치 앱은 교체하지 않았다.

## Ravil 개발 우선순위

1. 소스 빌드 런타임의 다른 Mac 설치·장시간 녹음·기본 전사 회귀를 확인한다. 기존 Homebrew 복사 방식은 이 경로가 충분히 검증될 때까지 기본값으로 남기되 VAD에는 사용하지 않는다.
2. VAD는 긴 녹음·무음 비율이 높은 구간에 한정해 실수업 정답으로 누락과 시간 오차를 측정한다. 짧은 음성은 VAD 없이 유지한다.
3. MLX 4비트 Qwen은 빠른 재전사 후보로 평가한다. ForcedAligner까지 포함한 120초 처리 시간·메모리와 Ravil JSON 계약은 확인했다. 한국어 강의의 사람이 검수한 전사·용어·단어 시각과 설치 앱 경로가 확인되기 전에는 앱 기본 모델로 승격하지 않는다.
4. 사용자가 허락한 학습지는 과목 용어 후보와 출처 문맥으로 수집한다. 녹음과 맞춘 검수 전사가 없는 PDF 문장을 음성 학습 정답으로 간주하지 않는다.
5. 화자 분리·요약 모델은 전사 정확도와 다른 층으로 평가한다. Alt의 공개 기능 설명이나 자산 목록을 그 성능의 검증치로 대체하지 않는다.
