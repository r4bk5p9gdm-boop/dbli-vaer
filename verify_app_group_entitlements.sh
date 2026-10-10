#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")" && pwd)"
cd "$project_root"

shared_data_file="VarselApp/SharedWidgetData.swift"
expected_group="$(sed -nE 's/^[[:space:]]*static let appGroup = "([^"]+)".*/\1/p' "$shared_data_file" | head -n 1)"
if [[ -z "$expected_group" ]]; then
  echo "Fant ikke appgruppe-ID i $shared_data_file." >&2
  exit 1
fi

check_target_entitlement() {
  local target="$1"
  local entitlement="$2"
  local configuration resolved

  if [[ ! -f "$entitlement" ]]; then
    echo "Entitlement-filen mangler: $entitlement" >&2
    exit 1
  fi
  if ! /usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups' "$entitlement" 2>/dev/null \
    | grep -Fq "$expected_group"; then
    echo "$entitlement mangler delt appgruppe $expected_group." >&2
    exit 1
  fi

  for configuration in Debug Release; do
    resolved="$(xcodebuild -project VarselApp.xcodeproj -target "$target" \
      -configuration "$configuration" -showBuildSettings 2>/dev/null \
      | awk -F ' = ' '/^[[:space:]]*CODE_SIGN_ENTITLEMENTS = / { print $2; exit }')"
    if [[ "$resolved" != "$entitlement" ]]; then
      echo "$target ($configuration) bruker '$resolved', forventet '$entitlement'." >&2
      exit 1
    fi
  done
}

check_target_entitlement VarselApp VarselApp/VarselApp.entitlements
check_target_entitlement DbliVaerWidget DbliVaerWidget/DbliVaerWidget.entitlements
check_target_entitlement DbliVaerWatchApp DbliVaerWatchApp/DbliVaerWatchApp.entitlements
check_target_entitlement DbliVaerWatchWidget DbliVaerWatchWidget/DbliVaerWatchWidget.entitlements

echo "Debug og Release for alle fire mål bruker entitlements med delt appgruppe $expected_group."
