import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageMetadataError: Error, LocalizedError, Sendable {
    /// E-09: Exif 除去に失敗 → 公開を中止する（DD-001 §8.3 の「警告のみで続行しない」を継承）
    case unreadable(String)
    case unsupportedFormat(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let name):
            return "画像のメタデータを除去できなかったため、公開を中止しました。（\(name) を読めません）"
        case .unsupportedFormat(let ext):
            return "画像のメタデータを除去できなかったため、公開を中止しました。（\(ext) は再書き出しに対応していません）"
        case .writeFailed(let detail):
            return "画像のメタデータを除去できなかったため、公開を中止しました。（\(detail)）"
        }
    }

    public var catalogID: String { "E-09" }
}

/// §7.4 / SEC-G03 / G-06: 公開前の画像メタデータ除去。ImageIO で実装し、外部 exiftool に依存しない。
public struct ImageMetadataStripper: Sendable {

    /// 対象拡張子（大小文字不問）。対象外は無加工でアップロードする。
    public static let targetExtensions: Set<String> = ["jpg", "jpeg", "png", "tiff", "tif", "heic", "webp"]

    public static func isTargetFile(_ url: URL) -> Bool {
        targetExtensions.contains(url.pathExtension.lowercased())
    }

    public init() {}

    /// 一時ディレクトリの複製に対して除去を行い、**原本は変更しない**（§7.4）。
    ///
    /// 除去するもの:
    /// - `kCGImagePropertyGPSDictionary`（GPS 位置情報）
    /// - `kCGImagePropertyExifDictionary`（撮影日時・機材・シリアル）
    /// - `kCGImagePropertyExifAuxDictionary`
    /// - `kCGImagePropertyIPTCDictionary`
    /// - `kCGImagePropertyTIFFDictionary` のうち Make / Model / Software
    ///
    /// 保持するもの（**必須要件**・DD-001 F-16）:
    /// - `kCGImagePropertyOrientation`（回転情報）
    /// - ICC カラープロファイル
    ///
    /// これを剥がすと公開画像が横倒し・色崩れで表示される。
    ///
    /// - Returns: 除去済みの一時ファイル。呼び出し側が確実に削除すること（defer 相当）。
    public func strip(_ source: URL, into directory: URL? = nil) throws -> URL {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              CGImageSourceGetCount(imageSource) > 0
        else { throw ImageMetadataError.unreadable(source.lastPathComponent) }

        guard let typeIdentifier = CGImageSourceGetType(imageSource) else {
            throw ImageMetadataError.unsupportedFormat(source.pathExtension)
        }

        // **原本は変更しない**（§7.4）。呼び出し側が原本と同じディレクトリを渡しても
        // 上書きが起きないよう、必ず一意なサブディレクトリの中に書き出す。
        let base = directory ?? FileManager.default.temporaryDirectory
        let workingDirectory = base.appendingPathComponent(
            "\(AppIdentity.bundleIdentifier).strip.\(UUID().uuidString)", isDirectory: true)
        try AppPaths.ensureDirectory(workingDirectory, mode: 0o700)
        let destinationURL = workingDirectory.appendingPathComponent(source.lastPathComponent)
        guard destinationURL.standardizedFileURL != source.standardizedFileURL else {
            throw ImageMetadataError.writeFailed("出力先が原本と同じになりました")
        }

        guard let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL, typeIdentifier, 1, nil)
        else { throw ImageMetadataError.unsupportedFormat(source.pathExtension) }

