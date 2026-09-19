#!/bin/bash
#
# Checks and installs app icon artwork for Crossbar's icon set.
#
#   Scripts/app-icon.sh check                      # validate what the catalog holds now
#   Scripts/app-icon.sh install <any.png> [dark.png] [tinted.png]
#
# The catalog is fussier than it looks. iOS 18 asks for three 1024x1024 slots — Any, Dark
# and Tinted — and they are **not** the same kind of image, per Apple's guidance
# ("Configuring your app icon using an asset catalog"):
#
#   Any     a full-bleed square, opaque. The system applies the rounded mask itself, so a
#           baked-in corner radius is wrong, and the App Store rejects transparency here.
#   Dark    the same shape, but *with* a transparent background, so the system-provided
#           background shows through.
#   Tinted  a grayscale image; the system applies the tint.
#
# Size and the Any slot's opacity are hard failures. The other two are reported as
# warnings, because an opaque dark icon still renders (it just loses the system
# background) and a grey-looking RGB image is fine in practice even though its colour
# space is not literally Gray.
#
# A file the catalog references but cannot find fails the build with a message that never
# names the file, which is why this checks before it writes.
set -euo pipefail

CATALOG="$(cd "$(dirname "$0")/.." && pwd)/Crossbar/Assets.xcassets/AppIcon.appiconset"
REQUIRED=1024

die() { printf 'app-icon: %s\n' "$1" >&2; exit 1; }
note() { printf 'app-icon: %s\n' "$1"; }

# Returns 0 when the file satisfies the rules for its slot. Says why either way.
check() {
    local file="$1" role="$2"
    [ -f "$file" ] || { note "$role: MISSING — no such file: $file"; return 1; }
    file "$file" | grep -q 'PNG image data' || { note "$role: not a PNG — the image well takes PNG"; return 1; }

    local props width height alpha space
    props="$(sips -g pixelWidth -g pixelHeight -g hasAlpha -g space "$file" 2>/dev/null)" \
        || { note "$role: sips could not read this file"; return 1; }
    width="$(awk '/pixelWidth/{print $2}' <<<"$props")"
    height="$(awk '/pixelHeight/{print $2}' <<<"$props")"
    alpha="$(awk '/hasAlpha/{print $2}' <<<"$props")"
    space="$(awk '/space/{print $2}' <<<"$props")"

    local failed=0
    if [ "$width" != "$REQUIRED" ] || [ "$height" != "$REQUIRED" ]; then
        note "$role: size is ${width}x${height}, must be ${REQUIRED}x${REQUIRED}"
        failed=1
    fi

    case "$role" in
        any)
            [ "$alpha" = "no" ] || {
                note "$role: has transparency — the App Store rejects an icon with it, and iOS applies the corner mask itself"
                failed=1
            }
            ;;
        dark)
            [ "$alpha" = "yes" ] \
                || note "$role: warning — Apple asks for a transparent background on the dark variant so the system background shows through"
            ;;
        tinted)
            [ "$space" = "Gray" ] \
                || note "$role: warning — Apple asks for a grayscale image here and the system tints it; this one reports $space"
            ;;
    esac

    [ "$failed" -eq 0 ] && note "$role: ok (${width}x${height}, alpha=$alpha, space=$space)"
    return "$failed"
}

check_catalog() {
    [ -f "$CATALOG/Contents.json" ] || die "no Contents.json at $CATALOG"
    local failures=0
    while IFS=$'\t' read -r role filename; do
        printf '\n'
        if [ -z "$filename" ]; then
            note "$role: no artwork — iOS falls back to the Any icon for this appearance"
            continue
        fi
        note "$role: $filename"
        check "$CATALOG/$filename" "$role" || failures=$((failures + 1))
    done < <(python3 - "$CATALOG" <<'PY'
import json, os, sys
data = json.load(open(os.path.join(sys.argv[1], "Contents.json")))
for image in data.get("images", []):
    values = [a.get("value") for a in image.get("appearances", [])]
    role = "dark" if "dark" in values else "tinted" if "tinted" in values else "any"
    print(f"{role}\t{image.get('filename', '')}")
PY
)
    printf '\n'
    [ "$failures" -eq 0 ] || die "$failures slot(s) do not fit — fix those before building"
    note "every filled slot fits"
}

install() {
    local any="$1" dark="${2:-}" tinted="${3:-}"
    printf '\n'
    check "$any" any || die "the Any artwork does not fit its slot (see above)"
    [ -n "$dark" ] && { check "$dark" dark || true; }
    [ -n "$tinted" ] && { check "$tinted" tinted || true; }

    mkdir -p "$CATALOG"
    rm -f "$CATALOG"/*-1024@1x.png "$CATALOG"/icon-1024*.png
    cp "$any" "$CATALOG/Crossbar-iOS-Default-1024@1x.png"
    [ -n "$dark" ] && cp "$dark" "$CATALOG/Crossbar-iOS-Dark-1024@1x.png"
    [ -n "$tinted" ] && cp "$tinted" "$CATALOG/Crossbar-iOS-TintedDark-1024@1x.png"

    # Written rather than hand-edited: a slot with a file needs a `filename` key, and a
    # slot without one must not have it at all.
    python3 - "$CATALOG" "$dark" "$tinted" <<'PY'
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
    slot("Crossbar-iOS-Default-1024@1x.png"),
    slot("Crossbar-iOS-Dark-1024@1x.png" if dark else None, "dark"),
    slot("Crossbar-iOS-TintedDark-1024@1x.png" if tinted else None, "tinted"),
]
with open(os.path.join(catalog, "Contents.json"), "w") as handle:
    json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, handle, indent=2)
    handle.write("\n")
PY

    printf '\n'
    note "installed into $(basename "$CATALOG")"
    check_catalog
}

case "${1:-}" in
    check) check_catalog ;;
    install)
        [ $# -ge 2 ] || die "usage: Scripts/app-icon.sh install <any.png> [dark.png] [tinted.png]"
        shift
        install "$@"
        ;;
    *) die "usage: Scripts/app-icon.sh check | install <any.png> [dark.png] [tinted.png]" ;;
esac
