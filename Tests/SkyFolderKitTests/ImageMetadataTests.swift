import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import SkyFolderKit

@Suite("公開前の画像メタデータ除去（§7.4 / SEC-G03 / G-06）")
struct ImageMetadataStripperTests {

    private let stripper = ImageMetadataStripper()

    // MARK: - 対象判定

    @Test("対象拡張子は大小文字を問わない", arguments: [
        "a.jpg", "a.JPEG", "a.PNG", "a.tiff", "a.HEIC", "a.webp",
    ])
    func targetsImageExtensions(name: String) {
        #expect(ImageMetadataStripper.isTargetFile(URL(fileURLWithPath: "/tmp/\(name)")))
    }

    @Test("対象外の拡張子は無加工", arguments: ["a.pdf", "a.txt", "a.mp4", "a"])
    func ignoresNonImages(name: String) {
        #expect(!ImageMetadataStripper.isTargetFile(URL(fileURLWithPath: "/tmp/\(name)")))
    }

    // MARK: - T-G21

    /// GPS・撮影日時・機材タグが存在しないこと。
    /// **Orientation と ICC プロファイルは保持されていること**（DD-001 F-16: 剥がすと横倒し・色崩れ）。
    /// 手元の原本の Exif は残っていること。
    @Test("T-G21: GPS / Exif / 機材タグを除去し、Orientation と ICC を保持する")
    func stripsGPSButKeepsOrientationAndICC() throws {
        let dir = TestSupport.makeTemporaryDirectory("exif")
        defer { TestSupport.remove(dir) }
        let original = dir.appendingPathComponent("photo.jpg")
        try Self.writeJPEGWithMetadata(to: original)

        // 原本にはメタデータが載っていること（テストの前提が成立しているかの確認）
        let before = stripper.inspect(original)
        #expect(before.hasGPS, "テスト用画像に GPS が入っていない")
        #expect(before.hasExif, "テスト用画像に Exif が入っていない")
        #expect(before.hasIPTC)
        #expect(before.hasCameraTags)
        #expect(before.orientation == 6)

        let stripped = try stripper.strip(original, into: dir)
        let after = stripper.inspect(stripped)

        // 識別情報が 1 つも残っていないこと
        #expect(!after.hasIdentifyingMetadata, "残存: \(after.identifyingKeys)")
        #expect(!after.hasGPS)
        #expect(!after.hasExif)
        #expect(!after.hasIPTC)
        #expect(!after.hasCameraTags)

        // 保持されたこと（必須要件・DD-001 F-16）
        #expect(after.orientation == 6, "Orientation が失われた（DD-001 F-16）")
        #expect(after.hasICCProfile, "ICC プロファイルが失われた（DD-001 F-16）")

        // 原本は変更しない（同じディレクトリを渡しても上書きされないこと）
        let originalAfter = stripper.inspect(original)
        #expect(originalAfter.hasGPS, "原本の Exif を書き換えてはならない")
        #expect(originalAfter.hasExif)
        #expect(originalAfter.identifyingKeys == before.identifyingKeys)
    }

