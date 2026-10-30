#!/bin/zsh
# Runs the unit tests. With Command Line Tools (no Xcode), explicit module builds fail to
# resolve the Swift Testing macro plugin in-process ("plugin for module 'TestingMacros' not
# found"), so it is loaded through the out-of-process plugin server instead.
set -euo pipefail
cd "$(dirname "$0")/.."
tools="$(xcode-select -p)"
plugins="$tools/usr/lib/swift/host/plugins/testing"
if [[ -d "$plugins" ]]; then
  exec swift test -Xswiftc -external-plugin-path -Xswiftc "$plugins#$tools/usr/bin/swift-plugin-server" "$@"
fi
exec swift test "$@"
