#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"
TEST_OPTIONS=(--disable-xctest --enable-swift-testing)
if [[ -n "${MACOS_SDK_PATH:-}" ]]; then
    TEST_OPTIONS+=(--sdk "${MACOS_SDK_PATH}")
fi
if [[ -n "${SWIFT_BUILD_SYSTEM:-}" ]]; then
    TEST_OPTIONS+=(--build-system "${SWIFT_BUILD_SYSTEM}")
fi

# Las Command Line Tools pueden distribuir Swift Testing como framework.
DEVELOPER_FRAMEWORKS="${DEVELOPER_DIR:-$(xcode-select -p)}/Library/Developer/Frameworks"
if [[ -d "${DEVELOPER_FRAMEWORKS}/Testing.framework" ]]; then
    TEST_OPTIONS+=(
        -Xswiftc -F -Xswiftc "${DEVELOPER_FRAMEWORKS}"
        -Xlinker -F -Xlinker "${DEVELOPER_FRAMEWORKS}"
        -Xlinker -rpath -Xlinker "${DEVELOPER_FRAMEWORKS}"
    )
fi
swift test "${TEST_OPTIONS[@]}"
