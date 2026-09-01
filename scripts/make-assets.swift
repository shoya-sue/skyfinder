#!/usr/bin/env swift
// G0-4 / §15.3: docs/design/ の原本から Assets.xcassets の派生物を生成する。
// 手作業で切り出さない — 原本を差し替えても同じ手順で再生成できることが要件（§8.6 の冪等性）。
// 依存は macOS 標準フレームワークのみ。
//
// 生成物:
//   AppIcon.appiconset         … A-01 / A-02 / A-03
//   MenuBarIcon.imageset       … A-04 / A-06（16-18pt 用の簡略版。原本からの縮小では潰れる）
//   Logo.imageset              … A-05（透過 + Light/Dark）
//   BrandColor / PublicWarningColor  … §15.2.2

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - 経路

let repoRoot = URL(fileURLWithPath: CommandLine.arguments.count > 1
                   ? CommandLine.arguments[1]
                   : FileManager.default.currentDirectoryPath)
let designDir = repoRoot.appendingPathComponent("docs/design")
let assetsDir = repoRoot.appendingPathComponent("SkyFolder/Assets.xcassets")

func fail(_ m: String) -> Never { FileHandle.standardError.write(Data(("[make-assets] " + m + "\n").utf8)); exit(1) }
func log(_ m: String) { print("[make-assets] " + m) }

// MARK: - 画像入出力

func loadImage(_ url: URL) -> CGImage {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("読めない: \(url.path)") }
    return img
}

func writePNG(_ image: CGImage, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fail("書けない: \(url.path)") }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) { fail("PNG 書き出しに失敗: \(url.path)") }
}

func newContext(_ w: Int, _ h: Int) -> CGContext {
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fail("CGContext を作れない") }
    ctx.interpolationQuality = .high
    return ctx
}

// MARK: - 原本の描画領域を自動検出
// 背景 #EFEFEF は意匠ではなく焼き込まれた背景（§15.2.2）。位置を決め打ちしないのは、
// 原本が差し替わっても同じスクリプトで動くようにするため。

struct RGBA { var r, g, b, a: UInt8 }