    /// TIFF の Make / Model / Software を落とす
    @Test("TIFF の機材タグを落とす")
    func stripsTIFFCameraTags() throws {
        let dir = TestSupport.makeTemporaryDirectory("exif-tiff")
        defer { TestSupport.remove(dir) }
        let original = dir.appendingPathComponent("photo.jpg")
        try Self.writeJPEGWithMetadata(to: original)

        let stripped = try stripper.strip(original, into: dir)
        guard let source = CGImageSourceCreateWithURL(stripped as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { Issue.record("読めない"); return }

        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        #expect(tiff[kCGImagePropertyTIFFMake] == nil)
        #expect(tiff[kCGImagePropertyTIFFModel] == nil)
        #expect(tiff[kCGImagePropertyTIFFSoftware] == nil)
    }

    /// §7.4: 処理は一時ディレクトリの複製に対して行い、完了後に削除する
    @Test("出力は指定した一時ディレクトリに置かれ、原本と別のファイルになる")
    func writesToTemporaryDirectory() throws {
        let dir = TestSupport.makeTemporaryDirectory("exif-out")
        defer { TestSupport.remove(dir) }
        let original = dir.appendingPathComponent("photo.jpg")
        try Self.writeJPEGWithMetadata(to: original)

        let workDir = dir.appendingPathComponent("work", isDirectory: true)
        let stripped = try stripper.strip(original, into: workDir)
        #expect(stripped.path.hasPrefix(workDir.path))
        #expect(stripped.path != original.path)
        #expect(FileManager.default.fileExists(atPath: original.path))
    }

    /// E-09: 読めないファイルは**中止**する（DD-001 §8.3 の「警告のみで続行しない」を継承）
    @Test("E-09: 読めない画像はエラーになる（黙って続行しない）")
    func failsOnUnreadableImage() throws {
        let dir = TestSupport.makeTemporaryDirectory("exif-bad")
        defer { TestSupport.remove(dir) }
        let broken = dir.appendingPathComponent("broken.jpg")
        try Data("not an image".utf8).write(to: broken)

        #expect(throws: ImageMetadataError.self) {
            _ = try stripper.strip(broken, into: dir)
        }
    }

    /// PNG は可逆なので再エンコードで問題にならない（G-06 CAUTION）
    @Test("PNG も処理できる")
    func handlesPNG() throws {
        let dir = TestSupport.makeTemporaryDirectory("exif-png")
        defer { TestSupport.remove(dir) }
        let original = dir.appendingPathComponent("a.png")
        try Self.writeImage(to: original, type: UTType.png, metadata: [:])
        let stripped = try stripper.strip(original, into: dir)
        #expect(FileManager.default.fileExists(atPath: stripped.path))
    }

    /// PNG のテキストチャンク（tEXt / iTXt）は `{Exif}` の子ではなくトップレベルの
    /// `{PNG}` 辞書に出る。Exif を kCFNull にしても消えない。
    /// 編集ツールが書く XMP（位置情報を含みうる）もここに載る。
    @Test("PNG のテキストチャンクを除去する")
    func stripsPNGTextChunks() throws {
        let dir = TestSupport.makeTemporaryDirectory("exif-pngtext")
        defer { TestSupport.remove(dir) }
        let original = dir.appendingPathComponent("a.png")
        try Self.writeImage(to: original, type: UTType.png, metadata: [
            kCGImagePropertyPNGDictionary: [
                kCGImagePropertyPNGAuthor: "Taro",
                kCGImagePropertyPNGSoftware: "SecretTool 3.2",
                kCGImagePropertyPNGDescription: "撮影地: 東京",
            ],
        ])
        let before = stripper.inspect(original)
        #expect(before.hasIdentifyingMetadata, "テスト用 PNG にメタデータが入っていない")

        let stripped = try stripper.strip(original, into: dir)
        let after = stripper.inspect(stripped)
        #expect(!after.hasIdentifyingMetadata, "残存: \(after.identifyingKeys)")

        // 生の辞書でも消えていること
        let source = CGImageSourceCreateWithURL(stripped as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any] ?? [:]
        #expect(png[kCGImagePropertyPNGAuthor] == nil)
        #expect(png[kCGImagePropertyPNGSoftware] == nil)
        #expect(png[kCGImagePropertyPNGDescription] == nil)
    }

    /// **M-26**: 元が持っていない辞書を渡すと、`kCFNull` が消すどころかキーを生やす。
    ///
    /// JPEG（PNG 辞書を持たない）を処理したあと、PNG 由来のキーが
    /// `IPTC.CopyrightNotice` / `TIFF.ImageDescription` として**空の値で出現しない**こと。
    /// これが崩れると、除去したつもりの処理が新しいメタデータを作ることになる。
    @Test("M-26: 元に無い辞書のキーを生やさない")
    func doesNotFabricateMetadata() throws {
        let dir = TestSupport.makeTemporaryDirectory("exif-fabricate")
        defer { TestSupport.remove(dir) }
        // PNG 辞書も IPTC もまったく持たない JPEG
        let original = dir.appendingPathComponent("plain.jpg")
        try Self.writeImage(to: original, type: UTType.jpeg, metadata: [:])

        let before = stripper.inspect(original)
        #expect(!before.hasIdentifyingMetadata, "前提: 元に識別情報が無い \(before.identifyingKeys)")

        let stripped = try stripper.strip(original, into: dir)
        let after = stripper.inspect(stripped)
        #expect(!after.hasIdentifyingMetadata,
                "元に無かったキーが生えた: \(after.identifyingKeys)")

