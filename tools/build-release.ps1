# Release builds of Passlune, with each version's Dart symbols kept.
#
# --obfuscate hides Dart names in the app, and only the matching
# build/symbols files turn its crash stack traces back into readable code
# (flutter symbolize). `flutter clean` and the next build wipe build/, so
# they are copied to release-symbols/<version>/ (ignored by git). The R8
# mapping and native symbols also travel inside the .aab, where Play picks
# them up by itself; the copy here is for the APK.
#
#   powershell -File tools/build-release.ps1            Android: AAB + one APK
#   powershell -File tools/build-release.ps1 -Windows   and the Windows build
param([switch]$Windows)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot)

$version = (Select-String -Path pubspec.yaml -Pattern '^version:\s*(\S+)').Matches[0].Groups[1].Value
$out = "release-symbols/$version"
if (Test-Path $out) { throw "$out already exists: raise the version in pubspec.yaml first." }

# flutter from PATH, else the SDK the Android build records in local.properties.
$flutter = (Get-Command flutter -ErrorAction SilentlyContinue).Source
if (-not $flutter) {
  $sdk = (Select-String -Path android/local.properties -Pattern '^flutter\.sdk=(.+)$').Matches[0].Groups[1].Value -replace '\\\\', '\' -replace '\\:', ':'
  $flutter = Join-Path $sdk 'bin\flutter.bat'
}

function Build([string[]]$target) {
  & $flutter build @target --release --obfuscate --split-debug-info=build/symbols
  if ($LASTEXITCODE) { throw "flutter build $target failed" }
}

# Copies the symbols of one target (android-*, windows-*). build/symbols is
# not emptied first: when the Dart code hasn't changed, flutter reuses its
# cached build and doesn't write them again.
function Keep([string]$target, [string]$to) {
  $files = @(Get-ChildItem "build/symbols/app.$target-*.symbols" -ErrorAction SilentlyContinue)
  if (-not $files) { throw "No $target symbols in build/symbols: run flutter clean and build again." }
  New-Item -ItemType Directory -Force $to | Out-Null
  $files | Copy-Item -Destination $to
}

try {
  Build @('appbundle')
  Keep android "$out/android-aab"
  Copy-Item build/app/outputs/mapping/release/mapping.txt "$out/android-aab/"
  # One APK for every phone, not --split-per-abi: split APKs get
  # 1000 x ABI added to their versionCode (7001 for arm64), and a phone
  # holding one could then never take the lower-numbered Play updates.
  Build @('apk')
  Keep android "$out/android-apk"
  Copy-Item build/app/outputs/mapping/release/mapping.txt "$out/android-apk/"

  if ($Windows) {
    Build @('windows')
    Keep windows "$out/windows"
  }
} catch {
  # A half-filled archive would block the next try (see above).
  if (Test-Path $out) { Remove-Item $out -Recurse -Force }
  throw
}

Write-Host ''
Write-Host "Passlune $version"
Write-Host '  Play:    build/app/outputs/bundle/release/app-release.aab'
Write-Host '  GitHub:  build/app/outputs/flutter-apk/app-release.apk'
if ($Windows) { Write-Host '  Windows: build/windows/x64/runner/Release/' }
Write-Host "  Symbols: $out"
