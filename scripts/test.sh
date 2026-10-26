#!/bin/zsh
# Runs the test suite with the Command Line Tools' swift-testing (no Xcode needed).
# Cross-import overlays are disabled because the CLT ship _Testing_Foundation without modules.
set -euo pipefail
cd "$(dirname "$0")/.."
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
swift test -Xswiftc -F$F -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
    -Xlinker -F$F -Xlinker -rpath -Xlinker $F "$@"
