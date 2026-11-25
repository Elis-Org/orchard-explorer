#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
developer_dir="$(xcode-select -p)"
test_flags=()
# CLT ships Swift Testing without wiring its framework/plugin paths into SwiftPM.
# Full Xcode normally supplies these automatically; detect the CLT layout only.
framework_dir="$developer_dir/Library/Developer/Frameworks"
macro_library="$developer_dir/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [[ -d "$framework_dir/Testing.framework" && -f "$macro_library" ]]; then
    test_flags=(
        -Xswiftc -F -Xswiftc "$framework_dir"
        -Xswiftc -load-plugin-library -Xswiftc "$macro_library"
        -Xlinker -F -Xlinker "$framework_dir"
        -Xlinker -rpath -Xlinker "$framework_dir"
    )
fi
exec swift test --build-system native --arch arm64 --disable-xctest --enable-swift-testing "${test_flags[@]}" "$@"
