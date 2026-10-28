# Ravil-ASMR 모델 개발 기록 · 2026-09-30

이어진 Apple Silicon 양자화, Alt 경쟁 경로, VAD 및 단어 시각 실험은
[Ravil-ASMR 최적화 기록](ravil-asmr-optimization.md)에 정리했다.

`Ravil-ASMR-버전`은 사용자가 제안한 **잠정 출시명**이다. 현재 산출물은 `Ravil-ASMR-0.1-experimental`로 구분하며 출시·공개하지 않는다. ASMR은 이미 다른 의미로 널리 쓰이므로 제품 설명에서는 음성인식 모델임을 분명히 밝혀야 한다. [저작권청의 이름·짧은 문구 안내](https://www.copyright.gov/help/faq/faq-protect.html)처럼 이름 자체의 저작권과 출시 국가의 상표 충돌은 별개다. [KIPRIS](https://www.kipris.or.kr/) 등 대상 국가의 정식 상표 검색과 유사 표장 검토는 출시 전 과제로 남긴다. 이 문서는 상표 사용 가능 판정이 아니다.

## 이번에 실제로 만든 모델

- 기반: `openai/whisper-tiny` 고정 리비전 `169d4a4341b33bc18d8881c4b69c2e104e1cc0af`.
- Ravil 변경: attention `q_proj`·`v_proj`에 rank-4 LoRA를 학습했다. 학습 가능한 매개변수 73,728개. Mac M5의 MPS에서 학습했다.
- 학습 자료: Google FLEURS 한국어 고정 리비전 `70bb2e84b976b7e960aa89f1c648e09c59f894dd`의 dev 음성 129문장, 3회 학습. 평가에는 학습에 쓰지 않은 test 음성 100문장을 사용했다. [데이터 카드](https://huggingface.co/datasets/google/fleurs)는 CC BY 4.0이며, [라이선스](https://creativecommons.org/licenses/by/4.0/)에 맞춰 Google/FLEURS·논문·수정 사실을 모델 카드에 표시했다. 데이터 아카이브는 모델 산출물에 포함하지 않는다.
- 어댑터: `tmp/model-dev/experiments/ravil-stt-tiny-ko-lora-v1/adapter_model.safetensors`, SHA-256 `5a58dc4fddd2c4d7936b6b0a41716e78122b3399bb13274acd936ec0ed7b708b`.
- Mac 실행용 GGML 변환본: `tmp/model-dev/experiments/ravil-stt-tiny-ko-lora-v1/ggml-export/ggml-ravil-stt-tiny-ko-lora-v1.bin`, SHA-256 `e8eb72662d21a3b34729b5a68c404f95b3f4781621e5068fa152d9ced10b9170`. 변환은 whisper.cpp 커밋 `6e4ab854f67f743900934a703d5603419384c961`과 OpenAI Whisper 자산 커밋 `86098128c0b4f24f0e2aa2994de830614b474227`을 사용했다.

기반 가중치는 Ravil이 처음부터 학습한 것이 아니다. 이 어댑터와 GGML 변환본은 **Ravil이 학습·변환한 파생 산출물**이다. [OpenAI Whisper 원본](https://github.com/openai/whisper)은 MIT를 명시하지만 [학습에 사용한 Hugging Face 체크포인트](https://huggingface.co/openai/whisper-tiny)는 Apache-2.0으로 표시한다. 공개 전 두 고지의 적용 범위를 정리하고 모두 보존한다. 권리 검토가 끝났다는 주장으로 취급하지 않는다.

## 평가 결과

| 같은 조건의 비교 | 기반 모델 문자 오류율 | Ravil 어댑터 문자 오류율 | 범위 |
|---|---:|---:|---|
| Hugging Face 실행 | 16.73% | 16.07% | FLEURS 한국어 test 100문장, 4,667자 |
| whisper.cpp GGML 실행 | 15.19% | 14.78% | 같은 100문장. 변환 모델에서 JSON UTF-8 오류 2건 발생 |

처음 만든 64문장·1회 학습 어댑터는 Hugging Face 100문장 평가에서 16.73% → 16.97%로 악화됐다. 따라서 학습했다는 사실만으로 품질 개선을 주장하지 않는다. 두 번째 어댑터의 저장 파일을 새 프로세스에서 다시 읽어 16.07%를 재현했고, GGML 변환본도 번들 `whisper.cpp`에서 한국어 음성을 처리했다. 다만 GGML 100문장 중 **2문장에서 올바르지 않은 UTF-8 JSON**을 출력해 현재 앱 기본 모델로 넣지 않는다. GGML 평가 점수에는 해당 바이트를 대체 문자로 처리한 결과가 포함됐다.

## 다른 공개 모델과 현재 앱 모델

공식 [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR)의 0.6B·1.7B 가중치(각 Apache-2.0)를 별도로 받아 Mac MPS에서 네트워크 없이 실행했다. 1.7B 모델은 [공식 체크포인트](https://huggingface.co/Qwen/Qwen3-ASR-1.7B-hf) 리비전 `bcd2b5b7f32b480ab5790554cfa8347f246a14f3`, SHA-256 `2db53c7d81bd9b8cbc6a074e89be2c968a0d373fb4ee68bb1b1e14f7042dfee1`로 고정했다. 0.6B는 리비전 `7f1569a48a89f3e3f4dc3a5c9d28bddd903bc76c`, SHA-256 `d3f212dd20abecd315d830bc54ae3865e56ebfc3276484e57b771288ba27fd35`다.

FLEURS test의 같은 20문장에서는 현재 Ravil의 Whisper large-v3-turbo 1.54%, Qwen3-ASR 0.6B 1.66%, 1.7B 1.42%였다. 같은 100문장(4,667자)으로 늘린 결과는 다음과 같다.

| 모델 | 원본 가중치 크기 | 문자 오류 | 문자 오류율 | 측정한 추론 시간 합 |
|---|---:|---:|---:|---:|
| 현재 Ravil Whisper Turbo q5_0 | 574 MB | 191 | 4.09% | 109초 |
| Qwen3-ASR 0.6B | 1.56 GB | 190 | 4.07% | 124초 |
| Qwen3-ASR 1.7B | 4.08 GB | 148 | 3.17% | 278초 |

이는 **공개 읽기 음성** 결과이며 실제 수업의 정확도를 뜻하지 않는다. 이 실험에서 Qwen은 기존 `whisper.cpp` 앱 실행 경로와 연결되지 않았고 별도 Python 런타임을 사용했다. Qwen은 모델을 한 번 로드한 뒤 100문장을 처리했고, Turbo는 각 문장에서 새 프로세스를 실행했다. 따라서 시간 합은 그대로 앱 지연의 공정한 비교가 아니다. 1.7B의 이 표본 품질 우위와 더 큰 용량·처리 부담을 모두 실제 강의로 다시 확인해야 한다.

사용자가 기존 녹음·학습지를 로컬 학습에 사용하도록 허락했다. Ravil DB에서 녹음 자산 14개와 전사 구간 10,009개를 읽기 전용으로 확인했다. 평가용으로 현물·국어·영어 녹음에서 각각 20초를 **복사**했으며 원본은 변경하지 않았다. 현재 Alt 전사는 사람이 검수한 정답이 아니다. 특히 일부 녹음은 오디오 길이와 전사 종료 시간이 크게 달라 자동 대응이 불가능했고, 영어 녹음의 Alt 문장은 한국어 위주여서 영어 전사의 정확도 기준으로 사용할 수 없었다. `script/prepare_ravil_recording_clips.py`는 길이가 맞지 않는 자산을 제외하며, 언어가 다른 약한 참고 전사는 제외한다. 이 클립과 비교 결과는 무시되는 `tmp/model-dev/` 아래에만 있고 외부 API로 보내지 않았다. 학습지는 음성 정답이 아니라 과목 용어·문맥 후보로 다룬다.

사용자의 로컬 학습 허가는 **모델 가중치를 공개할 때 필요한 제3자 음성·학습지 권리 확인을 대신하지 않는다.** 이번 어댑터에는 학교 녹음, 학습지, Alt 전사문을 학습 데이터로 쓰지 않았다.

로컬 `tmp/model-dev/private-eval-prepared/review.html`에는 세 구간의 오디오와 Alt·Whisper·Qwen 전사를 나란히 배치했다. 브라우저에서 직접 들은 문장을 입력하면 JSONL로 내려받는 정적 페이지이며 외부 서비스를 호출하지 않는다. 1200×900 크기의 렌더에서 글자·카드 배치를 확인했다. **오디오 재생과 검수 JSONL 다운로드의 실제 사용자 경로는 미검증**이다. 검수 결과가 생기기 전에는 세 전사 중 어느 것도 학습 정답으로 승격하지 않는다.

## 재현 방법과 다음 기준

`script/fetch_fleurs_ko.sh`는 원본 아카이브의 고정 SHA-256을 확인한다. `script/prepare_fleurs_ko.py`는 훈련·평가 파일을 분리한다. `script/train_whisper_ko_adapter.py`, `script/evaluate_whisper_ko_adapter.py`, `script/export_whisper_ko_adapter.py`가 학습·재검증·GGML 변환을 맡는다. 의존성 판본은 `config/model-dev-requirements.txt`에 고정했다. 실제 녹음과 Qwen/Whisper 비교에는 `script/prepare_ravil_recording_clips.py`, `script/evaluate_qwen3_asr.py`, `script/evaluate_whisper_clips.py`를 사용한다. 로컬 검수 페이지는 `script/create_asr_review.py`로 다시 만들 수 있다.

다음 모델을 앱에 넣기 전에는 (1) 실제 강의의 사람이 검수한 전사 정답, (2) 길이·시점이 맞는 오디오, (3) 한국어·영어 혼용과 과목 용어별 평가, (4) 잘못된 UTF-8 출력 0건 및 실패 복구, (5) 기기 자원·배터리 측정, (6) 출처·라이선스·학습 자료 권리와 공개 모델 카드, (7) 출시명 상표 검토가 필요하다. 현재 Ravil의 기본 Turbo 모델과 기존 DMG는 유지한다.
