# HUEN Remote — 클라이언트 빌드 가이드 (Windows / Android)

이 문서는 **커스텀 RustDesk 클라이언트**를 Windows와 Android로 빌드하는 방법을 **처음 하는 사람도 따라 할 수 있게** 정리한 것입니다.

> 서버(hbbs/hbbr) 빌드·배포는 별도 저장소(`rustdesk-server` fork)에서 합니다. 이 문서는 **클라이언트(원격제어 앱)** 전용입니다.

---

## 0. 먼저 이해하기 — 이 빌드가 stock RustDesk와 다른 점

빌드 **시점**에 환경변수로 서버/키/모드를 "구워 넣습니다"(baked). 그래서 사용자가 서버·키를 직접 입력할 필요가 없습니다.

| 변형 | 누구용 | baked 설정 | 로그인 게이트 |
|---|---|---|---|
| **customer (고객)** | 지원받는 고객 PC/폰 | 서버 + **공개키** | 없음 (실행하면 바로 ID 표시) |
| **staff (상담원)** | 내부 직원 | 서버 (키는 **런타임에 M365 로그인 후** 받음) | **M365(Entra ID) 로그인 필수** |

핵심 환경변수 (자세한 표는 [부록 A](#부록-a--huen-환경변수)):
- `RUSTDESK_SERVER` — 서버 도메인 (**둘 다 필수**)
- `RUSTDESK_KEY` — 서버 공개키 (**고객 빌드만**)
- `RUSTDESK_TECHNICIAN=1` — 상담원 모드 켜기 (**상담원 빌드만**)
- `RUSTDESK_AAD_*` — M365 로그인 설정 (**상담원 빌드만**)

---

## 1. 사전 준비물 (Windows·Android 공통, 한 번만)

| 도구 | 버전 | 비고 / 설치 위치 |
|---|---|---|
| Windows | 11 | |
| Rust | 최신 stable | `rustup` 설치 → `~/.cargo/bin` |
| Visual Studio | **2026 (v18)** | "C++를 사용한 데스크톱 개발" 워크로드 |
| LLVM/Clang | 최신 | `C:\Program Files\LLVM` (`LIBCLANG_PATH`) |
| Python | 3.12 | **`python`** 명령 사용 (Windows에서 `python3`는 스토어 스텁이라 실패) |
| Git | 최신 | |
| Flutter | **3.24.5 (고정)** | `C:\flutter` |
| flutter_rust_bridge_codegen | **1.80.1** | `cargo install flutter_rust_bridge_codegen --version 1.80.1 --features uuid --locked` |
| vcpkg | 최신 | `C:\vcpkg` (`VCPKG_ROOT`) |

> Android는 추가 준비물이 더 있습니다 → [4-0. Android 일회성 셋업](#4-0-android-일회성-셋업) 참고.

### 1-1. 환경 활성화 (매 새 PowerShell 창마다)

저장소에 `activate.ps1`이 포함돼 있습니다. 빌드 전 **저장소 폴더에서** 한 줄 실행(경로는 본인 설치에 맞게 조정):
```powershell
. .\activate.ps1
```
`activate.ps1` 내용(이게 하는 일):
```powershell
$env:VCPKG_ROOT    = 'C:\vcpkg'
$env:LIBCLANG_PATH = 'C:\Program Files\LLVM\bin'
$env:Path = "C:\flutter\bin;$env:USERPROFILE\.cargo\bin;C:\vcpkg;" + $env:Path
```
> Android도 빌드한다면 `$env:ANDROID_NDK_HOME = 'C:\Android\Sdk\ndk\28.2.13676358'` 줄을 추가하면 편합니다(activate.ps1 안에 주석으로 들어있음).

---

## 2. 공통 일회성 셋업 (한 번만)

### 2-1. 네이티브 코덱 의존성 (vcpkg)

Windows용(호스트):
```powershell
vcpkg install libvpx:x64-windows-static libyuv:x64-windows-static opus:x64-windows-static aom:x64-windows-static
```

### 2-2. FFI 브리지 생성 — `flutter_ffi.rs`를 수정했을 때만

`src/flutter_ffi.rs`를 바꾸면 Rust↔Dart 브리지를 다시 생성해야 합니다:
```powershell
flutter_rust_bridge_codegen --rust-input ./src/flutter_ffi.rs --dart-output ./flutter/lib/generated_bridge.dart
```
> `generated_bridge.dart`와 `src/bridge_generated.rs`는 **생성물**입니다. flutter_ffi.rs를 안 건드렸으면 이 단계는 건너뜁니다.

### 2-3. Visual Studio 2026 인식 패치 (Windows 빌드 시 1회)

Flutter 3.24.5는 VS2026을 모릅니다. CMake 생성기 에러("could not find VS2019")가 나면:
- `C:\flutter\packages\flutter_tools\lib\src\windows\visual_studio.dart`의 `cmakeGenerator`에 `18 => 'Visual Studio 18 2026'` 매핑 추가
- `C:\flutter\bin\cache\flutter_tools.{stamp,snapshot}` 삭제 (flutter 도구 재컴파일 유도)
- `flutter\build\windows` 폴더 삭제 (오래된 캐시 제거)

> ⚠️ 이 패치는 **Flutter 업그레이드 시 사라집니다** → 업그레이드하면 다시 적용.

---

## 3. Windows 빌드

### 3-1. 환경 + HUEN 설정

```powershell
cd C:\src\rustdesk          # 클론한 저장소 폴더로 이동
. .\activate.ps1
```

실제 값(서버·키·AAD·패키지명)은 **저장소에 없습니다.** 루트에 `build-config.ps1`을 직접 만들어 채우세요 (`.gitignore`로 커밋 제외됨):
```powershell
# build-config.ps1   ★커밋 금지★
$env:RUSTDESK_SERVER = '<당신의 서버 도메인>'
$HUEN_KEY            = '<서버 공개키>'
$HUEN_AAD_TENANT     = '<M365 tenant id>'
$HUEN_AAD_CLIENT     = '<M365 public client id>'
$HUEN_AAD_CONFIG_URL = 'https://<당신의 서버>/authconfig/config'
$HUEN_APPID_CUSTOMER = '<com.yourco.app>';        $HUEN_APPID_STAFF = '<com.yourco.app>.staff'
$HUEN_LABEL_CUSTOMER = '<App Name>';              $HUEN_LABEL_STAFF = '<App Name> - Staff'
```
그 다음 변형별 env 만 추가합니다.

**고객용**:
```powershell
. .\build-config.ps1
$env:RUSTDESK_KEY = $HUEN_KEY
Remove-Item Env:RUSTDESK_TECHNICIAN -ErrorAction SilentlyContinue
```

**상담원용** (M365 게이트 포함):
```powershell
. .\build-config.ps1
$env:RUSTDESK_TECHNICIAN     = '1'
$env:RUSTDESK_AAD_TENANT     = $HUEN_AAD_TENANT
$env:RUSTDESK_AAD_CLIENT     = $HUEN_AAD_CLIENT
$env:RUSTDESK_AAD_CONFIG_URL = $HUEN_AAD_CONFIG_URL
Remove-Item Env:RUSTDESK_KEY -ErrorAction SilentlyContinue
```
> ($env:RUSTDESK_SERVER 는 build-config.ps1 이 설정함.) 변형 바꿔 빌드할 땐 **새 PowerShell 창** 권장.

### 3-2. 빌드 + 포터블 패킹

```powershell
python build.py --flutter --portable
```
이게 하는 일: Rust 라이브러리 컴파일(이때 `RUSTDESK_SERVER`/`KEY`/`TECHNICIAN`이 `env!`로 baked) → `flutter build windows`(이때 `RUSTDESK_AAD_*`가 `--dart-define`으로 주입) → 자기추출 포터블 exe 패킹.

**출력**: `libs/portable/rustdesk-<버전>-install.exe` (단일 실행 파일, 더블클릭하면 임시폴더에 풀고 실행)

> Flutter 앱은 원래 여러 파일(exe + DLL + data/)이라 "단일 exe"는 brotli 자기추출 패커로 묶은 것입니다.
> 패킹 단계가 실패하면(드물게 python 관련) [6. 트러블슈팅](#6-트러블슈팅) 참고.

설치 안 한 raw 빌드 결과물은: `flutter\build\windows\x64\runner\Release\` (rustdesk.exe + DLL들)

### 3-3. 코드 서명 (배포용, 선택)

USB 토큰 인증서로 Authenticode 서명. **포터블로 묶기 전 안쪽 exe/dll 먼저, 묶은 뒤 바깥 exe도** 서명하는 게 안전합니다(엄격한 AV가 임시추출 exe를 검사하므로):
```powershell
signtool sign /fd SHA256 /a /tr http://timestamp.digicert.com /td SHA256 <파일>
```

---

## 4. Android 빌드

### 4-0. Android 일회성 셋업

| 항목 | 값 / 명령 |
|---|---|
| Android NDK | **r28c** (`28.2.13676358`) → `C:\Android\Sdk\ndk\28.2.13676358` |
| 환경변수 | `$env:ANDROID_NDK_HOME = 'C:\Android\Sdk\ndk\28.2.13676358'` (+ `ANDROID_NDK_ROOT` 동일하게) |
| cargo-ndk | `cargo install cargo-ndk --version 3.1.2 --locked` |
| Rust 타겟 | `rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android` |
| JDK | **17** (Gradle 7.6.4가 Java 19까지만 지원 → 21 쓰면 "major version 65" 에러). 설치 후 `flutter config --jdk-dir "<jdk17 경로>"` |
| vcpkg android deps | `vcpkg install --triplet arm64-android` (libvpx libyuv opus aom libsodium openssl 등) |

> ⚠️ **vcpkg arm64-android 빌드는 Windows에서 toolchain 버그를 만납니다.** aom(ASM 컴파일러), ffmpeg(sysroot), libsodium/openssl 링크 등 — 이미 적용된 fix가 있으나 **vcpkg를 재설치하면 일부(vcpkg-internal)는 다시 적용해야** 합니다. 자세한 건 [6. 트러블슈팅](#6-트러블슈팅).

### 4-1. 서명 키스토어 (배포용, 일회성)

Android는 **자체 서명 키스토어(JKS)** 를 씁니다 — Windows의 USB 코드서명 토큰(Authenticode)과 **다릅니다**.
```powershell
keytool -genkeypair -v -keystore C:\path\to\release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias <alias>
```
그리고 `flutter/android/key.properties` 파일 생성(이미 있으면 그대로):
```properties
storePassword=<KEYSTORE_PASSWORD>
keyPassword=<KEY_PASSWORD>
keyAlias=<alias>
storeFile=C:/path/to/release.jks
```
> ⚠️ **`.jks`는 반드시 백업하세요.** 잃어버리면 앱 업데이트 서명을 못 합니다. `key.properties`와 `.jks`는 **git에 안 올립니다**(gitignore됨, 비밀값). 고객/상담원 APK 둘 다 같은 키스토어로 서명합니다.

### 4-2. 빌드 (스크립트 한 줄)

```powershell
cd C:\src\rustdesk          # 클론한 저장소 폴더로 이동
. .\activate.ps1
$env:ANDROID_NDK_HOME = 'C:\Android\Sdk\ndk\28.2.13676358'   # activate.ps1에 넣었으면 생략

.\build-android.ps1 -Variant customer    # 고객용 APK
# 또는
.\build-android.ps1 -Variant staff        # 상담원용 APK (M365 게이트 + AAD)
```
`build-android.ps1`이 자동으로 하는 일: 변형별 env/dart-define 설정 → `cargo ndk` 로 `.so` 빌드 → jniLibs 복사 → 런처 아이콘 재생성(`flutter_launcher_icons`) → `applicationId`/표시이름 기록 → `flutter build apk`.

**출력**: `flutter\build\app\outputs\flutter-apk\app-release.apk`

> ⚠️ **staff 빌드는 customer의 APK를 덮어씁니다**(같은 출력 경로). 변형 바꿔 빌드하기 전에 이름을 바꿔 보관하세요:
> ```powershell
> Copy-Item flutter\build\app\outputs\flutter-apk\app-release.apk C:\src\HUEN-customer.apk -Force
> ```
> 그리고 변형 전환 시 **새 PowerShell 창** 권장.

**변형별 패키지명 / 표시이름** (한 기기에 둘 다 설치 가능):

| 변형 | applicationId | 표시 이름 |
|---|---|---|
| customer | `<com.yourco.app>` | <App Name> |
| staff | `<com.yourco.app>.staff` | <App Name> - Staff |

---

## 5. 산출물 / 배포

| 플랫폼 | 산출물 | 배포 이름 예시 |
|---|---|---|
| Windows | `libs/portable/rustdesk-<버전>-install.exe` | `HUEN-Support-qs.exe` (서명 후) |
| Android 고객 | `flutter-apk/app-release.apk` | `HUEN-customer.apk` |
| Android 상담원 | `flutter-apk/app-release.apk` | `HUEN-staff.apk` |

---

## 6. 트러블슈팅 (자주 막히는 곳)

**공통**
- `python3`/`pip3` not found → Windows에선 **`python`/`pip`** 사용.
- 빌드가 옛 결과를 재사용(변경 반영 안 됨) → `flutter\build\windows` 또는 `target\` 일부 삭제 후 재빌드.

**Windows**
- "could not find Visual Studio 2019" → [2-3 VS2026 패치](#2-3-visual-studio-2026-인식-패치-windows-빌드-시-1회).
- 포터블 패킹 실패 → 수동 패킹: `python -m pip install -r libs/portable/requirements.txt` 후 `python libs/portable/generate.py -f flutter/build/windows/x64/runner/Release -o . -e flutter/build/windows/x64/runner/Release/rustdesk.exe`.

**Android (vcpkg arm64-android — Windows 크로스 빌드 특유)**
- **aom**: `CMAKE_ASM_COMPILER: as not found` → `C:\vcpkg\scripts\toolchains\android.cmake`에서 NDK toolchain include 직후 `set(CMAKE_ASM_COMPILER "${CMAKE_C_COMPILER}" CACHE FILEPATH "" FORCE)` 추가. *(vcpkg-internal, 재설치 시 재적용)*
- **ffmpeg**: `'ctype.h' not found` / "Native MSYS builds discouraged" → `res/vcpkg/ffmpeg/portfile.cmake`의 android 블록에 `--extra-cflags/--extra-ldflags`에 `--target=aarch64-linux-android28 --sysroot=<ndk sysroot>` 추가 + pkgconf 경로 뒤 공백 1칸. *(repo에 포함됨)*
- **libsodium LNK1136**: 전역 `SODIUM_LIB_DIR` 금지(호스트 빌드까지 오염). `.cargo/config.toml`의 `[target.aarch64-linux-android.sodium]` 오버라이드로 처리(이미 적용). `build-android.ps1`이 `SODIUM_LIB_DIR`를 지움.
- **oboe-sys** `pthread_cond_clockwait` → `CFLAGS_/CXXFLAGS_aarch64_linux_android = --target=aarch64-linux-android28` (build-android.ps1이 설정).
- **hwcodec / build.rs** — android 빌드에서 `'d3d11.h' file not found`: hwcodec `build_common()`이 **호스트** cfg(`#[cfg(windows)]`)로 win.cpp 컴파일 + d3d11/dxgi 링크를 결정 → Windows 호스트에서 android 크로스컴파일 시 오작동. `~/.cargo/git/checkouts/hwcodec-*/<rev>/build.rs`의 두 `#[cfg(windows)]` 블록을 `if target_os == "windows"`로 변경(같은 함수의 macOS 체크와 동일 방식). ⚠️ **이 패치는 `.cargo` 체크아웃이라 git에 없음 — hwcodec가 bump될 때마다(예: upstream #15323) 사라지니 매번 재적용.** cargo는 git dep를 rev로 캐시해 파일 수정만으론 재빌드를 안 하므로, 패치 후 **빌드 캐시 삭제 필수**: `Remove-Item -Recurse -Force target\aarch64-linux-android\release\build\hwcodec-*, target\aarch64-linux-android\release\.fingerprint\hwcodec-*, target\release\build\hwcodec-*, target\release\.fingerprint\hwcodec-*` 후 재빌드.
- **JDK**: "Unsupported class file major version 65" → JDK 17 사용.
- **서명 누락**: `key.properties` + `.jks` 확인 ([4-1](#4-1-서명-키스토어-배포용-일회성)).
- 아이콘이 옛 RustDesk 그대로 → `build-android.ps1`이 `flutter pub run flutter_launcher_icons`를 도는지 확인(이미 포함). adaptive 아이콘은 `res/icon_fg.png`(여백 준 foreground) + pubspec `flutter_launcher_icons:` 설정 사용.

---

## 7. HUEN 커스터마이징 요약 (stock RustDesk 대비 변경점)

이 fork가 stock과 다른 부분 — 빌드/유지보수 시 참고:

**Rust (공통)**
- `src/common.rs` `load_custom_client()` — `RUSTDESK_SERVER`(필수, `env!`) / `RUSTDESK_KEY`(`option_env!`) / `RUSTDESK_TECHNICIAN`(`option_env!`) 주입. 네트워크 설정(서버/키) UI 숨김, `allow-websocket=Y`, `api-server=https://...` baked. 키는 디스크에 안 남기고 in-memory(OVERWRITE)로 주입.
- `src/flutter_ffi.rs` — `main_set_override_option()` 추가(상담원 빌드가 런타임에 받은 키를 in-memory 주입).
- `build.rs` — `build_windows()`를 `if target_os == "windows"`로 게이트(android 크로스 빌드 시 windows.cc 컴파일 방지).
- `.cargo/config.toml`, `vcpkg.json`, `res/vcpkg/ffmpeg/portfile.cmake` — android 크로스 빌드 fix.

**Flutter / Android**
- `flutter/lib/common/huen_aad_gate.dart` (신규) — **상담원 빌드 전용 M365 device-code 로그인 게이트**. 성공 시 설정 엔드포인트에서 서버 키를 받아 in-memory 주입. `RUSTDESK_TECHNICIAN` define으로만 활성.
- `flutter/lib/main.dart` — 홈을 `HuenAadGate`로 감쌈(상담원 빌드만).
- `flutter/android/app/build.gradle` — `applicationId`/표시이름을 `huen.properties`에서 읽음(변형별). Kotlin 네임스페이스(`com.carriez.*`)·JNI(`package ffi`)는 **그대로**(applicationId만 분리).
- `AndroidManifest.xml`, `strings.xml` — 표시이름/접근성 라벨 HUEN으로.
- `pubspec.yaml` — `flutter_launcher_icons:` adaptive 아이콘 설정.
- `build.py` — `huen_dart_defines()`로 상담원용 AAD define을 env에서 자동 구성(Windows/데스크톱 빌드).
- `build-android.ps1` (신규) — Android APK 빌드 오케스트레이터.

**빌드 시 생성/비밀 파일 (git에 안 올림)**
- `flutter/android/key.properties` — 키스토어 비밀번호 (gitignore).
- `flutter/android/huen.properties` — 빌드마다 기록되는 applicationId/label (gitignore).
- 서명 키스토어 `.jks` (저장소 밖, 별도 백업 필수).
- `build-config.ps1` — 실제 서버/키/AAD/패키지명 (gitignore).

---

## 부록 A — HUEN 환경변수

| 변수 | 주입 방식 | customer | staff | 비고 |
|---|---|---|---|---|
| `RUSTDESK_SERVER` | `env!` (cargo, 필수) | ✅ | ✅ | 서버 도메인 (build-config.ps1) |
| `RUSTDESK_KEY` | `option_env!` (cargo) | ✅ | ❌ | 서버 공개키. 상담원는 런타임에 받음 |
| `RUSTDESK_TECHNICIAN` | `option_env!` (cargo) | ❌ | ✅ `1` | 상담원 모드 + AAD 게이트 on |
| `RUSTDESK_AAD_TENANT` | `--dart-define` | ❌ | ✅ | M365 tenant id |
| `RUSTDESK_AAD_CLIENT` | `--dart-define` | ❌ | ✅ | M365 client id (public client) |
| `RUSTDESK_AAD_CONFIG_URL` | `--dart-define` | ❌ | ✅ | 키 받아오는 엔드포인트 |

- **cargo `env!`/`option_env!`** 변수는 `cargo build`/`build.py` 실행 **전에 환경변수로** 설정 (Rust 컴파일 시점에 박힘).
- **`--dart-define`** 변수는 Windows는 `build.py`가 env에서 자동 변환, Android는 `build-android.ps1`이 변형에 따라 자동 추가.
