import Foundation

/// §7.3 手順 1: `publicKeyTemplate` から公開 key を組み立てる。
///
/// 既定は `{prefix}/{yyyy}/{slug}.{ext}`（DD-001 §4.4 準拠）。
/// slug 規則が決定的なので、同じファイルを再度公開すれば同じ key・同じ URL になる（§8.6.3）。
public enum PublicKeyTemplate {

    public static func render(template: String,
                              prefix: String,
                              fileName: String,
                              now: Date = Date(),
                              calendar: Calendar = Calendar(identifier: .gregorian),
                              timeZone: TimeZone = .current) -> String {
        let (slug, ext) = Slug.shareSlug(fileName: fileName, now: now)

        var cal = calendar
        cal.timeZone = timeZone
        let components = cal.dateComponents([.year, .month, .day], from: now)
        let yyyy = String(format: "%04d", components.year ?? 1970)
        let mm = String(format: "%02d", components.month ?? 1)
        let dd = String(format: "%02d", components.day ?? 1)

        var key = template
        key = key.replacingOccurrences(of: "{prefix}", with: prefix)
        key = key.replacingOccurrences(of: "{yyyy}", with: yyyy)
        key = key.replacingOccurrences(of: "{mm}", with: mm)
        key = key.replacingOccurrences(of: "{dd}", with: dd)
        key = key.replacingOccurrences(of: "{slug}", with: slug)
        key = key.replacingOccurrences(of: "{ext}", with: ext)

        return normalize(key, hasExtension: !ext.isEmpty)
    }

    /// 空の置換で `//` や末尾 `.` が生まれるのを畳む
    static func normalize(_ raw: String, hasExtension: Bool) -> String {
        var key = raw
        while key.contains("//") { key = key.replacingOccurrences(of: "//", with: "/") }
        while key.hasPrefix("/") { key.removeFirst() }
        if !hasExtension, key.hasSuffix(".") { key.removeLast() }
        return key
    }

    /// §7.1: `{publicBaseURL}/{key}` を組み立てる。
    /// publicBaseURL は末尾スラッシュなしに正規化済みである前提（V-05）。
    public static func publicURL(publicBaseURL: String, key: String) -> String {
        let base = ProfileValidator.normalizePublicBaseURL(publicBaseURL)
        let encoded = key.split(separator: "/", omittingEmptySubsequences: false)
            .map { component -> String in
                component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                    ?? String(component)
            }
            .joined(separator: "/")
        return "\(base)/\(encoded)"
    }

    /// §7.2: ローカルファイルの期限付き共有で使う staging の key。
    /// 日付 prefix だけで自己完結する判定にするため、`share-staging/{YYYYMMDD}/` を使う。
    public static let stagingPrefix = "share-staging"

    /// **MUST — key に乱数を含める。**
    ///
    /// 日付とファイル名だけで決めると `report.pdf` のような日常的な名前が同じ日に衝突し、
    /// 2 本目のアップロードが 1 本目のオブジェクトを**黙って置き換える**
    /// （`operations/copyfile` は既存キーを上書きする）。
    /// このとき **1 本目の presigned URL は有効なまま 2 本目の中身を配信する** —
    /// 最初にリンクを渡した相手に、渡すつもりのなかったファイルが届く。
    /// SEC-G05 により URL を保存しないので追跡も失効もできず、最長 7 日この状態が続く。
    ///
    /// 掃除は日付 prefix だけで判定するので（§7.2）、乱数を入れても冪等性は損なわれない。
    public static func stagingKey(fileName: String,
                                 now: Date = Date(),
                                 timeZone: TimeZone = .current,
                                 nonce: String = RandomToken.make(length: 10)) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: now)
        let stamp = String(format: "%04d%02d%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
        return "\(stagingPrefix)/\(stamp)/\(nonce)/\(Slug.shareFileName(fileName: fileName, now: now))"
    }

    /// §5.4: 取り下げ先。`gone/{key}`（削除ではない・DD-001 §4.4 の URL 不変性）
    public static let gonePrefix = "gone"

    public static func goneKey(_ key: String) -> String { "\(gonePrefix)/\(key)" }

    /// §8.6.3: 移動先に `gone/{key}` が既に存在する場合のフォールバック。
    /// 取り下げ操作が二度押しで失敗しないようにする。
    public static func goneKeyFallback(_ key: String, now: Date = Date()) -> String {
        "\(gonePrefix)/\(key).\(Int(now.timeIntervalSince1970))"
    }
}
