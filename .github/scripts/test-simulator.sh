#!/bin/bash
# Usage: test-simulator.sh <simulator UDID>
#
# Runs the client stack's tests on that simulator, then prints how many ran:
# `xcodebuild -quiet` prints none. The MMClientStackTests scheme builds and
# runs the tests of what the client links (MMWire, MMSchema, MMClient), never
# the server, CLI or integration targets. Fails if none ran, or any was
# skipped.
set -euo pipefail
udid=$1

results="$RUNNER_TEMP/tests.xcresult"
rm -rf "$results"
status=0
xcodebuild test -quiet -scheme MMClientStackTests -destination "id=$udid" \
    -skipMacroValidation -skipPackagePluginValidation \
    -resultBundlePath "$results" || status=$?

# The counts, and each failure's message, which `-quiet` leaves out.
summary="$(xcrun xcresulttool get test-results summary --path "$results" --compact)"
jq -r '"\(.totalTestCount) tests: \(.passedTests) passed, \(.skippedTests) skipped, \(.failedTests) failed"' <<< "$summary"
jq -r '.testFailures[]? | "::error::\(.testName): \(.failureText)"' <<< "$summary"
if ! jq -e '.totalTestCount > 0 and .skippedTests == 0' <<< "$summary" > /dev/null; then
    echo "::error::No tests ran, or some were skipped."
    [ "$status" != 0 ] || status=1
fi
exit "$status"
