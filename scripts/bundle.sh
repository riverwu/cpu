#!/bin/zsh
# Builds build/CPU.app (release) and signs it.
#
# TCC permissions (Accessibility, Screen Recording, Microphone) are bound to the code
# signature: an ad-hoc signature changes on every build and silently drops them, so a
# stable "Apple Development" identity is used when one exists.
#   CPU_SIGN_IDENTITY="Apple Development: ..." scripts/bundle.sh   # pick an identity
#   scripts/bundle.sh --open                                      # build, then launch
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product CPUApp

app=build/CPU.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/CPUApp "$app/Contents/MacOS/CPU"
cp Resources/Info.plist "$app/Contents/Info.plist"

identity="${CPU_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity=$(security find-identity -v -p codesigning | grep -v REVOKED | grep -m1 '"Apple Development' | sed -E 's/.*"(.*)".*/\1/' || true)
fi
if [[ -n "$identity" ]]; then
  codesign --force --sign "$identity" "$app"
  echo "signed with: $identity"
else
  codesign --force --sign - "$app"
  echo "warning: ad-hoc signature; macOS permissions must be re-granted after each rebuild" >&2
fi
echo "built $app"

if [[ "${1:-}" == "--open" ]]; then
  pkill -x CPU 2>/dev/null || true
  open "$app"
fi
