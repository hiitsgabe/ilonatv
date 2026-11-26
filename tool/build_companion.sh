#!/usr/bin/env bash
# Builds the companion release APK. It installs Ilona TV from the latest GitHub Release, so no TV APK goes in.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v flutter >/dev/null; then
  export PATH="$HOME/.cache/elimor-toolchain/flutter/bin:$PATH"
fi
export JAVA_HOME="${JAVA_HOME:-$HOME/.cache/elimor-toolchain/jdk}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/.cache/elimor-toolchain/sdk}"

cd "$root/companion"
flutter build apk --release
echo "$root/companion/build/app/outputs/flutter-apk/app-release.apk"
