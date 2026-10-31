#!/bin/bash
# Usage: run-examples.sh <bin directory>
#
# Runs the examples built in `bin directory` against each other: the daemon
# on a socket of its own; the client, which goes through every call pattern;
# and the CLI, which appends a line from its arguments and lines from stdin,
# and reads them back. Then ends the daemon with SIGTERM, which drains it
# gracefully, and checks that it removed its socket file.
set -euo pipefail
bin=$1

dir="$(mktemp -d)"
socket="$dir/mm.sock"
"$bin/mm-example-daemon" "$socket" &
daemon=$!
trap 'kill -KILL "$daemon" 2> /dev/null || true; rm -rf "$dir"' EXIT

for _ in $(seq 100); do
    [ -S "$socket" ] && break
    if ! kill -0 "$daemon" 2> /dev/null; then
        echo "::error::The daemon exited before it listened."
        exit 1
    fi
    sleep 0.1
done
if [ ! -S "$socket" ]; then
    echo "::error::The daemon did not listen in 10 seconds."
    exit 1
fi

# The client reports a failure and still exits 0, so its last line is checked.
echo "== mm-example-client"
"$bin/mm-example-client" "$socket" | tee "$dir/client.txt"
if [ "$(tail -n 1 "$dir/client.txt")" != "closed cleanly" ]; then
    echo "::error::The client did not close cleanly."
    exit 1
fi

echo "== mm-example-cli"
cli() { "$bin/mm-example-cli" "$@" --socket "$socket"; }
cli journal add "from the arguments" journal.notes
printf 'from stdin\n!urgent from stdin\n' | cli journal add --input - journal.notes
cli journal read journal.notes --output text | tee "$dir/read.txt"
for line in "from the arguments" "from stdin" "urgent from stdin"; do
    if ! grep -qxF "$line" "$dir/read.txt"; then
        echo "::error::The journal has no \"$line\"."
        exit 1
    fi
done

echo "== SIGTERM"
kill -TERM "$daemon"
wait "$daemon"
if [ -e "$socket" ]; then
    echo "::error::The daemon left its socket file behind."
    exit 1
fi
echo "The daemon drained and removed its socket file."
