#!/bin/bash
# Usage: android-test.sh <Swift SDKs path> <Swift SDK id> <triple>
#
# Runs the package's tests, built for `triple`, on the running emulator
# (see android-start-emulator.sh). The test runners go to the emulator with
# the libraries they load beside them: the Swift runtime and Foundation from
# the SDK, and the NDK's C++ library. Every runner runs; the script fails
# after the last one if any failed.
set -euo pipefail
sdks=$1 sdk_id=$2 triple=$3
arch="${triple%%-*}"

adb="$ANDROID_HOME/platform-tools/adb"
sdk="$sdks/$sdk_id.artifactbundle/swift-android"
bin="$(swift build --swift-sdks-path "$sdks" --swift-sdk "$sdk_id" --triple "$triple" --show-bin-path)"

stage="$RUNNER_TEMP/mm"
mkdir -p "$stage"
find "$bin" -maxdepth 1 \( -name '*-test-runner' -o -name '*.xctest' -o -name '*.so' \) \
    -exec cp -a {} "$stage" \;
cp "$sdk/swift-resources/usr/lib/swift-$arch/android/"*.so "$stage"
cp "$sdk/ndk-sysroot/usr/lib/$arch-linux-android/libc++_shared.so" "$stage"
runners="$(cd "$stage" && ls -1 | grep -E -e '-test-runner$' -e '\.xctest$')"
if [ -z "$runners" ]; then
    echo "::error::No test runners in $bin."
    exit 1
fi

# The tests bind unix sockets under TMPDIR. SELinux lets the shell user create
# files in /data/local/tmp but not sockets (bind fails with EACCES), so the
# tests run as root, as they do in the Linux container. adbd restarts for it,
# so this waits until the shell is root.
"$adb" root
for _ in $(seq 30); do
    "$adb" wait-for-device
    [ "$(timeout 10 "$adb" shell id -u 2> /dev/null | tr -d '\r' || true)" = 0 ] && break
    sleep 1
done
if [ "$("$adb" shell id -u | tr -d '\r')" != 0 ]; then
    echo "::error::adbd did not restart as root."
    exit 1
fi

"$adb" push "$stage" /data/local/tmp/
device=/data/local/tmp/mm
failed=()
for runner in $runners; do
    echo "== $runner"
    "$adb" shell "cd $device && TMPDIR=/data/local/tmp ./$runner --testing-library swift-testing" ||
        failed+=("$runner")
done
if [ ${#failed[@]} -gt 0 ]; then
    echo "::error::Failed on the emulator: ${failed[*]}"
    exit 1
fi
