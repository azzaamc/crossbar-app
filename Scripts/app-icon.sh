#!/bin/bash
#
# Installs app icon artwork into Crossbar's icon set.
#
# The catalog is fussier than it looks. iOS 18 asks for three 1024x1024 slots — Any, Dark
# and Tinted — and they are **not** the same kind of image, per Apple's own guidance:
#
#   Any     a full-bleed square, opaque. The system applies the rounded mask itself, so a
#           baked-in corner radius is wrong, and transparency here is rejected by the App
#           Store. (The Family Call PWA's icon has both, which is why it cannot be reused
#           as-is.)
#   Dark    same shape, but *with* a transparent background, so the system-provided
#           background shows through.
#   Tinted  a grayscale image; the system applies the tint.
#
# A file the catalog references but cannot find fails the build with a message that does
# not name the missing file, so this validates before it writes anything.
#
#   Scripts/app-icon.sh install <any-1024.png> [dark-1024.png] [tinted-1024.png]
#
# Dark and tinted are optional: the interface wants all three, but iOS falls back to the
# Any artwork for any appearance it has no image for, so one file is a working start.
set -euo pipefail

CATALOG="$(cd "$(dirname "$0")/.." && pwd)/Crossbar/Assets.xcassets/AppIcon.appiconset"
REQUIRED=1024

die() { printf 'app-icon: %s\n' "$1" >&2; exit 1; }
note() { printf 'app-icon: %s\n' "$1"; }

check() {
    local file="$1" role="$2"
    [ -f "$file" ] || die "$role: no such file: $file"
    file "$file" | grep -q 'PNG image data' || die "$role: not a PNG — an app icon image well takes PNG ($file)"

    local props width height alpha space
    props="$(sips -g pixelWidth -g pixelHeight -g hasAlpha -g space "$file" 2>/dev/null)" \
        || die "$role: sips could not read $file"
    width="$(awk '/pixelWidth/{print $2}' <<<"$props")"
    height="$(awk '/pixelHeight/{print $2}' <<<"$props")"
    alpha="$(awk '/hasAlpha/{print $2}' <<<"$props")"
    space="$(awk '/space/{print $2}' <<<"$props")"

    [ "$width" = "$REQUIRED" ] && [ "$height" = "$REQUIRED" ] \
        || die "$role: must be ${REQUIRED}x${REQUIRED}, this is ${width}x${height}"

    case "$role" in
        any)
            [ "$alpha" = "no" ] || die "$role: has transparency — the App Store rejects an app icon with it, and iOS masks the corners itself"
            ;;
        dark)
            [ "$alpha" = "yes" ] || note "$role: warning — Apple asks for a transparent background on the dark variant so the system background shows through"
            ;;
        tinted)
            [ "$space" = "Gray" ] || note "$role: warning — Apple asks for a grayscale image here and the system tints it; this one reports $space"
            ;;
    esac
    note "$role: ${width}x${height}, alpha=$alpha, space=$space — fine"
}

[ $# -ge 2 ] || die "usage: Scripts/app-icon.sh install <any.png> [dark.png] [tinted.png]"
[ "$1" = "install" ] || die "unknown command: $1 (only 'install' exists)"
shift

ANY_PNG="$1"; DARK_PNG="${2:-}"; TINTED_PNG="${3:-}"
check "$ANY_PNG" any
[ -n "$DARK_PNG" ] && check "$DARK_PNG" dark
[ -n "$TINTED_PNG" ] && check "$TINTED_PNG" tinted

mkdir -p "$CATALOG"
rm -f "$CATALOG"/icon-1024*.png
cp "$ANY_PNG" "$CATALOG/icon-1024.png"
[ -n "$DARK_PNG" ] && cp "$DARK_PNG" "$CATALOG/icon-1024-dark.png"
[ -n "$TINTED_PNG" ] && cp "$TINTED_PNG" "$CATALOG/icon-1024-tinted.png"

# Written rather than hand-edited: every slot that has a file needs a `filename` key, and
# every slot without one must not have the key at all.
python3 - "$CATALOG" "$DARK_PNG" "$TINTED_PNG" <<'PY'
import json, os, sys
catalog, dark, tinted = sys.argv[1], sys.argv[2], sys.argv[3]

def slot(filename, appearance=None):
    image = {"idiom": "universal", "platform": "ios", "size": "1024x1024"}
    if appearance:
        image["appearances"] = [{"appearance": "luminosity", "value": appearance}]
    if filename:
        image["filename"] = filename
    return image

images = [
    slot("icon-1024.png"),
    slot("icon-1024-dark.png" if dark else None, "dark"),
    slot("icon-1024-tinted.png" if tinted else None, "tinted"),
]
with open(os.path.join(catalog, "Contents.json"), "w") as handle:
    json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, handle, indent=2)
    handle.write("\n")
PY

note "installed into $(basename "$CATALOG")"
note "the catalog now holds: $(cd "$CATALOG" && ls -1 | tr '\n' ' ')"
note "to see it at the sizes the system uses, build and install, then look at the Home Screen"
