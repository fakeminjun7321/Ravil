# Ravil macOS DMG

`script/package_dmg.sh`는 이미 빌드된 앱 번들을 버전별 DMG로 포장한다. 기본 입력은 `dist/Ravil.app`이며 `RAVIL_APP_BUNDLE` 환경 변수로 별도 번들을 지정할 수 있다. 이미지의 최상위에는 앱과 `/Applications` 바로가기만 들어간다. 앱 내부에는 Whisper 전사 실행 파일·필요한 라이브러리와 모델이 들어간다. Alt의 노트, 녹음, 개인 DB는 포함하지 않는다.

현재 소스에서 새로 빌드할 때는 먼저 `./script/fetch_local_model.sh`로 고정된 공개 출처의 모델을 Ravil 캐시에 받아 SHA-256을 확인한다. 기본 빌드에는 이 파일과 Homebrew `whisper-cli`가 필요하다. Alt 설치 폴더는 모델 빌드 입력이 아니다. 앱에는 모델 카드와 라이선스가 함께 포함된다. 설치 후 전사는 기본적으로 앱에 포함된 파일을 선택하며, 번들된 실행 파일의 동적 링크에는 Homebrew 절대 경로가 없다. Alt나 Homebrew가 없는 별도 Mac에서의 설치·전사는 아직 검증하지 않았다. 필요하면 **설정 → 로컬 전사**에서 다른 모델·실행 파일 경로를 선택할 수 있다. 모델 또는 실행 파일이 고장 나도 녹음 파일은 앱 데이터 폴더에 보존된다. 별도 요약 LLM은 포함하지 않는다.

앱 데이터는 `~/Library/Application Support/Ravil`에 저장된다. 첫 실행 때 기존 `~/Ravil/data/lecture-os.db`가 있으면 새 앱 전용 DB로 복사한다. 현재 DMG는 Mac 앱만 담고 있으며 iPhone·iPad·Apple Watch 동기화 기능은 아직 구현되지 않았다.

```bash
./script/fetch_local_model.sh
./script/build_and_run.sh --build
./script/package_dmg.sh
```

Alt와 Homebrew 실행 파일에 빌드가 의존하지 않는 **실험용** 경로도 있다. `./script/fetch_local_vad.sh`로 Silero VAD를 별도 출처에서 받은 뒤 `script/build_whisper_runtime.sh`로 고정된 공개 `whisper.cpp` 소스를 빌드한다. 생성된 패키지 경로를 `RAVIL_WHISPER_RUNTIME_DIR`에 지정해 `script/build_and_run.sh --build`를 실행하면 출처·MIT 고지와 함께 앱에 넣는다. 격리 앱의 헤드리스 전사와 VAD 검사는 통과했지만 기존 설치 앱이나 DMG는 교체하지 않았고 실제 녹음 UI 경로도 미검증이다. VAD는 현재 기본 전사에서 사용하지 않는다. 자세한 결과는 [최적화 기록](ravil-asmr-optimization.md)에 있다.

같은 버전의 DMG가 이미 있으면 스크립트는 중단한다. 새 앱을 빌드한 뒤 이미지를 교체하려면 `./script/package_dmg.sh --replace`를 실행한다. 포장 과정에서 앱 서명과 DMG 무결성을 검사하고 SHA-256을 출력한다.

2026-09-25에 생성한 **0.5.0** 개인 개발용 DMG는 544,927,906바이트이며 SHA-256은
`7d98be15abb37b6cfb22fde65a84bc7c0eaf437ca52ec51edac259db0cbb2266`이다.
모델 복사본의 SHA-256은 Alt 원본과 같은
`394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2`이다.
빌드, ad-hoc 앱 서명, 포장 스크립트의 DMG 무결성 검사, 내부 실행 파일 smoke test,
Goodnotes 판본·그림 비교·이름 변경·ID 교체·충돌·롤백·OCR 검사가 통과했다. 읽기 전용·비표시
마운트한 DMG의 앱 서명, Alt 모델·엔진 번들 선택과 Goodnotes 검사도 확인했다. 실행 중인 기존
`dist/Ravil.app`을 건드리지 않도록 `dist/Ravil-0.5.0.app`에서 포장했다. 실제 Ravil DB에는
중간고사 최신 **25문서/1,254쪽**, 총 27개 판본과 OCR 148쪽이 기록되고 새 PDF 해시가
대조됐다. **0.5.0 DMG 설치와 새 자료 화면·판본 전환·OCR 표시의 실제 사용자 경로는 화면
도구 오류로 미검증**이다. Google Drive 앱 내 로그인·자동 감시는 포함되지 않았다. 녹음 파일
가져오기·전사 옵션·마이크도 이 버전에서 별도 확인하지 않았다.

이 DMG는 Apple Silicon Mac용 개인 개발 배포물이다. 현재 앱은 ad-hoc 서명이며 Apple Developer ID 서명이나 공증을 받지 않았다. 따라서 macOS Gatekeeper 승인을 받은 공개 배포물로 취급하면 안 된다. 특히 복사된 모델 가중치의 공개 재배포 조건은 검토하지 않았다. 공개 배포 전에는 라이선스와 모델 배포 조건을 확인하고, Developer ID로 서명·공증한 뒤 다른 Mac에서 설치·실행을 확인해야 한다.

수동 검사에는 다음 명령을 사용할 수 있다.

```bash
hdiutil verify dist/Ravil-0.5.0-arm64.dmg
codesign --verify --deep --strict dist/Ravil-0.5.0.app
spctl --assess --type execute --verbose=4 dist/Ravil-0.5.0.app
```
