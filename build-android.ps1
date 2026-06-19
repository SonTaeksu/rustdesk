# build-android.ps1 — HUEN RustDesk Android APK 빌드 (고객/상담원)
#
# 선행(일회성, 아래 "일회성 셋업" 참고):
#   - ANDROID_NDK_HOME (NDK r28c), VCPKG_ROOT 환경변수
#   - vcpkg android deps 설치 (vcpkg install --triplet arm64-android ...)
#   - cargo install cargo-ndk --version 3.1.2 --locked
#   - rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
#   - flutter_rust_bridge_codegen 1회 (flutter_ffi.rs 바뀐 것 반영)
#
# 사용:
#   .\build-android.ps1 -Variant customer                    # arm64 고객 APK
#   .\build-android.ps1 -Variant staff                       # arm64 상담원 APK
#   .\build-android.ps1 -Variant customer -Abi armeabi-v7a   # 다른 ABI
param(
  [Parameter(Mandatory)][ValidateSet('customer', 'staff')][string]$Variant,
  [ValidateSet('arm64-v8a', 'armeabi-v7a', 'x86_64')][string]$Abi = 'arm64-v8a'
)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

if (-not $env:ANDROID_NDK_HOME) { throw 'ANDROID_NDK_HOME 환경변수가 필요합니다 (NDK r28c 경로).' }
if (-not $env:VCPKG_ROOT)       { throw 'VCPKG_ROOT 환경변수가 필요합니다 (android deps 설치된 vcpkg).' }

# HUEN: 실제 배포값(서버/키/AAD/패키지명)은 git에 안 올라가는 build-config.ps1 에서 읽는다.
$cfgPath = "$PSScriptRoot\build-config.ps1"
if (-not (Test-Path $cfgPath)) { throw 'build-config.ps1 가 없습니다 — 본인 값으로 만드세요 (예시: BUILD-HUEN.md).' }
. $cfgPath

$rustTarget = @{ 'arm64-v8a' = 'aarch64-linux-android'; 'armeabi-v7a' = 'armv7-linux-androideabi'; 'x86_64' = 'x86_64-linux-android' }[$Abi]
$ndkTriple  = @{ 'arm64-v8a' = 'aarch64-linux-android'; 'armeabi-v7a' = 'arm-linux-androideabi';   'x86_64' = 'x86_64-linux-android' }[$Abi]
$targetPlat = @{ 'arm64-v8a' = 'android-arm64';        'armeabi-v7a' = 'android-arm';             'x86_64' = 'android-x64' }[$Abi]

# HUEN: libsodium-sys 는 Windows 호스트에서 android용 소스 빌드를 못 하므로 vcpkg가 만든 걸 링크
$vcpkgTriplet = @{ 'arm64-v8a' = 'arm64-android'; 'armeabi-v7a' = 'arm-android'; 'x86_64' = 'x64-android' }[$Abi]
# HUEN: 전역 SODIUM_LIB_DIR 은 호스트(Windows) 빌드스크립트까지 android libsodium을 링크하게 해
#       LNK1136(아키텍처 불일치)을 냄 → 제거. android 타겟 libsodium은 .cargo/config.toml 의
#       [target.aarch64-linux-android.sodium] 오버라이드로 처리. 호스트는 windows libsodium(자동).
Remove-Item Env:SODIUM_LIB_DIR, Env:SODIUM_STATIC -ErrorAction SilentlyContinue
# HUEN: openssl-sys 도 vcpkg가 만든 android openssl 사용 (vendored 빌드 회피)
$env:OPENSSL_DIR = "$env:VCPKG_ROOT\installed\$vcpkgTriplet"
$env:OPENSSL_STATIC = '1'
$env:OPENSSL_NO_VENDOR = '1'
# HUEN: cargo-ndk가 cc-rs(C++: oboe 등) 빌드에 API 레벨을 안 넘겨 --target에 API 번호가 빠짐 →
#       libc++가 API30 전용 pthread_cond_clockwait 를 낮은 API에서 참조해 깨짐. C/C++ 타겟에 API28 명시.
$tgtU = $rustTarget.Replace('-', '_')
[Environment]::SetEnvironmentVariable("CFLAGS_$tgtU", "--target=${rustTarget}28", "Process")
[Environment]::SetEnvironmentVariable("CXXFLAGS_$tgtU", "--target=${rustTarget}28", "Process")

