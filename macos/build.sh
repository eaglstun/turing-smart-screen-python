#!/bin/sh
# Build with Xcode's Swift toolchain. (A swiftly-installed toolchain earlier on PATH crashes against the macOS SDK.)
set -e
cd "$(dirname "$0")"
SWIFT="${SWIFT:-/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift}"
exec "$SWIFT" build "$@"
