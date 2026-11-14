#!/bin/bash
# Usage: check-benchmark-thresholds.sh <thresholds directory>
#
# Runs the Benchmarks package and checks every benchmark's counts against the
# thresholds saved in `thresholds directory`. A count that moved either way
# fails the check: worse is a regression, and better means the saved
# threshold is to be lowered. On a failure, writes the measured counts over
# the saved ones and prints the diff, so the change can be reviewed and
# committed.
set -uo pipefail
thresholds=$1

# MMThroughputBenchmarks times messages per second: its counts depend on the
# scheduler and the socket, so it has no thresholds to hold.
skip=(--skip-target MMThroughputBenchmarks)

# `thresholds check` passes a benchmark that has no saved thresholds, so a
# new benchmark would go unchecked: every benchmark needs its file.
complete=true
target=""
while IFS= read -r line; do
    if [[ $line =~ ^Target\ \'(.+)\'\ available\ benchmarks:$ ]]; then
        target=${BASH_REMATCH[1]}
    elif [[ -z $line ]]; then
        target=""
    elif [[ -n $target && ! -f "$thresholds/$target.$line.p90.json" ]]; then
        echo "::error::$target $line has no thresholds in $thresholds."
        complete=false
    fi
done < <(swift package --package-path Benchmarks benchmark list "${skip[@]}")

if $complete && swift package --package-path Benchmarks benchmark thresholds check \
    "${skip[@]}" --path "$thresholds" --no-progress; then
    exit 0
fi

echo "::error::The benchmark counts do not match $thresholds. The measured counts follow."
mkdir -p "$thresholds"
swift package --package-path Benchmarks --allow-writing-to-package-directory \
    benchmark thresholds update "${skip[@]}" --path "$thresholds" --no-progress || exit 1
# The checkout belongs to another user in a container, which git refuses
# without the safe.directory exception.
git -c safe.directory="$PWD" add --intent-to-add "$thresholds"
git -c safe.directory="$PWD" --no-pager diff -- "$thresholds"
exit 1