# ── 변형별 baked env + dart-define (실제값은 build-config.ps1 에서) ──
$flutterArgs = @('build', 'apk', '--release', '--target-platform', $targetPlat)
if ($Variant -eq 'customer') {
  $env:RUSTDESK_KEY = $HUEN_KEY                                       # = 서버 공개키
  Remove-Item Env:RUSTDESK_TECHNICIAN -ErrorAction SilentlyContinue
  $appId = $HUEN_APPID_CUSTOMER
  $appLabel = $HUEN_LABEL_CUSTOMER
}
else {
  $env:RUSTDESK_TECHNICIAN = '1'
  Remove-Item Env:RUSTDESK_KEY -ErrorAction SilentlyContinue          # 상담원: 키 미베이크(런타임 AAD)
  $flutterArgs += '--dart-define=RUSTDESK_TECHNICIAN=1'
  $flutterArgs += "--dart-define=RUSTDESK_AAD_TENANT=$HUEN_AAD_TENANT"
  $flutterArgs += "--dart-define=RUSTDESK_AAD_CLIENT=$HUEN_AAD_CLIENT"
  $flutterArgs += "--dart-define=RUSTDESK_AAD_CONFIG_URL=$HUEN_AAD_CONFIG_URL"
  $appId = $HUEN_APPID_STAFF                                          # 상담원: 고객과 분리 → 한 기기 공존
  $appLabel = $HUEN_LABEL_STAFF
}

Write-Host "==> [$Variant / $Abi] cargo ndk build" -ForegroundColor Cyan
cargo ndk --platform 28 --target $rustTarget build --locked --release --features flutter,hwcodec

Write-Host '==> jniLibs 복사' -ForegroundColor Cyan
$jni = "flutter\android\app\src\main\jniLibs\$Abi"
New-Item -ItemType Directory -Force $jni | Out-Null
Copy-Item "target\$rustTarget\release\liblibrustdesk.so" "$jni\librustdesk.so" -Force
Copy-Item "$env:ANDROID_NDK_HOME\toolchains\llvm\prebuilt\windows-x86_64\sysroot\usr\lib\$ndkTriple\libc++_shared.so" "$jni\" -Force

# HUEN: adaptive 아이콘 foreground(res/icon_fg.png)를 icon.png에서 재생성 (여백 60% → 원형 마스크에 안 잘림).
#       icon_fg.png 는 루트 .gitignore 의 *png 로 커밋 안 되므로, 매 빌드 icon.png 에서 새로 만든다.
Write-Host '==> adaptive foreground (icon_fg.png) 생성' -ForegroundColor Cyan
Add-Type -AssemblyName System.Drawing
$icoSrc = [System.Drawing.Image]::FromFile("$PSScriptRoot\res\icon.png")
$icoCanvas = New-Object System.Drawing.Bitmap(512, 512)
$icoG = [System.Drawing.Graphics]::FromImage($icoCanvas)
$icoG.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$icoG.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
$icoG.Clear([System.Drawing.Color]::Transparent)
$icoTw = [int](512 * 0.60); $icoOff = [int]((512 - $icoTw) / 2)
$icoG.DrawImage($icoSrc, $icoOff, $icoOff, $icoTw, $icoTw)
$icoG.Dispose()
$icoCanvas.Save("$PSScriptRoot\res\icon_fg.png", [System.Drawing.Imaging.ImageFormat]::Png)
$icoCanvas.Dispose(); $icoSrc.Dispose()

# HUEN: 런처 아이콘을 res/icon.png(+ res/icon_fg.png adaptive foreground) 기준으로 재생성.
#       이 단계가 없으면 stock RustDesk 아이콘이 그대로 남는다.
Write-Host '==> 런처 아이콘 재생성 (flutter_launcher_icons)' -ForegroundColor Cyan
Push-Location flutter
try { & flutter pub run flutter_launcher_icons } finally { Pop-Location }

# HUEN: 변형별 applicationId 를 Gradle 이 읽도록 huen.properties 기록.
#       (env 변수는 Gradle 데몬이 캐싱해 변형 전환이 안 먹음 → 파일은 매 빌드 새로 읽힘)
Write-Host "==> applicationId = $appId / label = $appLabel" -ForegroundColor Cyan
Set-Content -Path "$PSScriptRoot\flutter\android\huen.properties" -Value @("applicationId=$appId", "appLabel=$appLabel") -Encoding ASCII

Write-Host "==> flutter build apk ($Variant)" -ForegroundColor Cyan
Push-Location flutter
try { & flutter @flutterArgs } finally { Pop-Location }

Write-Host '==> 완료: flutter\build\app\outputs\flutter-apk\app-release.apk' -ForegroundColor Green
Write-Host '   (변형 바꿔 다시 빌드 전, 같은 셸이면 env가 남으니 새 셸 권장)'
