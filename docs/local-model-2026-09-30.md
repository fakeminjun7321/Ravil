# Ravil 로컬 모델 작업 기록 · 2026-09-30

## 이번에 바뀐 것

- 빌드의 기본 모델 입력을 Alt 설치 폴더에서 Ravil 전용 캐시로 바꿨다. 기존 설정에 Alt 모델 경로가 저장돼 있어도 기본 번들/캐시 모델로 옮겨 간다.
- `script/fetch_local_model.sh`가 whisper.cpp 관리자의 고정 리비전에서 Whisper large-v3-turbo q5_0 파일을 받고 SHA-256이 일치할 때만 캐시에 둔다. 빌드는 같은 해시를 다시 검사한다. 다운로드는 명시적으로 스크립트를 실행할 때만 발생한다.
- 앱 번들에 원모델 MIT 라이선스, 출처·변환자·리비전·해시·변경 여부를 밝힌 모델 카드를 포함했다. 설정 화면에도 모델과 변환자의 이름을 표시한다.
- DMG 포장 단계는 모델 카드·라이선스·출처 파일과 모델 해시가 현재 소스의 기록과 일치하지 않으면 중단한다. 기존 0.6.2 DMG는 교체하지 않았다.
- `--transcription-check`의 원시 출력은 임시 폴더에 작성해 검사 후 제거한다. 일반 강의 전사의 보존 경로는 유지한다.
- `script/evaluate_local_stt.py`는 권리 근거가 적힌 평가 JSONL에서 전사를 실행해 CER·영어 WER·소요 시간·실제 모델 해시를 보고한다. 평가 텍스트와 오디오는 결과 JSON에 넣지 않는다. 같은 입력과 `--model` 인자로 다른 GGML 후보를 비교할 수 있다.

## 출처와 지위

원모델은 OpenAI Whisper large-v3-turbo다. GGML q5_0 파일은 [whisper.cpp 관리자의 모델 저장소](https://huggingface.co/ggerganov/whisper.cpp) 리비전 `5359861c739e955e79d9a303bcbc70fb988958b1`에서 별도로 받았다. SHA-256은 `394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2`다. OpenAI의 [Whisper 저장소](https://github.com/openai/whisper)는 코드와 가중치를 MIT로 공개하며, 모델 저장소도 MIT를 표시한다. 번들에는 `Models/MODEL_CARD.md`, `Models/LICENSE`, `Models/source.env`가 들어간다.

이 파일은 예전 Alt 폴더 파일과 **바이트 해시가 같다**. 이번 변경은 조달·빌드 의존성 제거이며, Ravil이 새로 학습한 가중치나 Alt 대비 정확도 향상이 아니다. Ravil 전용 파생 모델을 공개하려면 기반 모델 외에 추가 학습 데이터의 권리·동의, 학습 설정, 변경된 가중치 해시와 실제 강의 평가를 별도로 기록해야 한다. 학교 녹음과 Goodnotes 자료는 권리가 확인되지 않은 상태에서 학습에 사용하지 않는다.

## 검증

- **Implemented:** 공개 출처 다운로드, SHA-256 확인, Alt 없는 기본 모델 경로, 번들 안 모델 카드·라이선스.
- **Build-verified:** SwiftPM release 빌드, 격리된 `tmp/local-model-check/Ravil.app`의 ad-hoc 서명 검사, 번들 모델 해시 및 모델 카드 원본 대조가 통과했다. 기존 `dist/Ravil.app`은 교체하지 않았다.
- **Headless runtime-verified:** 같은 격리 번들에서 합성 영어·한국어 WAV를 전사해 타임스탬프가 있는 구간을 얻었다. 한국어 문장은 `라빌은 강의를 녹음하고 학습 자료를 정리합니다.`로 출력됐다. Homebrew GGML 플러그인 경로 읽기를 거부한 제한 실행에서 번들 BLAS·Metal·CPU 플러그인이 로드되고 한국어 전사가 완료됐다.
- **Unit-verified:** `npm test` 16개 통과. 기존 Alt 연동 및 자료 로직 검사이며 로컬 모델 품질 검사는 아니다.
- **평가 도구 확인:** `say`로 만든 내부 시험용 영어·한국어 음성 2개에서 평가 JSON을 얻었다. 합성 문장 2개는 실수업 정확도나 Alt 대비 우위를 판단할 표본이 아니다. `rights_reference`는 검토 기록을 요구할 뿐, 도구가 실제 이용 권리를 법적으로 판정하지는 않는다.
- **Not verified / 미검증:** 설치 앱 UI의 실제 녹음 → 전사 경로, Alt 앱이 없는 다른 Mac, 긴 수업·전문 용어·화자 구분, Alt 대비 품질 우위, Ravil이 직접 학습한 새 가중치, 공개 배포 전체의 권리·서명·공증.

## 다음 모델 개발 기준

1. 권리 확인된 한국어 수업 평가 음성·사람이 검수한 전사문을 학습 자료와 분리해 만든다. Alt 결과는 비교 대상일 뿐 정답으로 쓰지 않는다.
2. 현 기준 모델과 독립 후보의 CER, 영어 WER, 과목 용어, 무음 환각, 시간 오차, 지연·메모리를 같은 조건에서 측정한다.
3. 관찰된 약점에 대응하는 구간 처리·용어 문맥을 먼저 개선한다. 공개 가중치만으로 목표에 못 미칠 때, 권리가 명시된 데이터로 미세조정한다.
4. 공개할 파생 모델마다 기반 가중치, 데이터셋, 변환/학습 방법, 라이선스 고지, 해시와 제한 사항을 새 모델 카드에 기록한다. 출시 판본의 파일과 문서가 실제로 일치하는지 검사한다.

권리 검토 후보로 [Mozilla Common Voice의 한국어 27.0 목록](https://commonvoice.mozilla.org/en/datasets)을 확인했다. 목록에는 CC0-1.0으로 표시되지만, 실제로 사용할 판본의 데이터시트와 [Common Voice 이용 조건](https://commonvoice.mozilla.org/en/terms)을 다시 확인해야 한다. 데이터 자체를 재배포하거나 화자 신원을 추정하지 않는 조건도 지킨다. 아직 내려받거나 학습에 사용하지 않았다.

평가 입력의 각 JSONL 행은 `id`, 절대 경로 `audio_path`, 사람이 검수한 `reference`, `language` (`ko`/`en`/`ja`/`zh`), `subject`, `split: "eval"`, `rights_reference`를 포함한다. `python3 script/evaluate_local_stt.py <manifest.jsonl> --app <Ravil.app>`로 실행한다. 학습에 쓰는 원본과 평가는 다른 목록으로 관리한다.