        // 生の辞書でも、元に無かった辞書が作られていないこと
        let source = CGImageSourceCreateWithURL(stripped as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        #expect(props[kCGImagePropertyPNGDictionary] == nil, "JPEG に PNG 辞書が作られた")
        let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        #expect(iptc.isEmpty, "元に無い IPTC が作られた: \(iptc.keys.map { $0 as String })")
    }

    /// MakerNote は**メーカーごとに別の辞書**でトップレベルに出る。
    /// `kCGImagePropertyExifDictionary = kCFNull` では消えず、
    /// カメラのシリアル番号・レンズ個体情報が残る。
    @Test("MakerNote 辞書も除去対象・検査対象に含める")
    func handlesMakerNoteDictionaries() {
        // 実装が全メーカーを潰していること（1 社だけ対応だと他社機で漏れる）
        let keys = Set(ImageMetadataStripper.makerNoteKeys.map { $0 as String })
        #expect(keys.contains(kCGImagePropertyMakerAppleDictionary as String))
        #expect(keys.contains(kCGImagePropertyMakerCanonDictionary as String))
        #expect(keys.contains(kCGImagePropertyMakerNikonDictionary as String))
        #expect(keys.contains(kCGImagePropertyMakerFujiDictionary as String))
        #expect(keys.contains(kCGImagePropertyMakerOlympusDictionary as String))
        #expect(keys.contains(kCGImagePropertyMakerPentaxDictionary as String))
        #expect(keys.contains(kCGImagePropertyMakerMinoltaDictionary as String))
    }

    // MARK: - テスト用画像の生成

    static func writeJPEGWithMetadata(to url: URL) throws {
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 35.6812,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 139.7671,
            kCGImagePropertyGPSLongitudeRef: "E",
        ]
        let exif: [CFString: Any] = [
            kCGImagePropertyExifDateTimeOriginal: "2026:08:31 12:00:00",
            kCGImagePropertyExifLensModel: "TestLens 50mm",
            kCGImagePropertyExifBodySerialNumber: "SERIAL123",
        ]
        let tiff: [CFString: Any] = [
            kCGImagePropertyTIFFMake: "TestCamera",
            kCGImagePropertyTIFFModel: "Model-X",
            kCGImagePropertyTIFFSoftware: "TestSoftware 1.0",
            kCGImagePropertyTIFFOrientation: 6,
        ]
        let iptc: [CFString: Any] = [kCGImagePropertyIPTCKeywords: ["secret"]]

        try writeImage(to: url, type: UTType.jpeg, metadata: [
            kCGImagePropertyGPSDictionary: gps,
            kCGImagePropertyExifDictionary: exif,
            kCGImagePropertyTIFFDictionary: tiff,
            kCGImagePropertyIPTCDictionary: iptc,
            // DD-001 F-16: この 2 つは保持されなければならない
            kCGImagePropertyOrientation: 6,
        ])
    }

    static func writeImage(to url: URL, type: UTType, metadata: [CFString: Any]) throws {
        let width = 16, height = 16
        // ICC プロファイルを持つ色空間で作る（sRGB）
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let image = { () -> CGImage? in
                  context.setFillColor(CGColor(red: 0.36, green: 0.65, blue: 0.89, alpha: 1))
                  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                  return context.makeImage()
              }()
        else { throw ImageMetadataError.writeFailed("テスト画像を作れない") }

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil)
        else { throw ImageMetadataError.writeFailed("書き出し先を作れない") }
        CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageMetadataError.writeFailed("finalize に失敗")
        }
    }
}
