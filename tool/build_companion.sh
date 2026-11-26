#!/usr/bin/env bash
# Builds the TV APKs, bundles them into the companion, and builds the companion release APK.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v flutter >/dev/null; then
  export PATH="$HOME/.cache/elimor-toolchain/flutter/bin:$PATH"
fi
export JAVA_HOME="${JAVA_HOME:-$HOME/.cache/elimor-toolchain/jdk}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/.cache/elimor-toolchain/sdk}"

cd "$root"
flutter build apk --release --split-per-abi --target-platform android-arm,android-arm64
mkdir -p companion/assets/tv
for abi in armeabi-v7a arm64-v8a; do
  cp "build/app/outputs/flutter-apk/app-$abi-release.apk" "companion/assets/tv/ilonatv-$abi.apk"
done

cd companion
flutter build apk --release
echo "$root/companion/build/app/outputs/flutter-apk/app-release.apk"
