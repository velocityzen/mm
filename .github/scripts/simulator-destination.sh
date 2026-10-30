#!/usr/bin/env bash
# Prints the UDID of an available simulator for a platform, on its newest
# installed runtime, whose device name starts with a prefix. CI images name
# their simulators differently from release to release, so the jobs pick one
# instead of hard-coding a name. When the image has no runtime for the
# platform it is downloaded; when the runtime has no matching device, one is
# created.
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

newest_runtime() {
    xcrun simctl list runtimes available --json \
        | jq -r --arg prefix "$runtime_prefix" '
            [.runtimes[] | select(.identifier | startswith($prefix))]
            | sort_by(.version | split(".") | map(tonumber))
            | last | .identifier // empty'
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

runtime=$(newest_runtime)
if [[ -z "$runtime" ]]; then
    echo "No $platform simulator runtime installed; downloading it." >&2
    xcodebuild -downloadPlatform "$platform" >&2
    runtime=$(newest_runtime)
fi
if [[ -z "$runtime" ]]; then
    echo "No $platform simulator runtime, even after downloading it." >&2
    exit 1
fi

udid=$(available_device "$runtime")
if [[ -z "$udid" ]]; then
    type=$(device_type "$runtime")
    if [[ -z "$type" ]]; then
        echo "$runtime supports no device named $device_prefix*." >&2
        exit 1
    fi
    echo "No $device_prefix simulator on $runtime; creating one." >&2
    udid=$(xcrun simctl create "CI $device_prefix" "$type" "$runtime")
fi

echo "Using $(xcrun simctl list devices | grep "$udid" | sed -E 's/^ +//') on $runtime." >&2
echo "$udid"
