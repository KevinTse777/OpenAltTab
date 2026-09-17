#!/bin/bash
# 生成 AppIcon.icns（纯代码绘制，无需外部素材）
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/icon

cat > .build/icon/make_icon.swift <<'SWIFT'
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// 深色圆角背景
let bg = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 210, yRadius: 210)
NSGradient(colors: [NSColor(red: 0.17, green: 0.20, blue: 0.30, alpha: 1),
                    NSColor(red: 0.05, green: 0.06, blue: 0.11, alpha: 1)])?
    .draw(in: bg, angle: -90)

func drawWindow(_ rect: NSRect, _ border: NSColor, _ fill: NSColor) {
    let path = NSBezierPath(roundedRect: rect, xRadius: 28, yRadius: 28)
    fill.setFill()
    path.fill()
    border.setStroke()
    path.lineWidth = 14
    path.stroke()
    let bar = NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.maxY - 56,
                                               width: rect.width, height: 56),
                           xRadius: 28, yRadius: 28)
    bar.append(NSBezierPath(rect: NSRect(x: rect.minX, y: rect.maxY - 56,
                                         width: rect.width, height: 28)))
    NSColor.white.withAlphaComponent(0.10).setFill()
    bar.fill()
}

// 层叠的两个窗口，前面的带主题色描边
drawWindow(NSRect(x: 380, y: 430, width: 470, height: 320),
           NSColor.white.withAlphaComponent(0.30), NSColor.white.withAlphaComponent(0.12))
drawWindow(NSRect(x: 175, y: 275, width: 470, height: 320),
           NSColor.controlAccentColor, NSColor.white.withAlphaComponent(0.18))

// ⌥ 符号
let para = NSMutableParagraphStyle()
para.alignment = .center
"⌥".draw(in: NSRect(x: 175, y: 300, width: 470, height: 270), withAttributes: [
    .font: NSFont.systemFont(ofSize: 230, weight: .bold),
    .foregroundColor: NSColor.white,
    .paragraphStyle: para,
])

image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: ".build/icon/AppIcon1024.png"))
print("icon png done")
SWIFT

swift .build/icon/make_icon.swift

ICONSET=".build/icon/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
SRC=".build/icon/AppIcon1024.png"
sips -z 16 16   "$SRC" --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z 32 32   "$SRC" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32 32   "$SRC" --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z 64 64   "$SRC" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128 128 "$SRC" --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256 256 "$SRC" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$SRC" --out "$ICONSET/icon_256x256.png"    >/dev/null
sips -z 512 512 "$SRC" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$SRC" --out "$ICONSET/icon_512x512.png"    >/dev/null
sips -z 1024 1024 "$SRC" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o ".build/icon/AppIcon.icns"
echo "AppIcon.icns done"
