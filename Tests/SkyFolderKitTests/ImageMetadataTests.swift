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
        "a.jpg", "a.JPEG", "a.PNG", "a.tiff", "a.HEIC", "a.tif",
    ])
    func targetsImageExtensions(name: String) {
        #expect(ImageMetadataStripper.isTargetFile(URL(fileURLWithPath: "/tmp/\(name)")))
    }

    /// **webp は ImageIO が読めるが書けない。**
    /// 対象に入れると `strip` が必ず `unsupportedFormat` を投げ、
    /// WebP の恒久公開が常に失敗する（実測）。対象外にしたうえで、
    /// メタデータを持つ webp は `carriesMetadata` の fail-closed が公開を止める。
    @Test("webp は再書き出しできないので対象外")
    func webpIsNotATarget() {
        #expect(!ImageMetadataStripper.isTargetFile(URL(fileURLWithPath: "/tmp/a.webp")))
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

    /// **SEC-08（MUST）の回帰テスト。**
    ///
    /// 除去を「消したいキーの一覧との積集合」で書くと、**一覧に無いキーは無加工で
    /// 出力へ引き継がれる**（`AddImageFromSource` は properties をマージするため）。
    /// 実測（2026-09-01）: IPTC の `PersonInImage` — 写真アプリや Lightroom の顔認識が
    /// 書き込む**被写体本人の氏名** — が、GPS も Byline も消えている裏で残っていた。
    /// ユーザーには「除去された」ように見えるので気づけない。
    ///
    /// このテストは**かつての一覧に載っていなかったキー**を必ず含める。
    /// 一覧に 1 件足すだけの修正では通らない。
    @Test("SEC-08: 除去の一覧に無い IPTC キー（PersonInImage）も残らない")
    func stripsIPTCKeysThatNoAllowListMentions() throws {
        let dir = TestSupport.makeTemporaryDirectory("iptc-unlisted")
        defer { TestSupport.remove(dir) }
        let original = dir.appendingPathComponent("person.jpg")

        try Self.writeImage(to: original, type: .jpeg, metadata: [
            kCGImagePropertyIPTCDictionary: [
                kCGImagePropertyIPTCByline: "Taro",              // かつての一覧にあった
                "PersonInImage" as CFString: ["Hanako Suzuki"],  // 一覧に無かった
            ] as [CFString: Any],
        ])

        let before = stripper.inspect(original)
        #expect(before.identifyingKeys.contains("IPTC.PersonInImage"),
                "前提が成立していない。原本に PersonInImage が入っていない: \(before.identifyingKeys)")

        let stripped = try stripper.strip(original, into: dir)
        let after = stripper.inspect(stripped)

        #expect(!after.hasIPTC, "IPTC が残っている: \(after.identifyingKeys)")
        #expect(!after.identifyingKeys.contains("IPTC.PersonInImage"))

        // プロパティ経由で見えなくても、実体が残っていれば読める。
        // **生バイト列でも確かめる。**
        let bytes = try Data(contentsOf: stripped)
        #expect(bytes.range(of: Data("Hanako Suzuki".utf8)) == nil,
                "出力の生バイト列に被写体の氏名が残っている")
    }

    /// TIFF も同じ形の穴があった。除去側が一覧方式で、**検査側も同じ一覧でフィルタ**していたため、
    /// 一覧外の TIFF キーは**除去にも検査にも見えない盲点**になっていた。
    @Test("除去の一覧に無い TIFF キーも残らない（検査側の盲点だった）")
    func stripsTIFFKeysThatNoAllowListMentions() throws {
        let dir = TestSupport.makeTemporaryDirectory("tiff-unlisted")
        defer { TestSupport.remove(dir) }
        let original = dir.appendingPathComponent("doc.jpg")

        try Self.writeImage(to: original, type: .jpeg, metadata: [
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "TestCamera",            // かつての一覧にあった
                kCGImagePropertyTIFFDocumentName: "secret-doc",    // 一覧に無かった
                kCGImagePropertyTIFFOrientation: 6,                // 構造キー・残す
            ] as [CFString: Any],
            kCGImagePropertyOrientation: 6,
        ])

        let before = stripper.inspect(original)
        #expect(before.identifyingKeys.contains("TIFF.DocumentName"),
                "前提が成立していない: \(before.identifyingKeys)")

        let stripped = try stripper.strip(original, into: dir)
        let after = stripper.inspect(stripped)

        #expect(!after.identifyingKeys.contains { $0.hasPrefix("TIFF.") },
                "TIFF のキーが残っている: \(after.identifyingKeys)")
        // 構造キーは残す（DD-001 F-16: 剥がすと横倒しになる）
        #expect(after.orientation == 6, "Orientation が失われた")

        let bytes = try Data(contentsOf: stripped)
        #expect(bytes.range(of: Data("secret-doc".utf8)) == nil,
                "出力の生バイト列に文書名が残っている")
    }

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

