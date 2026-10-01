# 제삼자 구성요소와 출처

이 소스 저장소에는 모델 가중치, 학습용 음성 코퍼스, 개인 녹음·학습지 또는 다른 앱의 실행 파일이 포함되지 않습니다. 아래는 개발·실행 중 별도로 사용하는 주요 구성요소입니다. 실제 배포 패키지는 포함하는 모든 구성요소의 라이선스·고지문을 다시 확인해야 합니다.

| 구성요소 | 출처 | 확인한 라이선스 |
|---|---|---|
| Whisper / whisper.cpp | [OpenAI Whisper](https://github.com/openai/whisper), [whisper.cpp](https://github.com/ggml-org/whisper.cpp) | MIT |
| Qwen3-ASR / ForcedAligner | [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR) | Apache-2.0 |
| Qwen MLX 변환 가중치 | [MLX Community](https://huggingface.co/mlx-community) | 개별 모델 카드의 Apache-2.0 |
| Parakeet v3 | [NVIDIA](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) | CC BY 4.0 |
| Parakeet Redux | [Moondream](https://huggingface.co/moondream/parakeet-redux) | CC BY 4.0 |
| MLX / mlx-audio | [MLX](https://github.com/ml-explore/mlx), [mlx-audio](https://github.com/Blaizzy/mlx-audio) | MIT |
| Silero VAD | [Silero](https://github.com/snakers4/silero-vad) | MIT |
| FLEURS 평가·학습 자료 | [Google FLEURS](https://huggingface.co/datasets/google/fleurs) | CC BY 4.0 |

모델별 고정 리비전·SHA-256·원본과 변환본의 관계·Ravil 변경 사항은 다음 파일에 기록합니다.

- [기본 로컬 전사 모델](config/local-stt-MODEL_CARD.md)
- [ASMR 0.4](config/ravil-asmr-0.4-MODEL_CARD.md)
- [ASMR 0.5](config/ravil-asmr-0.5-MODEL_CARD.md)
- [후보 레지스트리](config/asr-candidates-20261001.json)

Apache-2.0 구성요소의 배포에는 라이선스 사본, 변경 표시와 해당 NOTICE 보존 등이 필요합니다. CC BY 4.0 구성요소에는 적절한 출처·라이선스 링크·변경 표시가 필요합니다. MIT 구성요소의 저작권·허가문도 보존해야 합니다. 모델 다운로드 허용을 원본 저작권 소유권 이전이나 상표 사용 허락으로 해석하지 않습니다.
