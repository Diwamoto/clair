#!/usr/bin/env bash
# Usage: make-icns.sh ART.png OUT.icns — masks the art to the macOS app-icon grid and writes an .icns.
set -euo pipefail
icon_png="$1" out="$2"
iconset="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$iconset"
# Same macOS-grid mask as ClairMacApp.appIcon(): 824pt body, 185pt corners on a 1024 canvas.
swift - "$icon_png" "$iconset/icon_512x512@2x.png" <<'SWIFT'
import AppKit
let a = CommandLine.arguments, art = NSImage(contentsOfFile: a[1])!
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
  hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let r = NSRect(x: 100, y: 100, width: 824, height: 824)
NSBezierPath(roundedRect: r, xRadius: 185, yRadius: 185).addClip()
art.draw(in: r)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
SWIFT
for s in 16 32 128 256 512; do
    sips -z $s $s "$iconset/icon_512x512@2x.png" --out "$iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$iconset/icon_512x512@2x.png" --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$out"
rm -rf "$(dirname "$iconset")"