/// **XMP パケットが除去されるかの実測。**
///
/// `strip` は `CGImageSourceCopyPropertiesAtIndex` が返す辞書へ `kCFNull` を入れる方式だが、
/// **XMP（JPEG の APP1 / PNG の iTXt）はその properties 辞書に現れない** — ImageIO では
/// `CGImageSourceCopyMetadataAtIndex` / `CGImageMetadata` 系の別 API で扱う。
/// つまり指定先のキーが存在せず、`AddImageFromSource` の「指定しなかったものは元のまま」
/// によって出力へ残る可能性がある。
///
/// XMP は `Iptc4xmpExt:PersonInImage`（**M-28 で実害が出た被写体の氏名の本来の格納先**）や
/// `exif:GPSLatitude` を持つ。Lightroom や写真アプリの書き出しでは IPTC 辞書ではなく
/// XMP 側に入るのが普通なので、ここが素通しなら M-28 の修正は片側しか塞いでいない。
@Suite("XMP パケットの除去（SEC-08）")
struct XMPStrippingTests {

    private let stripper = ImageMetadataStripper()

    /// JPEG の SOI 直後に XMP の APP1 セグメントを差し込む。
    ///
    /// ImageIO の `CGImageDestinationAddImageAndMetadata` では `xmp:` の任意タグを
    /// 埋め込めなかった（保存されるのは `exif:` へ写せるものだけだった・実測）ため、
    /// **バイト列を直接組んで確実に XMP を持つ JPEG を作る**。
    /// 実際のカメラや Lightroom が書く形と同じ APP1 セグメントになる。
    private func insertXMPPacket(into jpeg: Data, xmp: String) -> Data {
        let header = Data("http://ns.adobe.com/xap/1.0/\u{0}".utf8)
        let payload = header + Data(xmp.utf8)
        let length = payload.count + 2          // 長さフィールド自身の 2 バイトを含む
        var segment = Data([0xFF, 0xE1])        // APP1
        segment.append(UInt8((length >> 8) & 0xFF))
        segment.append(UInt8(length & 0xFF))
        segment.append(payload)

        var result = Data(jpeg.prefix(2))       // SOI
        result.append(segment)
        result.append(jpeg.dropFirst(2))
        return result
    }

