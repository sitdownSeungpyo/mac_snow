# WinterDesk for Windows

macOS 앱 WinterDesk를 Windows용 네이티브 C++ 앱으로 옮긴 버전입니다.
노트북 **내장 디스플레이에만** 눈을 내리고, 그래픽은 모두 코드로 그려서 GPU로 렌더링합니다
(Direct3D 11 + DXGI flip-model 컴포지션 스왑체인 + DirectComposition + Direct2D/DirectWrite).
외부 라이브러리나 이미지 에셋은 쓰지 않습니다.

## 빌드 / 실행

```powershell
powershell -ExecutionPolicy Bypass -File windows\build.ps1   # -> windows\build\WinterDesk.exe
windows\build\WinterDesk.exe
```

- 필요: Visual Studio Build Tools (C++ x64 도구, Windows 10/11 SDK). `build.ps1`은 `vswhere`로 MSVC를 찾아
  `vcvars64` 환경을 가져온 뒤 `cl.exe`로 빌드합니다 (`/O2 /std:c++17 /W4 /MT`, 정적 CRT라 exe 하나로 실행됨).
- 실행하면 알림 영역(트레이)에 눈송이 아이콘이 생깁니다. 클릭하면 메뉴가 열립니다.
- 옵션
  - `--safe` : 안전 모드 — 이번 실행 동안만 Desktop 모드 + 창 위 눈/전구 끔 (저장된 설정 값은 그대로). 실행할 때 Shift를 누르고 있어도 같습니다.
    직전 실행이 10초 동안 정상 동작하기 전에 끝났거나(강제 종료·멈춤·재부팅) 워치독이 종료시켰다면 자동으로 안전 모드가 되고
    트레이 메뉴 맨 위에 ⚠️ 안내가 나옵니다. Mode를 직접 고르면 안전 모드가 끝납니다.
  - `--test-seconds N` : N초 뒤 자동 종료 (UI 스레드가 멈춰도 워치독이 종료).
  - `--log` : `%TEMP%\WinterDesk.log` 에 로그 (디스플레이, D3D 장치, 10초마다 fps/CPU 통계).
  - `--test` : 자동화용 메시지 허용 (아래). `--test-seconds`도 이를 켭니다.
  - `--selftest` : `WINTERDESK_DATA_DIR` 환경 변수로 지정한 임시 폴더에 NaN/깨진 gifts·riders·links 파일을 써서 읽기 검사를 하고
    (`SELFTEST ok/FAIL` 로그) 그 파일로 앱을 실행합니다. 이 변수가 없으면 실제 파일을 건드리지 않도록 실행을 거부합니다.
  - `--diag` : `%LOCALAPPDATA%\WinterDesk\Logs\diag-<시각>.csv` 에 창 눈 이벤트 CSV (grab / slideOff / regrow / liveFrame / fling …, 1초마다 기록).
