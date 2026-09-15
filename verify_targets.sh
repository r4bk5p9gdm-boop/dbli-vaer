#!/usr/bin/env bash
set -euo pipefail

# Resource-safe target check: generic destinations compile the targets without
# booting a simulator or touching a physical device. Exit instead of
# competing with another maintenance/build process.
project_root="$(cd "$(dirname "$0")" && pwd)"
cd "$project_root"

if pgrep -f 'xcodebuild.*VarselApp\.xcodeproj' >/dev/null 2>&1; then
  echo "Et annet xcodebuild kjører allerede; avbryter uten overlapp." >&2
  exit 2
fi

if xcrun simctl list devices 2>/dev/null | rg -q '\(Booted\)'; then
  echo "En simulator er allerede startet; avbryter uten å starte en ny." >&2
  exit 2
fi

developer_dir="${DEVELOPER_DIR:-/Applications/Xcode-27.app/Contents/Developer}"
derived_data="${DERIVED_DATA_PATH:-.build/VerifyTargets}"

for scheme in VarselApp DbliVaerWidget; do
  DEVELOPER_DIR="$developer_dir" xcodebuild \
    -project VarselApp.xcodeproj -scheme "$scheme" \
    -destination generic/platform=iOS -derivedDataPath "$derived_data" \
    -jobs 2 CODE_SIGNING_ALLOWED=NO build-for-testing
done

for scheme in DbliVaerWatchApp DbliVaerWatchWidget; do
  DEVELOPER_DIR="$developer_dir" xcodebuild \
    -project VarselApp.xcodeproj -scheme "$scheme" \
    -destination generic/platform=watchOS -derivedDataPath "$derived_data" \
    -jobs 2 CODE_SIGNING_ALLOWED=NO build
done

echo "Alle iOS- og watchOS-mål er verifisert uten simulator."
