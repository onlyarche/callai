# callai

> 로컬 **Ollama** 서버에 텍스트·스크린샷·음성을 자유롭게 조합해 보내는 macOS **메뉴바 앱**.

- **상태:** v1
- **출력:** 텍스트 전용 (TTS·이미지 출력은 post-v1)
- **목표:** 개인용으로 먼저 쓰고, 검증되면 **Mac App Store** 배포 — 처음부터 샌드박스 호환 API만 사용

---

## 무엇을 하는 앱인가

메뉴바 아이콘 또는 사용자가 직접 지정한 전역 단축키로 띄우는 작은 입력창에 **세 채널의 입력**을 자유롭게 조합해 Ollama 로컬 모델에 보낸다.

- **S — 화면 영역 스크린샷** (드래그로 선택)
- **T — 텍스트**
- **V — 음성** (on-device STT로 변환되어 텍스트와 합쳐 전송)

세 채널의 부분집합(공집합 제외) = 7가지 입력 조합을 단일 **PromptComposer** 하나로 전부 처리한다.

| # | 조합 | 시나리오 |
|---|---|---|
| 2-1 | S | 스크린샷만 (vision 모델 + 기본 프롬프트) |
| 2-2 | S + T | 스크린샷 + 텍스트 |
| 2-3 | S + V | 스크린샷 + 음성 |
| 2-4 | S + T + V | 셋 다 |
| 2-5 | T + V | 텍스트 + 음성 |
| 2-6 | T | 텍스트만 |
| 2-7 | V | 음성만 |

응답은 NDJSON 스트리밍으로 받아 같은 창에 마크다운으로 점진 렌더되고, 그대로 **멀티턴 후속 질문**으로 이어진다. 대화는 SwiftData에 영속되어 **MainWindow**의 히스토리 사이드바에서 다시 열 수 있다.

---

## 주요 기능

- **메뉴바 전용 앱** — `MenuBarExtra` + `LSUIElement=YES`. Dock 아이콘 없음
- **두 창 구조**
  - **SessionWindow** — 단축키로 뜨는 개별 창. 한 대화(Conversation) 1개 호스팅. 여러 개 동시에 띄울 수 있음
  - **MainWindow** — 히스토리 사이드바 + 대화 상세 + 새 대화 작성
- **단일 Composer** — S/T/V를 옵션으로 받아 7가지 조합을 한 코드 경로로 처리. 첫 입력과 후속 입력이 동일 컴포넌트
- **영역 스크린샷** — 전체화면 드래그 오버레이 → `ScreenCaptureKit`의 `SCScreenshotManager`로 `CGRect` → `CGImage` → 모델로 전송
- **음성 입력** — `AVAudioEngine` 녹음 + `Speech.framework` on-device STT. 기본 **push-to-talk**, 설정에서 toggle 전환
- **멀티턴** — 같은 창에서 후속 질문 시 `Conversation.messages` 전체 + 새 user message를 그대로 다시 전송
- **NDJSON 스트리밍** — `URLSession.bytes` 기반 파서. ESC로 즉시 취소(`URLSessionDataTask.cancel()`)
- **Capability 자동 감지** — `/api/show`의 `capabilities` 배열로 vision/audio/tools 지원 여부 자동 판별. vision 미지원 모델에 이미지를 첨부하면 전송 차단 + 경고
- **비차단형 온보딩** — 권한 0개여도 텍스트 플로우(시나리오 2-6)는 그대로 동작. 미완료 시 메뉴 상단에 `⚠ 설정 완료하기`만 노출, JIT 권한 요청
- **전역 단축키** — sindresorhus/`KeyboardShortcuts` (Carbon 래퍼, 샌드박스/App Store 호환, Accessibility 권한 불필요). **기본값은 미할당** — 첫 실행 OnboardingView에서 사용자가 직접 잡는다

---

## 요구사항

