# Ravil ASR 후보·연구 조사 — 2026-10-01

범위: 한국어, 영어, 한영 혼용. 공개 출처와 모델 배포 조건을 추적하고, Apple M5에서 정확도·속도·활성 메모리를 함께 비교한다. 모델 카드와 논문의 초록·관련 방법·실험 절을 검토했다. 아래의 외부 보고 수치는 저자의 조건이며 Ravil 실측으로 간주하지 않는다.

## 실행 환경: dot, 노트북, 학습용 GPU

[dot 공식 안내](https://learn.chatgpt.com/docs/dots/computers-and-apps)는 클라우드 컴퓨터에서 조사·문서·소프트웨어 작업을 이어가거나 연결된 개인 컴퓨터의 작업을 관리할 수 있다고 설명한다. 개인 컴퓨터를 쓰는 단계에는 해당 컴퓨터가 온라인이고 앱이 열려 있어야 한다. 같은 Mac에서 같은 실험을 실행하면 dot이 관리하더라도 연산 장치는 Mac이다.

[Codex Cloud 공식 사양](https://learn.chatgpt.com/docs/environments/cloud-environments)은 Pro/Business/Enterprise 기본 VM에 4 vCPU, 16 GiB 메모리, 32 GiB 디스크를 명시한다. **이것은 Codex Cloud 사양이며 dot 자체 컴퓨터의 사양이라고 단정할 수 없다.** 확인한 안내에서는 모델 학습용 GPU 보장을 찾지 못했다. MLX는 현재 Apple Silicon 실험 경로이므로 클라우드로 옮길 때 런타임과 하드웨어를 다시 확인해야 한다.

판단: 조사·실험 계획·장시간 작업 관리에는 dot의 지속성이 유용하다. Mac용 Ravil의 성능·배포 검증은 실제 Mac에서 수행한다. 대규모 미세조정이 필요해지면 GPU 종류·메모리·시간·비용이 명확한 별도 환경을 검토한다. 이번 작업에서 클라우드 이전, 계정 연결, GPU 구매 또는 비공개 녹음 업로드는 수행하지 않았다.

## 후보 비교

| 후보 | 목적·지원 | 확인한 조건 | 이번 결정 |
|---|---|---|---|
| [Qwen3-ASR 1.7B](https://huggingface.co/Qwen/Qwen3-ASR-1.7B) | 한국어·영어·혼용의 기존 품질 기준 | Apache-2.0, 6비트 MLX 고정 변환본 | 동일 조건으로 기준 재측정 |
| [Qwen3-ASR 0.6B 8비트](https://huggingface.co/mlx-community/Qwen3-ASR-0.6B-8bit) | 두 언어를 지원하는 경량 후보 | Apache-2.0, 약 1.01GB 가중치 | 다운로드·100문장씩 실측, 긴 전사 CLI에 선택 옵션 추가 |
| [Parakeet TDT v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) | 영어 고속 처리, 자체 시각 출력 | CC BY 4.0, 25개 유럽 언어이며 한국어 미지원 | BF16 실측, 영어 전용 경로 구현 |
| [Parakeet Redux](https://huggingface.co/moondream/parakeet-redux) | 178MB 삼진 가중치, 최소 메모리 후보 | CC BY 4.0, 원본과 같은 지원 언어 | 다운로드·영어 실측. Photon의 광고 속도를 MLX 속도로 인용하지 않음 |
| [Cohere Transcribe 03-2026](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026) | 2B, 한국어·영어 포함 14개 언어 | Apache-2.0 표기, 원본 파일 접근에는 연락처 제공 동의 안내 | 조사 후보로 유지. 다운로드·실측하지 않음 |
| [SenseVoiceSmall](https://huggingface.co/FunAudioLLM/SenseVoiceSmall) | 한국어·영어, 비자기회귀 구조 | 코드와 별개로 모델 카드에 `model-license` 표기 | 배포 조건을 추가 검토할 후보, 실측하지 않음 |
| [Moonshine Tiny Korean](https://huggingface.co/moonshine-ai/moonshine-tiny-ko) | 작은 한국어 전용 모델 | 전용 Community License. [원본 조건](https://huggingface.co/UsefulSensors/moonshine-tiny-ko/blob/645d05c368da789ad41bdc12f2ec416e2bfa974f/LICENSE.txt)에 상업 사용 등록·매출 조건 등이 있음 | 영어 Moonshine의 MIT 표기를 한국어 가중치에 적용하지 않음. 출시 우선 후보에서 제외 |
| [Qwen-Audio-3.0-ASR](https://arxiv.org/html/2609.07549v2) | 2026년 9월 보고, MoE·용어·장기 문맥 | Fun-ASR 계열 후속 시스템. Qwen3-ASR 1.7B와 같은 이름의 새 체크포인트가 아님 | 아이디어 참고. 이번 조사에서 배포 가능한 고정 공개 가중치를 확인하지 못해 로컬 실행했다고 주장하지 않음 |

원본·변환본 리비전, 해시, 라이선스 및 Ravil 지원 범위는 `config/asr-candidates-20261001.json`에 기록한다. 한국어가 섞인 영어 **과목** 녹음을 영어 전용 모델에 보내지 않는다. 과목 이름은 언어 판별 근거가 아니다.

## 연구에서 채택할 방법

1. **계산 구조를 바꾸는 영어 고속 경로.** [Fast Conformer](https://arxiv.org/abs/2305.05084)는 다운샘플링과 제한된 문맥으로 긴 음성의 계산 부담을 줄이는 방향을 제시한다. Parakeet의 자체 시각을 사용하면 Ravil의 별도 0.6B 정렬 모델도 생략할 수 있다. 이번에 구현·측정하는 항목이다. 다른 기기의 논문 가속 배율을 이 Mac의 성능으로 가져오지 않는다.

2. **작은 초안과 큰 최종 모델의 역할 분리.** [Qwen3-ASR 보고](https://arxiv.org/abs/2601.21337)는 0.6B의 효율과 1.7B의 품질 차이를 설명한다. [Qwen-Audio-3.0의 스트리밍 절](https://arxiv.org/html/2609.07549v2#S4.SS2)은 빠른 임시 결과를 발화 종료 후 전체 문맥으로 갱신하는 구성을 설명한다. Ravil에서는 먼저 경량·품질 선택지를 측정하고, 검수된 데이터로 불확실성 기준을 보정한 뒤 선택적 재전사를 검토한다. **자동 라우팅·증류 학습은 아직 구현하지 않았다.**

3. **학습지 전체를 프롬프트에 넣지 않고 용어를 골라 사용.** [CTC Word Spotter 연구](https://arxiv.org/abs/2406.07096)는 희귀어를 음향 증거와 연결하는 문맥 보정 방법을 제안한다. [Qwen-Audio-3.0 §5.4](https://arxiv.org/html/2609.07549v2#S5.SS4)는 용어를 확신도에 따라 구분한 조건부 디코딩을 보고한다. Ravil의 적용 가설은 최신 학습지의 검수된 용어 중 관련성이 높은 소수만 사용하는 것이다. 모델 구조·학습이 다른 Qwen3-ASR에 같은 프롬프트만 주면 논문 효과가 재현된다고 가정하지 않는다. 기존 용어 후보는 미검수여서 자동 반영하지 않는다.

4. **한영 혼용 학습과 단일 언어 퇴행을 함께 평가.** [Code-switching Under the Lens](https://arxiv.org/html/2509.24310v1)의 Mandarin–English 실험은 혼용 미세조정의 효과와 단일 언어 성능 저하를 함께 보여 준다. 한영에서 같은 수치를 기대할 근거는 없지만, 두 언어의 단독 평가를 유지해야 한다는 실험 설계에 반영한다. 실제 혼용 정답과 독립 강의 평가를 확보한 뒤 어댑터를 학습한다. 이어 붙인 낭독은 문장 내부 혼용을 대신하지 않는다.

5. **기기별 정수 연산은 후속 경로.** [I-Parakeet 초록](https://arxiv.org/abs/2609.30846)은 Qualcomm NPU의 정수 전용 Conformer 실행을 제안한다. Apple GPU/ANE에 바로 적용 가능한 구현이라고 보지 않는다. 지금은 검증 가능한 MLX BF16·양자화 가중치를 비교하며, 향후 실제 Apple 런타임을 별도로 측정한다.

## 평가 기준

- 기존에 준비한 FLEURS 한국어 100문장과 영어 100문장의 **동일 PCM16 파일**을 사용한다. 한국어 CER, 영어 WER를 별도로 보고한다.
- 모델마다 첫 파일 1회 워밍업을 제외한 뒤 측정한다. 가중치 해시 검사와 로드는 별도 시간이다. Qwen 비교에는 별도 정렬 모델을 넣지 않으며 Parakeet은 자체 시각 출력 비용이 포함된다.
- 한 번의 Mac 실행에 따른 관측치다. 배터리, 열 안정성, 전체 프로세스 메모리, 자연 수업 정확도와 통계적 우위를 증명하지 않는다.
- 배포 기본값은 측정 결과만으로 몰래 바꾸지 않는다. 속도·메모리와 오류율의 교환을 명시한 실험 프로필을 만든다.

실측 보고서는 `tmp/model-research-20261001/`에 비공개 저장한다. [0.5 개발 기록](ravil-asmr-0.5-development.md)에 최종 수치, 채택 범위, 실패와 실제 실행 검증을 기록한다.