final class Bitmap {
    let w: Int, h: Int
    private let px: UnsafeMutablePointer<UInt8>
    init(_ image: CGImage) {
        w = image.width; h = image.height
        px = .allocate(capacity: w * h * 4)
        px.initialize(repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    deinit { px.deallocate() }
    func at(_ x: Int, _ y: Int) -> RGBA {
        let o = (y * w + x) * 4
        return RGBA(r: px[o], g: px[o + 1], b: px[o + 2], a: px[o + 3])
    }
}

let bgR: Int = 0xEF, bgG: Int = 0xEF, bgB: Int = 0xEF
let bgTolerance = 10

func isBackground(_ c: RGBA) -> Bool {
    abs(Int(c.r) - bgR) <= bgTolerance && abs(Int(c.g) - bgG) <= bgTolerance && abs(Int(c.b) - bgB) <= bgTolerance
}

/// 背景色でない領域の外接矩形（画像座標・原点は左上）
func contentBBox(_ bmp: Bitmap) -> (x: Int, y: Int, w: Int, h: Int) {
    var minX = bmp.w, minY = bmp.h, maxX = -1, maxY = -1
    for y in 0..<bmp.h {
        for x in 0..<bmp.w where !isBackground(bmp.at(x, y)) {
            if x < minX { minX = x }; if x > maxX { maxX = x }
            if y < minY { minY = y }; if y > maxY { maxY = y }
        }
    }
    guard maxX >= minX, maxY >= minY else { fail("描画領域を検出できない（背景色の想定が違う可能性）") }
    return (minX, minY, maxX - minX + 1, maxY - minY + 1)
}

func crop(_ image: CGImage, _ box: (x: Int, y: Int, w: Int, h: Int)) -> CGImage {
    guard let c = image.cropping(to: CGRect(x: box.x, y: box.y, width: box.w, height: box.h))
    else { fail("切り出しに失敗") }
    return c
}

// MARK: - A-01 / A-02 / A-03  AppIcon

// macOS 11〜15 のアイコングリッド: 1024 のキャンバスに 824 の角丸正方形、半径 185.4。
// deployment target が macOS 14 なので、この従来方式で描く（G0-5 の判断・docs/design/README.md に記録）。
let canvas = 1024.0
let bodySide = 824.0
let bodyInset = (canvas - bodySide) / 2.0    // 100
let cornerRadius = 185.4

func makeAppIconMaster(from artwork: CGImage) -> CGImage {
    let ctx = newContext(Int(canvas), Int(canvas))
    ctx.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
    let body = CGRect(x: bodyInset, y: bodyInset, width: bodySide, height: bodySide)
    let path = CGPath(roundedRect: body, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.addPath(path)
    ctx.clip()
    // 原本の実描画領域を body いっぱいに引き伸ばす（A-01: 903px → 824px は縮小なので劣化しない）
    ctx.draw(artwork, in: body)
    guard let out = ctx.makeImage() else { fail("AppIcon マスターを生成できない") }
    return out
}

func resize(_ image: CGImage, _ side: Int) -> CGImage {
    let ctx = newContext(side, side)
    ctx.clear(CGRect(x: 0, y: 0, width: side, height: side))
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    guard let out = ctx.makeImage() else { fail("リサイズに失敗 (\(side))") }
    return out
}

// MARK: - A-04 / A-06  小サイズ用の簡略版グリフ
//
// M-10（実測）: 原本の線画は 16px で完全に潰れる。線を太らせ要素を減らした別版が要る。
// 原本どおりの「フォルダ + 雲 + 矢印 + 表情」ではなく、
// 塗りのフォルダから上向き矢印を抜いた形にする（16px でも輪郭が残る）。
// テンプレート画像なので色は持たせない（不透明度だけが意味を持つ）。

func folderPath(_ s: CGFloat) -> CGPath {
    func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
    // 左上にタブが飛び出したフォルダ。本体の上辺(y=70)より上にタブ(y=80)を出すことで、
    // 16px でも「角丸長方形」ではなく「フォルダ」に見える。
    let p = CGMutablePath()
    let body = CGPath(roundedRect: CGRect(x: 8 * s, y: 14 * s, width: 84 * s, height: 56 * s),
                      cornerWidth: 8 * s, cornerHeight: 8 * s, transform: nil)
    p.addPath(body)
    let tab = CGMutablePath()
    tab.move(to: P(8, 60))
    tab.addLine(to: P(8, 74))
    tab.addCurve(to: P(14, 80), control1: P(8, 78), control2: P(10, 80))
    tab.addLine(to: P(36, 80))
    tab.addLine(to: P(46, 70))
    tab.addLine(to: P(46, 60))
    tab.closeSubpath()
    p.addPath(tab)
    return p
}

func arrowPath(_ s: CGFloat) -> CGPath {
    func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
    let p = CGMutablePath()
    p.addRect(CGRect(x: 42 * s, y: 20 * s, width: 16 * s, height: 22 * s))
    let head = CGMutablePath()
    head.move(to: P(50, 60))
    head.addLine(to: P(28, 40))
    head.addLine(to: P(72, 40))
    head.closeSubpath()
    p.addPath(head)
    return p
}

/// テンプレート画像用: 塗りのフォルダから上向き矢印を抜く（色は持たせない）
func drawGlyph(into ctx: CGContext, side: CGFloat) {
    let s = side / 100.0
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    ctx.addPath(folderPath(s))
    ctx.fillPath()
    ctx.saveGState()
    ctx.setBlendMode(.clear)
    ctx.addPath(arrowPath(s))
    ctx.fillPath()
    ctx.restoreGState()
}

/// A-04: 16pt の AppIcon 用。原本の線画は 16px で潰れる（M-10）ので、
/// ブランド色のタイルに白のグリフを載せた別版を使う。
func makeSmallAppIcon(_ side: Int) -> CGImage {
    let ctx = newContext(side, side)
    ctx.clear(CGRect(x: 0, y: 0, width: side, height: side))
    let f = CGFloat(side)
    // AppIcon と同じグリッド比（824/1024・半径 185.4/1024）
    let inset = f * (bodyInset / canvas)
    let body = CGRect(x: inset, y: inset, width: f - inset * 2, height: f - inset * 2)
    ctx.addPath(CGPath(roundedRect: body,
                       cornerWidth: f * (cornerRadius / canvas),
                       cornerHeight: f * (cornerRadius / canvas), transform: nil))
    ctx.clip()
    ctx.setFillColor(CGColor(red: 0x5D / 255.0, green: 0xA7 / 255.0, blue: 0xE4 / 255.0, alpha: 1))
    ctx.fill(body)
    // グリフを白で、タイルの内側に少し縮めて描く
    ctx.saveGState()
    let g = body.insetBy(dx: body.width * 0.10, dy: body.height * 0.10)
    ctx.translateBy(x: g.minX, y: g.minY)
    let gs = g.width / 100.0
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.addPath(folderPath(gs))
    ctx.fillPath()
    ctx.setBlendMode(.clear)
    ctx.addPath(arrowPath(gs))
    ctx.fillPath()
    ctx.restoreGState()
    guard let out = ctx.makeImage() else { fail("小サイズ AppIcon を生成できない (\(side))") }
    return out
}

func makeGlyph(_ side: Int) -> CGImage {
    let ctx = newContext(side, side)
    ctx.clear(CGRect(x: 0, y: 0, width: side, height: side))
    drawGlyph(into: ctx, side: CGFloat(side))
    guard let out = ctx.makeImage() else { fail("グリフを生成できない (\(side))") }
    return out
}

// MARK: - A-05  ロゴの透過版（Light / Dark）
//
// ロゴは #EFEFEF の上の濃いグレー文字。単純な色抜きだと縁がギザつくので、
// 「背景からの暗さ」をそのままアルファに写す（アンチエイリアスが保たれる）。

func makeLogo(from bmp: Bitmap, box: (x: Int, y: Int, w: Int, h: Int),
              ink: (r: UInt8, g: UInt8, b: UInt8)) -> CGImage {
    let w = box.w, h = box.h
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let bgLuma = 0.299 * Double(bgR) + 0.587 * Double(bgG) + 0.114 * Double(bgB)
    for y in 0..<h {
        for x in 0..<w {
            let c = bmp.at(box.x + x, box.y + y)
            let luma = 0.299 * Double(c.r) + 0.587 * Double(c.g) + 0.114 * Double(c.b)
            // 背景と同じ明るさ → 透明、暗いほど不透明
            let alpha = max(0.0, min(1.0, (bgLuma - luma) / bgLuma))
            let a = UInt8((alpha * 255).rounded())
            let o = (y * w + x) * 4
            // premultipliedLast
            buf[o]     = UInt8((Double(ink.r) * alpha).rounded())
            buf[o + 1] = UInt8((Double(ink.g) * alpha).rounded())
            buf[o + 2] = UInt8((Double(ink.b) * alpha).rounded())
            buf[o + 3] = a
        }
    }
    let provider = CGDataProvider(data: Data(buf) as CFData)!
    guard let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    else { fail("ロゴを生成できない") }
    return img
}

// MARK: - Assets.xcassets の書き出し

func write(_ text: String, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! text.data(using: .utf8)!.write(to: url)
}

let infoBlock = #"""
  "info" : { "author" : "make-assets.swift", "version" : 1 }
"""#

// ---- 実行 ----

let iconSrcURL = designDir.appendingPathComponent("icon.jpeg")
let logoSrcURL = designDir.appendingPathComponent("logo.jpeg")
guard FileManager.default.fileExists(atPath: iconSrcURL.path) else { fail("原本がない: \(iconSrcURL.path)") }
guard FileManager.default.fileExists(atPath: logoSrcURL.path) else { fail("原本がない: \(logoSrcURL.path)") }

// --- AppIcon ---
let iconImage = loadImage(iconSrcURL)
let iconBmp = Bitmap(iconImage)
let iconBox = contentBBox(iconBmp)
log("icon.jpeg 実描画領域: origin=(\(iconBox.x),\(iconBox.y)) size=\(iconBox.w)x\(iconBox.h)")
let artwork = crop(iconImage, iconBox)
let master = makeAppIconMaster(from: artwork)

let appIconDir = assetsDir.appendingPathComponent("AppIcon.appiconset")
try? FileManager.default.removeItem(at: appIconDir)

// macOS の AppIcon は 16/32/128/256/512 pt の @1x/@2x を要求する
let macIconSizes: [(pt: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)
]
var appIconEntries: [String] = []
for (pt, scale) in macIconSizes {
    let px = pt * scale
    let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
    // M-10（実測）: 原本の線画は 16px で完全に潰れる。16px の枠だけ簡略版を使う。
    // 32px 以上は原本からの縮小で判別できることも実測済み。
    let image = px <= 16 ? makeSmallAppIcon(px) : resize(master, px)
    writePNG(image, to: appIconDir.appendingPathComponent(name))
    appIconEntries.append("""
        {
          "filename" : "\(name)",
          "idiom" : "mac",
          "scale" : "\(scale)x",
          "size" : "\(pt)x\(pt)"
        }
    """)
}
write("""
{
  "images" : [
\(appIconEntries.joined(separator: ",\n"))
  ],
\(infoBlock)
}
""", to: appIconDir.appendingPathComponent("Contents.json"))
log("AppIcon.appiconset: \(macIconSizes.count) 枚")

// --- MenuBarIcon（テンプレート・A-04 / A-06）---
let menuDir = assetsDir.appendingPathComponent("MenuBarIcon.imageset")
try? FileManager.default.removeItem(at: menuDir)
writePNG(makeGlyph(18), to: menuDir.appendingPathComponent("menubar_18.png"))
writePNG(makeGlyph(36), to: menuDir.appendingPathComponent("menubar_18@2x.png"))
write("""
{
  "images" : [
    { "filename" : "menubar_18.png", "idiom" : "mac", "scale" : "1x" },
    { "filename" : "menubar_18@2x.png", "idiom" : "mac", "scale" : "2x" }
  ],
\(infoBlock),
  "properties" : { "template-rendering-intent" : "template" }
}
""", to: menuDir.appendingPathComponent("Contents.json"))
log("MenuBarIcon.imageset: テンプレート 18pt @1x/@2x")

// --- Logo（A-05・Light / Dark）---
let logoImage = loadImage(logoSrcURL)
let logoBmp = Bitmap(logoImage)
let logoBox = contentBBox(logoBmp)
log("logo.jpeg 実描画領域: origin=(\(logoBox.x),\(logoBox.y)) size=\(logoBox.w)x\(logoBox.h)")

let logoDir = assetsDir.appendingPathComponent("Logo.imageset")
try? FileManager.default.removeItem(at: logoDir)
// Light: 原本の文字色 #555352 / Dark: 明るいグレー #E8E8EA
writePNG(makeLogo(from: logoBmp, box: logoBox, ink: (0x55, 0x53, 0x52)),
         to: logoDir.appendingPathComponent("logo_light.png"))
writePNG(makeLogo(from: logoBmp, box: logoBox, ink: (0xE8, 0xE8, 0xEA)),
         to: logoDir.appendingPathComponent("logo_dark.png"))
write("""
{
  "images" : [
    { "filename" : "logo_light.png", "idiom" : "mac", "scale" : "1x" },
    { "filename" : "logo_dark.png", "idiom" : "mac", "scale" : "1x",
      "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ] }
  ],
\(infoBlock),
  "properties" : { "template-rendering-intent" : "original" }
}
""", to: logoDir.appendingPathComponent("Contents.json"))
log("Logo.imageset: Light / Dark")

// --- 色（§15.2.2）---
func writeColorSet(_ name: String, hex: (r: Int, g: Int, b: Int)) {
    let dir = assetsDir.appendingPathComponent("\(name).colorset")
    write("""
    {
      "colors" : [
        {
          "color" : {
            "color-space" : "srgb",
            "components" : {
              "alpha" : "1.000",
              "blue" : "0x\(String(format: "%02X", hex.b))",
              "green" : "0x\(String(format: "%02X", hex.g))",
              "red" : "0x\(String(format: "%02X", hex.r))"
            }
          },
          "idiom" : "universal"
        }
      ],
    \(infoBlock)
    }
    """, to: dir.appendingPathComponent("Contents.json"))
}
// 青 = プロダクトのアイデンティティ / オレンジ = 「公開」という危険側の警告（§15.2.2 CAUTION）
writeColorSet("BrandColor", hex: (0x5D, 0xA7, 0xE4))
writeColorSet("PublicWarningColor", hex: (0xE8, 0x71, 0x0A))
writeColorSet("AccentColor", hex: (0x5D, 0xA7, 0xE4))
log("色: BrandColor #5DA7E4 / PublicWarningColor #E8710A / AccentColor")

// --- カタログのルート ---
write("""
{
\(infoBlock)
}
""", to: assetsDir.appendingPathComponent("Contents.json"))

log("完了")