- 저장 위치 `%APPDATA%\WinterDesk\`: `settings.ini`, `gifts.txt`(선물), `riders.txt`(창 위 눈사람과 옷차림),
  `links.txt`(전구 연결, exe 이름 + 그 앱의 창 순번), `sentinel.txt`(안전 모드 판단용).

## 단축키 (어디서나)

| 키 | 동작 |
|---|---|
| Ctrl+Alt+Shift+Q | 비상 종료 |
| Ctrl+Alt+Shift+E | 효과 전체 켜기/끄기 |
| Ctrl+Alt+Shift+S | 눈 내리기 켜기/끄기 |
| Ctrl+Alt+Shift+D | 산타 켜기/끄기 |
| Ctrl+Alt+Shift+P | 제설차 켜기/끄기 |
| Ctrl+Alt+Shift+L | 전구 연결하기 (편집 중 Esc로 종료, 30초 조작 없으면 자동 종료) |
| Ctrl+Alt+Shift+G | Report a Glitch (최근 이벤트를 `%LOCALAPPDATA%\WinterDesk\Logs\glitch-*.csv`로 저장) |

다른 앱이 이미 쓰고 있는 키는 조용히 건너뜁니다. AltGr 키보드 배열(독일어 등)에서는 Ctrl+Alt가 AltGr과 같아서
Ctrl+Alt+Shift 조합이 그 배열의 문자 입력과 겹칠 수 있습니다 (한국어 배열은 문제없음).
전구 편집 중 Esc는 가로채지 않고 읽기만 하므로 다른 앱도 Esc를 그대로 받습니다.

## 기능 (mac과 같은 동작)

- **내리는 눈** (Light / Normal / Heavy), 작업 표시줄 윗변의 눈 (자동 숨김/없으면 화면 아래), 아주 천천히 쌓임.
- **창 위 눈** (mac WindowCap 그대로): 2pt 칸의 모래 같은 눈 띠, 안식각 1.1pt, 양 끝은 작은 둥근 처마, 4~5pt까지 아주 천천히 자람.
  - **실시간 창 추적** (기본): `EVENT_OBJECT_LOCATIONCHANGE`로 창을 끄는 동안 눈·전구·창 위 눈사람이 창과 같이 움직입니다.
    끄는 방향 반대쪽으로 눈이 쏠려 끝에서 모래처럼 흘러내리고, 빠르게 던지듯 움직이면 작은 눈덩이(3–8pt)와 눈가루가 날아가
    바닥 눈에 쌓입니다. 눈사람은 흔들리기만 하고 아주 세게 흔들 때만 떨어집니다.
  - **기본 모드** (메뉴에서 실시간 추적을 끄면): 창이 움직이면 눈이 미끄러져 떨어지고, 0.4초 멈추면 다시 쌓입니다.
  - 앞뒤 순서나 높이만 바뀌면 아무 일도 없고, 닫기/최소화/숨기기는 즉시 사라집니다 (창 위 눈사람은 창이 돌아오면 복원).
  - "창 끌 때 눈": 미끄러져 떨어짐 / 붙어 있음.
- **눈사람**: 바닥 눈을 눌러 굴리면 커지고(최대 80pt), 작은 눈덩이를 위에 놓으면 최대 3단까지 쌓입니다. 창 윗변에 올리면 창을 따라다니고
  앞 창에 가려지면 숨습니다. 첫 실행(저장된 창 눈사람이 없을 때)에는 맨 앞 큰 창 윗변에 산타 모자 눈사람이 하나 섭니다.
- **꾸미기 패널** "Fashion week, but colder.": 2단 이상 눈사람을 클릭하면 열립니다. Hat / Face / Body / Clothes 탭, 고르면 바로 적용,
  눈사람마다 저장(창 위 눈사람은 다음 실행에도 복원), ↺ 초기화, ✕ 또는 Esc로 닫기. 패널은 클릭하기 전까지 포커스를 가져가지 않습니다.
- **삭제**: 눈덩이 위에 0.3초 올리면 ✕, 오른쪽 클릭 → "삭제". 선물은 마우스를 올리면 바로 ✕, 더블클릭하면 열림.
- **산타**: 가끔 날아가고, 절반쯤은 작업 표시줄 눈 위에 내려앉아 미끄러지다 다시 날아오릅니다. 클릭하면 "Ho Ho Ho!" 말풍선과 선물,
  드래그해서 옮기면 다시 날아갑니다. **자동 선물 확률**: 한 번 지나갈 때 6.7% (`kSantaGiftDropChance = 0.2 / 3`,
  사용자 요청으로 mac의 20%의 1/3). 선물은 최대 30개, 최대 3단까지 쌓이고 저장됩니다.
- **제설차**, **전구**: 창 가랜드(창마다 늘어진 줄 2~3개, 전구 간격 약 40pt — mac은 30pt), 가까운 창 사이 자동 전구 줄,
  직접 연결(금색 점 → 금색 점 드래그, 자석처럼 붙음, 안 되는 점은 빨간색, 줄 클릭 = 삭제, 최대 20줄, 안내 패널 + "알겠어요"),
  Light Links (Automatic / Manual only — 첫 연결을 만들면 한 번 Manual only로), Window Garlands, Light Style (Multicolor / Warm White).
- **Mode**: On Top (모든 창 위, 클릭 통과) / Desktop (앱 창 뒤, 바탕화면 아이콘 위 — 오버레이를 데스크톱 아이콘 창(Progman) 바로 위에 유지).
  창 위 눈/전구는 On Top에서만 동작합니다.
- 트레이 메뉴: mac 메뉴와 같은 항목 (Clear Snowballs & Snowmen, Clear Snowmen, Snowballs & Gifts, Report a Glitch, 절전 표시, Launch at Login 등).
  토스트 안내(화면 위 가운데, 클릭 통과)는 효과가 꺼져 있을 때도 보입니다.

## 작업 방해 없음

- 오버레이는 클릭 통과이고 포커스를 가져가지 않으며 작업 표시줄/Alt+Tab에 나타나지 않습니다. 커서가 눈사람·선물·산타·제설차·
  전구 편집 점/줄(또는 바닥 눈 띠 중 다른 창이 없는 부분) 위에 있을 때만 마우스를 받습니다.
- 전체 화면 앱/게임/프레젠테이션이 내장 디스플레이에 있으면(앞에 있는 창이 화면 전체를 덮으면, 포커스가 없어도) 또는 화면이 잠기면
  숨기고 렌더링을 멈춥니다.
- 내장 디스플레이가 없으면(덮개 닫음/외부 모니터만/데스크톱 PC) 다른 모니터에 그리지 않고 일시 정지하며, 트레이 메뉴에
  "내장 디스플레이 없음 – 일시 정지"가 보입니다. 내장 화면이 다시 켜지면 자동으로 이어집니다.
- 누르고 있던 물체는 마우스 버튼이 실제로 눌려 있는 동안만 잡혀 있습니다 (캡처를 잃으면 바로 놓고 클릭 통과로 돌아감).
- 평소 30fps 근처(144Hz 패널에서는 36fps), 드래그 중에만 더 빠르게, 움직이는 것이 없으면 그리지 않습니다.

## mac과 다른 점

- Dock 대신 작업 표시줄 윗변, Accessibility 메뉴 없음(필요 없음), 메뉴바 아이콘 대신 트레이 아이콘.
- 전구 반짝임은 3단계로 초당 약 5번 바뀝니다(mac은 20Hz 연속) — CPU 절약.
- 바닥 눈 띠는 다른 창 위에서는 마우스를 받지 않습니다 (최대화된 창의 아래쪽 클릭을 막지 않기 위해).

## 테스트용 메시지 (자동화)

`--test`(또는 `--test-seconds`, `--selftest`)로 실행했을 때만 처리됩니다. 컨트롤 창(클래스 `WinterDeskControl`)에
`RegisterWindowMessage`로 등록한 이름의 메시지를 보냅니다: `WinterDesk.Test.State`(상태 로그), `WinterDesk.Test.Santa`(산타 바로 출발),
`WinterDesk.Test.Ball`(눈덩이 생성: wParam x, lParam 반지름 pt), `WinterDesk.Test.LightEdit`, `WinterDesk.Test.Command`(wParam = 메뉴 명령 id),
`WinterDesk.Test.HitTest`(wParam x, lParam y). 결과는 `--log` 로그에 `TEST`/`STATE` 줄로 남고, 플래그 없이 받으면 무시하고 그 사실만 기록합니다.