        let original = (CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]) ?? [:]
        var properties: [CFString: Any] = [:]

        // MUST — 除去は「入れない」ではなく `kCFNull` を明示する（M-15）。
        //
        // `CGImageDestinationAddImageFromSource` の properties は**元のメタデータとマージ**される。
        // 単に載せないだけでは、GPS も Exif も元のまま出力に引き継がれる（実測で確認）。
        //
        // **ただし、元に存在しない辞書を渡してはならない（M-26）。**
        //
        // 元が持っていない辞書（例: JPEG に `{PNG}`）を渡すと、`kCFNull` を入れたキーが
        // 消えるどころか**空のエントリとして生成される**。
        // 実測: JPEG に PNG のキーを渡したところ、元に無かった `IPTC.CopyrightNotice` と
        // `TIFF.ImageDescription` が空の値で出現した。**消すつもりの指定がキーを生やす。**
        //
        // 効いているのは下の `guard let source = original[dictionaryKey]` である。

        /// 元の辞書に**実在するキーを全部**潰す。`keeping` に挙げたものだけ残す。
        ///
        /// **候補一覧との積集合にしてはいけない。** そうすると一覧に無いキーは
        /// `properties` に載らず、`AddImageFromSource` のマージで**元の値がそのまま
        /// 出力へ引き継がれる**。実測（2026-09-01）: IPTC の `PersonInImage`
        /// — 写真アプリや Lightroom の顔認識が書き込む**被写体本人の氏名** — が
        /// 除去されずに残った。GPS も Byline も消えるのでユーザーには効いて見える。
        /// SEC-08（MUST）が防ごうとしている被害そのもの。
        ///
        /// 「消したいキーを数える」のではなく「**残してよいキーだけを数える**」。
        /// 一覧の更新漏れが**安全側に倒れる**のはこちらの向きだけ。
        func nullifyAll(_ dictionaryKey: CFString, keeping keep: [CFString] = []) {
            // ← この guard が load-bearing。
            // M-26: 元に無い辞書へ kCFNull を渡すと、消すどころかキーを生やす。
            guard let source = original[dictionaryKey] as? [CFString: Any] else { return }
            let keepNames = Set(keep.map { $0 as String })
            var result: [CFString: Any] = [:]
            for key in source.keys where !keepNames.contains(key as String) {
                result[key] = kCFNull
            }
            for key in keep { if let value = source[key] { result[key] = value } }
            guard !result.isEmpty else { return }
            properties[dictionaryKey] = result
        }

        // 辞書ごと落としてよいもの（中身を残す必要がない）
        for key in [kCGImagePropertyGPSDictionary,
                    kCGImagePropertyExifDictionary,
                    kCGImagePropertyExifAuxDictionary] where original[key] != nil {
            properties[key] = kCFNull
        }
        // MakerNote は**メーカーごとに別の辞書**として、しかも {Exif} の子ではなく
        // トップレベルに出る。Exif 辞書を kCFNull にしても消えないので個別に潰す。
        for key in Self.makerNoteKeys where original[key] != nil {
            properties[key] = kCFNull
        }

        // **M-26**: PNG のテキストチャンクは PNG / IPTC / TIFF の**3 箇所に写し**が作られる。
        // `Author` は PNG と IPTC.Byline に、`Copyright` は PNG と IPTC.CopyrightNotice と
        // TIFF.Copyright に現れる。**3 つとも潰さないと消えない**（どれか 1 つでも残すとそこから復元される）。
        // 3 辞書とも「**実在するキーを全部潰し、構造に要るものだけ残す**」。
        // 残す一覧は `inspect` が識別情報として数えない一覧と**同じもの**を使う
        // — ここがずれると、検査は検出できるのに除去だけが漏らす状態になる（実測で発生した）。
        nullifyAll(kCGImagePropertyPNGDictionary, keeping: Self.structuralPNGKeyList)
        nullifyAll(kCGImagePropertyIPTCDictionary)
        nullifyAll(kCGImagePropertyTIFFDictionary, keeping: Self.structuralTIFFKeyList)

        // 保持: 回転情報（DD-001 F-16）。剥がすと公開画像が横倒しになる。
        //
        // 実測（mutation で確認・M-16）: `CGImageDestinationAddImageFromSource` は
        // **Orientation を無条件に引き継ぐ**。`kCFNull` を明示しても消えない。
        // つまり以下は現在の ImageIO では効いておらず、消しても結果は変わらない。
        // それでも残すのは将来 ImageIO の挙動が変わったときの保険であり、
        // 「これがあるから保持されている」と読まないこと（保証しているのはテストの表明のほう）。
        if let orientation = original[kCGImagePropertyOrientation] {
            properties[kCGImagePropertyOrientation] = orientation
        }
        // DPI は表示に影響しうるので残す
        for key in [kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
            if let value = original[key] { properties[key] = value }
        }

        // G-06 CAUTION: JPEG は再エンコードのため厳密には非可逆。品質 1.0 で影響を最小化する。
        properties[kCGImageDestinationLossyCompressionQuality] = 1.0

        CGImageDestinationAddImageFromSource(destination, imageSource, 0, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: destinationURL)
            throw ImageMetadataError.writeFailed(source.lastPathComponent)
        }
        return destinationURL
    }

    /// T-G21 の検査に使う。除去後のファイルに**識別情報**が残っていないことを確かめる。
    ///
    /// 注意: JPEG では ImageIO が書き出し時に `{Exif}` へ
    /// `ColorSpace` / `PixelXDimension` / `PixelYDimension` を必ず付け直す（実測）。
    /// これらは画像を見れば分かる構造的な値で識別情報ではないため、
    /// 「Exif 辞書が空か」ではなく「識別情報のキーが残っているか」で判定する。
    public struct Inspection: Sendable, Equatable {
        /// 残っている識別情報のキー（空なら除去できている）
        public var identifyingKeys: [String] = []
        public var orientation: Int?
        public var hasICCProfile: Bool = false

        public var hasIdentifyingMetadata: Bool { !identifyingKeys.isEmpty }
        public var hasGPS: Bool { identifyingKeys.contains { $0.hasPrefix("GPS.") } }
        public var hasExif: Bool { identifyingKeys.contains { $0.hasPrefix("Exif.") } }
        public var hasIPTC: Bool { identifyingKeys.contains { $0.hasPrefix("IPTC.") } }
        public var hasCameraTags: Bool { identifyingKeys.contains { $0.hasPrefix("TIFF.") } }
    }

    /// メーカー固有の MakerNote 辞書。トップレベルに出るので Exif 辞書とは別に潰す必要がある。
    static let makerNoteKeys: [CFString] = [
        kCGImagePropertyMakerAppleDictionary,
        kCGImagePropertyMakerCanonDictionary,
        kCGImagePropertyMakerNikonDictionary,
        kCGImagePropertyMakerMinoltaDictionary,
        kCGImagePropertyMakerFujiDictionary,
        kCGImagePropertyMakerOlympusDictionary,
        kCGImagePropertyMakerPentaxDictionary,
    ]

    /// JPEG 書き出し時に ImageIO が必ず付け直す構造的な Exif キー。識別情報ではない。
    private static let structuralExifKeys: Set<String> = [
        kCGImagePropertyExifColorSpace as String,
        kCGImagePropertyExifPixelXDimension as String,
        kCGImagePropertyExifPixelYDimension as String,
    ]

    // MARK: - 残してよいキー（これ以外は全部潰す）
    //
    // **「消す一覧」ではなく「残す一覧」で持つ。** 消す一覧にすると、
    // 一覧の更新漏れがそのまま漏洩になる（実測: IPTC の `PersonInImage` が残った）。
    // 残す一覧なら、更新漏れは「消しすぎ」に倒れる。**安全側はこちらだけ。**
    //
    // `strip` の `keeping` と `inspect` の除外は、**同じ一覧を使う**こと。
    // ずれると「検査は検出できるのに除去だけが漏らす」状態になる。

    /// IPTC は**丸ごと潰す**。構造・表示に要るキーは無い。

    /// PNG 書き出し時に ImageIO が付け直す構造的なキー。識別情報ではない。
    static let structuralPNGKeyList: [CFString] = [
        kCGImagePropertyPNGInterlaceType,
        kCGImagePropertyPNGGamma,
        kCGImagePropertyPNGsRGBIntent,
        kCGImagePropertyPNGChromaticities,
    ]

    private static let structuralPNGKeys: Set<String> =
        Set(structuralPNGKeyList.map { $0 as String })

    /// TIFF のうち画像の構造・表示に要るもの。**これ以外は全部潰す。**
    static let structuralTIFFKeyList: [CFString] = [
        // DD-001 F-16: 剥がすと公開画像が横倒しになる
        kCGImagePropertyTIFFOrientation,
        kCGImagePropertyTIFFXResolution,
        kCGImagePropertyTIFFYResolution,
        kCGImagePropertyTIFFResolutionUnit,
        kCGImagePropertyTIFFCompression,
        kCGImagePropertyTIFFPhotometricInterpretation,
    ]

    private static let structuralTIFFKeys: Set<String> =
        Set(structuralTIFFKeyList.map { $0 as String })

    public func inspect(_ url: URL) -> Inspection {
        var result = Inspection()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return result }

        func keys(_ dictionaryKey: CFString) -> [String] {
            (properties[dictionaryKey] as? [CFString: Any])?.keys.map { $0 as String } ?? []
        }

        result.identifyingKeys += keys(kCGImagePropertyGPSDictionary).map { "GPS.\($0)" }
        result.identifyingKeys += keys(kCGImagePropertyExifDictionary)
            .filter { !Self.structuralExifKeys.contains($0) }.map { "Exif.\($0)" }
        result.identifyingKeys += keys(kCGImagePropertyExifAuxDictionary).map { "ExifAux.\($0)" }
        result.identifyingKeys += keys(kCGImagePropertyIPTCDictionary).map { "IPTC.\($0)" }
        // 除去側（`strip` の `keeping`）と**同じ一覧**で除外する。
        // かつては「識別情報の一覧に載っているものだけ」を数えていたため、
        // 一覧外の TIFF キーは**除去側にも検査側にも見えない盲点**になっていた。
        result.identifyingKeys += keys(kCGImagePropertyTIFFDictionary)
            .filter { !Self.structuralTIFFKeys.contains($0) }.map { "TIFF.\($0)" }
        // MakerNote と PNG のテキストチャンクも検査対象に含める
        // — 検査していないものは「消せているつもり」になる（M-15 と同じ失敗の形）
        for key in Self.makerNoteKeys {
            result.identifyingKeys += keys(key).map { "\(key as String).\($0)" }
        }
        result.identifyingKeys += keys(kCGImagePropertyPNGDictionary)
            .filter { !Self.structuralPNGKeys.contains($0) }.map { "PNG.\($0)" }
        result.identifyingKeys = Array(Set(result.identifyingKeys)).sorted()

        result.orientation = properties[kCGImagePropertyOrientation] as? Int
        // DD-001 F-16: ICC を剥がすと色崩れする
        result.hasICCProfile = properties[kCGImagePropertyProfileName] != nil

        return result
    }
}
