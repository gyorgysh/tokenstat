#!/usr/bin/env bash
#
# The Windows host pipe opens asynchronously and never sets ReadTimeout.
#
# Named pipes report CanTimeout false even when opened asynchronously, so
# ReadTimeout always throws InvalidOperationException ("Timeouts are not
# supported on this stream."). HostClient therefore bounds its read with
# WaitAsync instead. Setting ReadTimeout breaks every host call: the app
# then reads the failure as a version mismatch and restarts a healthy
# helper.
#
# Fails on:
#   - no PipeOptions.Asynchronous in HostClient.cs
#   - a non-comment PipeOptions.None in HostClient.cs
#   - a non-comment ReadTimeout in HostClient.cs
set -euo pipefail
cd "$(dirname "$0")/.."

CLIENT="apps/windows/Host/HostClient.cs"
fail=0

if ! grep -q "PipeOptions\.Asynchronous" "$CLIENT"; then
    echo "$CLIENT: the host pipe must open with PipeOptions.Asynchronous (the read uses ReadLineAsync)"
    fail=1
fi

# Comment lines are skipped, so a comment may name a banned API while
# explaining why it is banned. A real call is never a comment.
hits=$(grep -rnH "PipeOptions\.None" "$CLIENT" | grep -v ':[0-9][0-9]*: *//' || true)
if [ -n "$hits" ]; then
    echo "$hits"
    echo "$CLIENT: a synchronously-opened pipe cannot do async reads well (see above)"
    fail=1
fi

hits=$(grep -rnH "ReadTimeout" "$CLIENT" | grep -v ':[0-9][0-9]*: *//' || true)
if [ -n "$hits" ]; then
    echo "$hits"
    echo "$CLIENT: ReadTimeout always throws on a named pipe (see above)"
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "The Windows host pipe supports timeouts."
fi
exit "$fail"
