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

# Keep the generic fallback honest: a simulator-free build is only useful when
# the app target still resolves to the project's supported iOS deployment.
ios_target="$(DEVELOPER_DIR="$developer_dir" xcodebuild -project VarselApp.xcodeproj \
  -scheme VarselApp -showBuildSettings 2>/dev/null \
  | awk -F ' = ' '/^[[:space:]]*IPHONEOS_DEPLOYMENT_TARGET = / { print $2; exit }')"
if [[ -z "$ios_target" ]]; then
  echo "Fant ikke iOS deployment target; avbryter byggkontrollen." >&2
  exit 3
fi
echo "iOS deployment target: $ios_target"

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