    @Test("XMP に入れた識別情報が出力に残らない")
    func stripsXMPMetadata() throws {
        let dir = TestSupport.makeTemporaryDirectory("xmp")
        defer { TestSupport.remove(dir) }
        let plain = dir.appendingPathComponent("plain.jpg")
        let original = dir.appendingPathComponent("xmp.jpg")

        try ImageMetadataStripperTests.writeImage(to: plain, type: UTType.jpeg, metadata: [:])

        // `Iptc4xmpExt:PersonInImage` は M-28 で実害が出た被写体の氏名の**本来の格納先**。
        // Lightroom や写真アプリの書き出しでは IPTC 辞書ではなくこちらに入る。
        let xmp = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about=""
          xmlns:Iptc4xmpExt="http://iptc.org/std/Iptc4xmpExt/2008-02-29/"
          xmlns:xmp="http://ns.adobe.com/xap/1.0/">
          <Iptc4xmpExt:PersonInImage><rdf:Bag><rdf:li>XMP-PERSON-NAME</rdf:li></rdf:Bag></Iptc4xmpExt:PersonInImage>
          <xmp:CreatorTool>XMP-CREATOR-TOOL</xmp:CreatorTool>
        </rdf:Description>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        try insertXMPPacket(into: try Data(contentsOf: plain), xmp: xmp).write(to: original)

        // 前提: 原本の生バイトに XMP の値があること
        let beforeBytes = try Data(contentsOf: original)
        #expect(beforeBytes.range(of: Data("XMP-PERSON-NAME".utf8)) != nil,
                "テストの前提が成立していない。原本に XMP が入っていない")
        // ImageIO からも読めること（読めないなら strip が触れる余地も無い）
        let src = CGImageSourceCreateWithURL(original as CFURL, nil)
        #expect(src != nil, "XMP を足した JPEG が ImageIO で読めない")

        let stripped = try stripper.strip(original, into: dir)

        // **生バイト列で確かめる。** XMP は properties 辞書に現れないため、
        // `inspect` の identifyingKeys では検出できない。
        let afterBytes = try Data(contentsOf: stripped)
        #expect(afterBytes.range(of: Data("XMP-PERSON-NAME".utf8)) == nil,
                "XMP の被写体名が出力に残っている（SEC-08）")
        #expect(afterBytes.range(of: Data("XMP-CREATOR-TOOL".utf8)) == nil,
                "XMP の CreatorTool が出力に残っている")
    }
}

/// 除去の対象外なのに識別情報を抱えている画像の検出（SEC-08 の fail-closed）。
///
/// `targetExtensions` の列挙だけで判定すると、RAW や新しいフォーマットが
/// **無加工・無警告で公開される**。拡張子の一覧は必ず置いていかれるので、
/// 実際に開いて中身を見る経路を持たせてある。
@Suite("除去対象外の画像の検出（SEC-08 fail-closed）")
struct UnsupportedImageDetectionTests {

    @Test("一覧外の拡張子でも、Exif を持つ画像なら検出する")
    func detectsMetadataInUnlistedExtension() throws {
        let dir = TestSupport.makeTemporaryDirectory("unlisted")
        defer { TestSupport.remove(dir) }
        // 中身は JPEG だが拡張子が一覧に無い（RAW を持ち込んだ状況の代用）
        let file = dir.appendingPathComponent("photo.dng")
        try ImageMetadataStripperTests.writeImage(to: file, type: UTType.jpeg, metadata: [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 35.6812,
                kCGImagePropertyGPSLongitude: 139.7671,
            ] as [CFString: Any],
        ])

        #expect(!ImageMetadataStripper.isTargetFile(file), "テストの前提: 一覧外であること")
        #expect(ImageMetadataStripper.carriesMetadata(file),
                "一覧外でも GPS を持つなら検出しなければならない")
    }

    @Test("画像でないファイルは検出しない（公開を無用に止めない）")
    func ignoresNonImages() throws {
        let dir = TestSupport.makeTemporaryDirectory("nonimage")
        defer { TestSupport.remove(dir) }
        let file = dir.appendingPathComponent("notes.txt")
        try Data("just text".utf8).write(to: file)
        #expect(!ImageMetadataStripper.carriesMetadata(file))
    }

    @Test("メタデータを持たない画像は検出しない")
    func ignoresCleanImages() throws {
        let dir = TestSupport.makeTemporaryDirectory("clean")
        defer { TestSupport.remove(dir) }
        let file = dir.appendingPathComponent("clean.dng")
        try ImageMetadataStripperTests.writeImage(to: file, type: UTType.png, metadata: [:])
        // PNG を素で書き出しても TIFF/Exif 辞書が付かないことを確かめる
        // （付くなら fail-closed が過剰に発火するので、そのときはここで落ちる）
        #expect(!ImageMetadataStripper.carriesMetadata(file))
    }
}