| | |
|---|---|
| macOS | **14.0+** (`MACOSX_DEPLOYMENT_TARGET = 14.0`) |
| Xcode | 16+ (file-system-synchronized groups 사용) |
| Swift | 5.0 |
| 런타임 의존성 | 로컬 [Ollama](https://ollama.com) 서버 (기본 `http://localhost:11434`) |
| 기본 모델 | `gemma4:latest` — 멀티모달 단일 모델이 텍스트·이미지를 모두 처리 |

> ⚠ Ollama 0.20.0+ 필요 (gemma4 동작). 기본 모델은 미리 받아두면 된다:
>
> ```bash
> ollama pull gemma4:latest
> ```

---

## 설치 (Release 사용자)

직접 빌드할 필요 없는 사용자는 [Releases](https://github.com/onlyarche/callai/releases) 페이지에서 최신 `callai.app.zip`을 받아서 쓰면 된다.

```bash
# 1) zip 다운로드 후 압축 해제
unzip ~/Downloads/callai.app.zip -d ~/Downloads/

# 2) /Applications/로 이동 (TCC 권한이 PID 기준이라 위치 고정이 중요)
mv ~/Downloads/callai.app /Applications/

# 3) Gatekeeper quarantine 속성 제거 — Developer ID 서명 없이 배포된
#    빌드이므로 macOS가 "확인되지 않은 개발자" 경고를 띄움. 이를
#    한 번에 우회. (또는 Finder에서 첫 실행 시 우클릭 → 열기 → 확인)
xattr -dr com.apple.quarantine /Applications/callai.app

# 4) 실행
open /Applications/callai.app
```

> ⚠ ad-hoc codesign된 개인 배포라 Gatekeeper/Notarization을 통과하지 않는다. 위 `xattr` 명령이 자기 책임 동의에 해당한다. 본격 배포를 원한다면 Apple Developer 계정($99/yr) → Developer ID 서명 + 노타라이즈 단계가 필요.

런타임 의존성으로 [Ollama](https://ollama.com)가 로컬에서 떠 있어야 한다 — `ollama serve`로 데몬을 띄우고 `ollama pull gemma4:latest`로 기본 모델을 받아두면 됨.

---

## 소스에서 빌드

### 의존성 설치

```bash
# 1) Xcode 16+ 설치 (App Store 또는 https://developer.apple.com/xcode)

# 2) xcode-select가 Xcode.app을 가리키는지 확인
xcode-select -p
# → /Applications/Xcode.app/Contents/Developer 이어야 함
# CommandLineTools를 가리키면 sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

# 3) 저장소 클론
git clone https://github.com/onlyarche/callai.git
cd callai
```

### Xcode에서 Run

```bash
open callai.xcodeproj
```

Xcode에서 `callai` scheme이 선택된 것을 확인하고 ▶ Run (⌘R). 처음 빌드 시 Swift Package Manager가 `KeyboardShortcuts` 의존성을 자동으로 받는다 (몇 초 소요).

### 커맨드라인 빌드 (CI/스크립트용)

```bash
# Debug 빌드
xcodebuild -project callai.xcodeproj -scheme callai \
    -configuration Debug -destination 'platform=macOS' build

# Release 빌드 (배포용)
xcodebuild -project callai.xcodeproj -scheme callai \
    -configuration Release -destination 'platform=macOS' \
    -derivedDataPath ./build build

# Release 산출물 경로
ls ./build/Build/Products/Release/callai.app
```

### Release 배포 패키징

GitHub Release에 올릴 zip을 만드는 절차:

```bash
# 1) Release 빌드
xcodebuild -project callai.xcodeproj -scheme callai \
    -configuration Release -destination 'platform=macOS' \
    -derivedDataPath ./build build

# 2) .app을 zip으로 묶기 (ditto로 macOS extended attrs 보존)
cd ./build/Build/Products/Release
ditto -c -k --keepParent callai.app ../../../../callai.app.zip
cd -

# 3) GitHub Release 생성 + zip 업로드 (gh CLI 필요)
gh release create v1.0.0 \
    --title "v1.0.0 — 첫 공개 릴리스" \
    --notes "PLAN §9 M1~M8 전부 완성. 트러블슈팅과 사용법은 README 참고." \
    callai.app.zip
```

(gh CLI가 없으면 `brew install gh` 후 `gh auth login`. 또는 GitHub 웹 UI에서 Release 페이지 → "Draft a new release" → tag `v1.0.0` 생성 후 zip 직접 업로드.)

### 두 가지 entitlements

| | 개인 빌드 | App Store 빌드 |
|---|---|---|
| 파일 | `callai/callai.entitlements` | `callai/callai-AppStore.entitlements` |
| App Sandbox | OFF | **ON** (`com.apple.security.app-sandbox`) |
| Hardened Runtime | ON (notarize 위해) | ON |
| 마이크 | `com.apple.security.device.audio-input` | 동일 |
| 네트워크 | `com.apple.security.network.client` (localhost Ollama 호출) | 동일 |

코드는 처음부터 샌드박스에서 동작하는 API만 사용한다 — App Store 전환 시 entitlement 토글만으로 끝나도록 설계.

---

## 권한 (TCC)

OnboardingView가 세 가지 권한과 단축키 2개를 한 화면에서 처리한다. 첫 실행 시 비차단으로 표시되며, "나중에 하기"로 건너뛰어도 앱은 그대로 동작한다.

| 권한 | 용도 | Info.plist 키 |
|---|---|---|
| Screen Recording | `ScreenCaptureKit` 영역 캡쳐 | (TCC 시스템 설정 안내) |
| Microphone | 음성 녹음 | `NSMicrophoneUsageDescription` |
| Speech Recognition | `SFSpeechRecognizer` on-device STT | `NSSpeechRecognitionUsageDescription` |

권한이 없는 상태에서 해당 기능을 시도하면 인라인 배너 / 버튼 disabled + 툴팁 / 시스템 설정 안내로 graceful degrade — 크래시·무음 실패 없음.

---

## 설정 (`Settings`)

- Ollama base URL (기본 `http://localhost:11434`)
- 기본 모델 — `/api/tags`로 채움, 요청별 드롭다운으로 변경 가능. `/api/show`로 capability 자동 감지
- 시스템 프롬프트 / vision 프롬프트 템플릿 (편집 가능)
- 단축키 2개 (Composer / 영역+Composer) 재할당
- 음성 입력 모드 — push-to-talk(기본) ↔ toggle
- STT 언어 — 기본 시스템 로케일
- 응답 자동 복사, 창 항상 최상위 토글

---

## 프로젝트 구조

디렉터리가 곧 모듈 경계다. 새 파일은 Xcode 16의 file-system-synchronized groups 덕에 `project.pbxproj`를 건드리지 않고 자동 합류한다.

```
callai/
├── App/                  # @main, MenuBarExtra + Scene 구성, AppCoordinator
├── MenuBar/              # 메뉴 드롭다운 콘텐츠
├── Permissions/          # PermissionsManager, OnboardingView
├── Hotkeys/              # KeyboardShortcuts.Name × 2 (기본 미할당)
├── Capture/              # RegionSelectorOverlay, ScreenCaptureService (ScreenCaptureKit 래퍼)
├── Audio/                # MicrophoneRecorder, SpeechRecognitionService (SFSpeechRecognizer)
├── Composer/             # PromptComposerView + ComposerViewModel — S/T/V 입력 UI (첫/후속 공용)
├── Conversation/         # @Model 멀티턴 + SwiftData 스토어 + ConversationView
├── Windows/              # SessionWindow (단축키 개별 창) + MainWindow (히스토리)
├── LLM/                  # LLMClient protocol + OllamaClient(NDJSON) + ChatRequest/ResponseChunk
├── Settings/             # SettingsView, SettingsStore(@AppStorage)
└── Shared/               # PromptTemplate, OnboardingStatus
```

---

## Ollama 연동

- 엔드포인트
  - `GET /api/tags` — 설치된 모델 목록 (설정/모델 드롭다운)
  - `POST /api/chat` — `{ model, messages, stream:true }` NDJSON 스트림
  - `POST /api/show` — 모델 capability 메타데이터
- vision 모델은 `messages[].images: [base64 PNG]`
- 스트리밍 파싱 — `URLSession.shared.bytes(for:).lines` → `JSONDecoder` → `ResponseChunk.text`
- 취소 — 창 ESC → `AsyncStream` `onTermination` → `URLSessionDataTask.cancel()`
- 200-with-error pitfall — Ollama가 200 상태로 `{ "error": "..." }` 라인을 보내는 케이스를 별도 처리

응답 추상화: `enum ResponseChunk { case text(String); case image(Data); case audio(Data) }`. v1은 `.text`만 사용하되 enum은 미리 정의해 post-v1(TTS·이미지 출력) 확장 시 UI 분기만 추가하면 된다.

---

## 의존성

| 패키지 | 용도 |
|---|---|
| [`sindresorhus/KeyboardShortcuts`](https://github.com/sindresorhus/KeyboardShortcuts) | 전역 단축키 (Carbon 래퍼, 샌드박스·App Store 호환) |

그 외는 Apple 1st-party 프레임워크 (`SwiftUI`, `SwiftData`, `ScreenCaptureKit`, `AVFoundation`, `Speech`).

---

## 트러블슈팅

### 1. Xcode에서 빌드/실행이 안 됨

**증상**: Xcode의 Run/Test/Profile 버튼이 회색이거나, `xcodebuild`만 통과하고 IDE에서는 실패한다.

1. `xcode-select` 경로 확인
   ```bash
   xcode-select -p
   # /Library/Developer/CommandLineTools 가 나오면 잘못된 경로
   ```
   CommandLineTools를 가리키고 있다면 Xcode.app으로 변경:
   ```bash
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   xcode-select -p
   # /Applications/Xcode.app/Contents/Developer 로 바뀌어야 정상
   ```

2. DerivedData 정리
   ```bash
   rm -rf ~/Library/Developer/Xcode/DerivedData/callai-*
   ```

3. **scheme 손상** — macOS 26 / Xcode 26.5 환경에서 xcodebuild가 `callai.xcscheme`의 `BuildableProductRunnable` → `MacroExpansion`을 자동 마이그레이션하고 `BuildableName "callai.app"`을 `"callai"`로 떼버리는 케이스가 관측됨. Run이 회색이 된 직접 원인. 복구:
   ```bash
   git checkout HEAD -- callai.xcodeproj/xcshareddata/xcschemes/callai.xcscheme
   ```
   xcodebuild를 매번 돌릴 때마다 재발할 수 있으므로 IDE에서 Run이 회색이 되면 먼저 이걸 의심.

---

### 2. 빌드할 때마다 TCC 권한 다이얼로그가 다시 뜸

**원인**: Debug 빌드는 ad-hoc codesign이어서 빌드마다 cdhash가 바뀐다. macOS TCC는 PID + cdhash로 권한을 캐싱하기 때문에 cdhash가 바뀌면 같은 번들이라도 새 앱으로 인식해 재요청.

해결책 (효과 순):

1. **`/Applications/`에 설치해서 쓰기 (권장)**
   `~/Library/Developer/Xcode/DerivedData/...`의 빌드 산출물을 `/Applications/`로 복사한 뒤 그 인스턴스를 실행. 위치가 고정되면 macOS가 같은 앱으로 일관되게 인식.
   ```bash
   cp -R "~/Library/Developer/Xcode/DerivedData/callai-*/Build/Products/Debug/callai.app" /Applications/
   ```

2. **개발 인증서로 sign**
   Apple Developer ID 인증서가 있다면 scheme의 Signing & Capabilities에서 ad-hoc 대신 cert sign으로 전환. cdhash가 빌드 간에 안정적.

3. **TCC 리셋 후 재허용** (응급)
   ```bash
   tccutil reset Microphone com.onlyarche.callai
   tccutil reset SpeechRecognition com.onlyarche.callai
   tccutil reset ScreenCapture com.onlyarche.callai
   ```

---

### 3. 화면 녹화 권한을 허용했는데도 안 됨

macOS 화면 녹화 권한은 **PID로 캐싱**되므로 토글 ON 후 **앱 재시작 필수**. 온보딩 화면 "재시작" 버튼 또는 메뉴바 → 종료 후 재실행.

토글이 ON인데도 안 되면:
1. System Settings → Privacy & Security → Screen Recording에서 callai 토글을 OFF → ON
2. 앱 완전 종료 후 재실행

---

### 4. 음성 인식이 한국어를 못 알아듣거나 영어로 변환됨

**원인**: STT 언어 설정이 시스템 region을 따라가서 `en_US`로 잡혀 있는 경우. v1부터 기본값을 `ko-KR`로 변경했지만, 이전 버전에서 다른 값으로 저장한 적이 있으면 그대로 남아 있다.

- Settings → 음성 → STT 언어 → **"기본 (ko-KR)"** 또는 **"ko-KR"** 선택
- 한국어 외 다른 언어로 인식하고 싶을 때만 직접 변경

---

### 5. 음성 인식이 아예 안 됨 — "Siri and Dictation are disabled"

**원인**: `SFSpeechRecognizer`는 macOS 시스템 받아쓰기(Dictation) 인프라를 공유한다. Dictation이 꺼져 있으면 권한이 있어도 동작하지 않음. Siri를 켤 필요는 없다 — Dictation만 켜면 충분.

해결책:
1. 🎙 버튼 누른 뒤 뜨는 에러 배너의 **"받아쓰기 설정 열기"** 버튼 클릭
   (또는 System Settings → Keyboard → Dictation 수동 진입)
2. **받아쓰기 토글 ON**
3. 언어에 **한국어 추가** (없으면 한국어 인식이 막힘)
4. macOS가 음성 모델 다운로드 안내를 띄우면 확인 — 다운로드 완료까지 대기 (수 분 소요 가능)
5. callai로 돌아와서 다시 🎙 시도

---

### 6. 메뉴바 아이콘이 안 보임

`LSUIElement=YES` 앱이라 Dock 아이콘이 없고 메뉴바 우측 영역에 말풍선(💬) 아이콘만 떠야 한다.

- 메뉴바가 가득 차서 시스템이 숨긴 경우 — 보이지 않는 부분을 ⌘+드래그로 정리
- 모니터 노치 영역 너머로 밀린 경우 — 다른 메뉴바 앱(예: Bartender, Hidden Bar)으로 재정렬
- 앱이 실제로 실행 중인지 확인:
  ```bash
  pgrep -l callai
  ```

---

### 7. 멀티 모니터에서 영역 선택 오버레이가 한 화면에만 뜸

v1(`9beb836` 이후)에서 해결됨 — 3개 모니터 전부 dim 처리되어야 정상. 여전히 한 화면에만 뜬다면 이전 빌드를 실행 중일 가능성:
```bash
pgrep -l callai  # 실행 중인 PID 확인
ls -lT ~/Library/Developer/Xcode/DerivedData/callai-*/Build/Products/Debug/callai.app/Contents/MacOS/callai
# 빌드 타임스탬프가 9beb836 커밋 이후인지 확인
```

---

## 라이선스

미정 (개인 빌드 단계).
