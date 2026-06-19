# 빌드 전, 새 PowerShell 창마다 1회 — 저장소 폴더에서 실행:  . .\activate.ps1
# 경로는 본인 설치 위치에 맞게 조정하세요.
$env:VCPKG_ROOT    = 'C:\vcpkg'
$env:LIBCLANG_PATH = 'C:\Program Files\LLVM\bin'
$env:Path = "C:\flutter\bin;$env:USERPROFILE\.cargo\bin;C:\vcpkg;" + $env:Path
# Android 빌드 시 NDK 경로도 (선택):
# $env:ANDROID_NDK_HOME = 'C:\Android\Sdk\ndk\28.2.13676358'
Write-Host 'RustDesk build env activated' -ForegroundColor Green
