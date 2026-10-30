#!/usr/bin/env bash
# Prints the UDID of an available simulator for a platform whose device name
# starts with a prefix. CI images name their simulators differently from
# release to release, and a runtime may carry only some device families, so
# the jobs pick one instead of hard-coding a name: an existing device on the
# newest runtime that has one, else a device created on the newest runtime
# that supports one. When the image has no runtime for the platform it is
# downloaded. When nothing fits, it lists what the image has and fails.
#
# Usage: simulator-destination.sh <platform> <device name prefix>
#   platform: iOS, tvOS, watchOS or visionOS (the xcodebuild -downloadPlatform names)
#   prefix:   iPhone, iPad, Apple TV, Apple Watch, Apple Vision, ...
set -euo pipefail

platform="$1"
device_prefix="$2"

case "$platform" in
    visionOS) runtime_prefix="com.apple.CoreSimulator.SimRuntime.xrOS-" ;;
    *) runtime_prefix="com.apple.CoreSimulator.SimRuntime.$platform-" ;;
esac

# The platform's available runtimes, newest first, one identifier per line.
runtimes_newest_first() {
    xcrun simctl list runtimes available --json \
        | jq -r --arg prefix "$runtime_prefix" '
            [.runtimes[] | select(.identifier | startswith($prefix))]
            | sort_by(.version | split(".") | map(tonumber))
            | reverse | .[].identifier'
}

available_device() {
    xcrun simctl list devices available --json \
        | jq -r --arg runtime "$1" --arg prefix "$device_prefix" '
            .devices[$runtime] // []
            | map(select(.name | startswith($prefix)))
            | first | .udid // empty'
}

device_type() {
    xcrun simctl list runtimes --json \
        | jq -r --arg runtime "$1" --arg prefix "$device_prefix" '
            .runtimes[] | select(.identifier == $runtime)
            | .supportedDeviceTypes
            | map(select(.name | startswith($prefix)))
            | first | .identifier // empty'
}

describe_runtimes() {
    for runtime in "${runtimes[@]}"; do
        echo "$runtime" >&2
        echo "  devices: $(xcrun simctl list devices available --json \
            | jq -r --arg runtime "$runtime" '.devices[$runtime] // [] | map(.name) | join(", ")')" >&2
        echo "  device types: $(xcrun simctl list runtimes --json \
            | jq -r --arg runtime "$runtime" '.runtimes[] | select(.identifier == $runtime)
                | .supportedDeviceTypes | map(.name) | join(", ")')" >&2
    done
}

runtimes=()
while IFS= read -r runtime; do
    runtimes+=("$runtime")
done < <(runtimes_newest_first)
if [[ ${#runtimes[@]} -eq 0 ]]; then
    echo "No $platform simulator runtime installed; downloading it." >&2
    xcodebuild -downloadPlatform "$platform" >&2
    while IFS= read -r runtime; do
        runtimes+=("$runtime")
    done < <(runtimes_newest_first)
fi
if [[ ${#runtimes[@]} -eq 0 ]]; then
    echo "No $platform simulator runtime, even after downloading it." >&2
    exit 1
fi

for runtime in "${runtimes[@]}"; do
    udid=$(available_device "$runtime")
    if [[ -n "$udid" ]]; then
        echo "Using $(xcrun simctl list devices | grep "$udid" | sed -E 's/^ +//') on $runtime." >&2
        echo "$udid"
        exit 0
    fi
done

for runtime in "${runtimes[@]}"; do
    type=$(device_type "$runtime")
    if [[ -n "$type" ]]; then
        echo "No $device_prefix simulator installed; creating one on $runtime." >&2
        udid=$(xcrun simctl create "CI $device_prefix" "$type" "$runtime")
        echo "Using $(xcrun simctl list devices | grep "$udid" | sed -E 's/^ +//') on $runtime." >&2
        echo "$udid"
        exit 0
    fi
done

echo "No $platform runtime has or supports a device named $device_prefix*. The image has:" >&2
describe_runtimes
exit 1
