#!/bin/sh
#
# Builds TailscaleKit.xcframework for iOS device and simulator, and installs it
# into Vendor/ for the Xcode project to embed and sign.
#
# TailscaleKit is Tailscale's BSD-3-Clause wrapper around libtailscale, which is
# tsnet (Go) compiled to a C archive. The upstream source is deliberately NOT
# vendored into this repository: it is a large tree that is pinned by commit, not
# by copy, and copying it here would obscure which revision is in the binary.
# Point this script at a checkout with LIBTAILSCALE_SRC.
#
# The output is roughly 70 MB of binaries, so Vendor/ is gitignored. A fresh
# clone of this branch does not build until this script has been run once.

set -e

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIBTAILSCALE_SRC=${LIBTAILSCALE_SRC:-"$REPO_ROOT/../tailscale-spike/libtailscale"}
SWIFT_DIR="$LIBTAILSCALE_SRC/swift"
PRODUCTS="$SWIFT_DIR/build/Build/Products/Release-iphonefat/TailscaleKit.xcframework"
OUT="$REPO_ROOT/Vendor/TailscaleKit.xcframework"

if [ ! -d "$SWIFT_DIR" ]; then
    echo "error: no libtailscale checkout at $LIBTAILSCALE_SRC" >&2
    echo "set LIBTAILSCALE_SRC to a checkout of github.com/tailscale/libtailscale" >&2
    exit 1
fi

# Some Go 1.27 toolchains ship the json/v2 experiment enabled; libtailscale's
# dependency graph does not build under it, and the failure surfaces as unrelated
# errors deep in encoding/json.
export GOEXPERIMENT=${GOEXPERIMENT:-nojsonv2}

echo "::: building from $LIBTAILSCALE_SRC (GOEXPERIMENT=$GOEXPERIMENT)"

# `make ios-fat` ends by assembling the .xcframework with
# `xcodebuild -create-xcframework`, which under Xcode 27 exits 70 reporting
#
#   "TailscaleKit.framework" couldn't be copied to
#   "ios-arm64_x86_64-simulator" because an item with the same name already exists
#
# *after* having written a complete, correct framework. The exit code is therefore
# not trustworthy here, so the artifact is validated below instead: a real failure
# still stops the script, and this cosmetic one does not.
make -C "$SWIFT_DIR" ios-fat || true

echo "::: validating $PRODUCTS"
if [ ! -f "$PRODUCTS/Info.plist" ] || ! plutil -lint "$PRODUCTS/Info.plist" >/dev/null; then
    echo "error: $PRODUCTS is not a valid xcframework" >&2
    exit 1
fi

# The device slice is the one that ships; the simulator slice keeps dev builds working.
for slice in ios-arm64 ios-arm64_x86_64-simulator; do
    slice_binary="$PRODUCTS/$slice/TailscaleKit.framework/TailscaleKit"
    if [ ! -f "$slice_binary" ]; then
        echo "error: xcframework is missing the $slice slice" >&2
        exit 1
    fi
done

echo "::: installing into $OUT"
mkdir -p "$REPO_ROOT/Vendor"
rm -rf "$OUT"
# ditto rather than cp: an .xcframework contains symlinks and extended
# attributes, and cp does not preserve them reliably.
ditto "$PRODUCTS" "$OUT"

echo "::: done"
echo "$OUT"
