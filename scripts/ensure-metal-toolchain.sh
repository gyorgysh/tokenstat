#!/bin/sh
# The new chat page's surface is a Metal fragment shader, so the app bundle
# carries a compiled default.metallib and every build of it needs the `metal`
# compiler. Xcode 26 moved that compiler out of the stock install into a
# downloadable component, so a fresh Mac and a fresh CI runner both have to
# fetch it once. The download is a few hundred megabytes and is cached by
# Xcode, so this is a no-op on every build after the first.
#
# Probing with a real compile rather than `xcrun -f metal`: the tool is on
# PATH whether or not the component is installed, and only fails when asked
# to do something.
set -eu

probe=$(mktemp -d)
trap 'rm -rf "$probe"' EXIT
printf '#include <metal_stdlib>\nkernel void probe() {}\n' > "$probe/probe.metal"
if xcrun metal -c "$probe/probe.metal" -o "$probe/probe.air" >/dev/null 2>&1; then
    exit 0
fi

echo "Downloading the Metal toolchain"
xcodebuild -downloadComponent MetalToolchain
