import Foundation
import Testing
@testable import SkyFolderKit

@Suite("slug 規則（§7.3.1 / V-03b）")
struct SlugTests {

    /// T-G19: `Logo Final.PNG` → `logo-final.png`。**拡張子も小文字化する**（DD-001 F-07）。
    @Test("共有 slug は拡張子も小文字化する")
    func shareSlugLowercasesExtension() {
        let (base, ext) = Slug.shareSlug(fileName: "Logo Final.PNG")
        #expect(base == "logo-final")
        #expect(ext == "png")
        #expect(Slug.shareFileName(fileName: "Logo Final.PNG") == "logo-final.png")
    }

    @Test("許可外の文字を落とす", arguments: [
        ("screenshot 2026.PNG", "screenshot-2026.png"),
        ("my_file-v1.2.TXT", "my_file-v1.2.txt"),
        ("a b  c.Jpeg", "a-b--c.jpeg"),
    ])
    func shareSlugFilters(input: String, expected: String) {
        #expect(Slug.shareFileName(fileName: input) == expected)
    }

    /// 記号だけのベース名は除去後に空になるので、規則 6 のフォールバックが働く
    @Test("記号だけのベース名は file-{unixtime} になる")
    func symbolsOnlyFallsBack() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(Slug.shareFileName(fileName: "()[]!@#.png", now: now) == "file-1700000000.png")
    }

    /// 6. 結果のベース名が空なら `file-{unixtime}`
    @Test("ベース名が空になるとき file-{unixtime} にフォールバックする")
    func shareSlugFallsBack() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let (base, ext) = Slug.shareSlug(fileName: "日本語だけ.PNG", now: now)
        #expect(base == "file-1700000000")
        #expect(ext == "png")
    }

    /// §8.6.3: slug 規則が決定的であるため、同じファイルを再度公開すれば同じ key・同じ URL になる。
    @Test("同じ入力からは常に同じ結果になる（決定的）")
    func shareSlugIsDeterministic() {
        let a = Slug.shareFileName(fileName: "Report Q3.PDF")
        let b = Slug.shareFileName(fileName: "Report Q3.PDF")
        #expect(a == b)
    }

    /// V-03b: displayName が全て日本語なら `profile-{idの先頭8文字}`
    @Test("プロファイル slug は日本語のみなら ID 由来にフォールバックする")
    func profileSlugFallback() {
        let slug = Slug.profileSlug(displayName: "仕事用", profileId: "prof_01JABCDEFGH")
        #expect(slug == "profile-01jabcde")
    }

    @Test("プロファイル slug は 32 文字で切り詰める")
    func profileSlugTruncates() {
        let slug = Slug.profileSlug(displayName: String(repeating: "a", count: 50),
                                    profileId: "prof_X")
        #expect(slug.count == 32)
    }

    @Test("プロファイル slug は空白をハイフンにし前後のハイフンを落とす")
    func profileSlugNormalizes() {
        #expect(Slug.profileSlug(displayName: " My Work Space ", profileId: "prof_X") == "my-work-space")
    }
}

@Suite("公開 key の組み立て（§7.3）")
struct PublicKeyTemplateTests {

    /// T-G19: prefix=img で `img/2026/logo-final.png`
    @Test("既定テンプレートから key を作る")
    func rendersDefaultTemplate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 5))!
        let key = PublicKeyTemplate.render(template: "{prefix}/{yyyy}/{slug}.{ext}",
                                           prefix: "img",
                                           fileName: "Logo Final.PNG",
                                           now: now,
                                           timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        #expect(key == "img/2026/logo-final.png")
    }

    @Test("prefix が空でも // にならない")
    func collapsesEmptyPrefix() {
        let key = PublicKeyTemplate.render(template: "{prefix}/{yyyy}/{slug}.{ext}",
                                           prefix: "", fileName: "a.png")
        #expect(!key.contains("//"))
        #expect(!key.hasPrefix("/"))
    }

    @Test("拡張子がないファイルで末尾のドットを残さない")
    func dropsTrailingDot() {
        let key = PublicKeyTemplate.render(template: "{prefix}/{slug}.{ext}",
                                           prefix: "a", fileName: "README")
        #expect(key == "a/readme")
    }

    @Test("公開 URL は末尾スラッシュを正規化して組み立てる")
    func buildsPublicURL() {
        #expect(PublicKeyTemplate.publicURL(publicBaseURL: "https://files.example.com/",
                                            key: "assets/2026/a.png")
                == "https://files.example.com/assets/2026/a.png")
    }

    @Test("公開 URL のパスはパーセントエンコードする")
    func encodesPublicURL() {
        let url = PublicKeyTemplate.publicURL(publicBaseURL: "https://files.example.com",
                                              key: "assets/a b.png")
        #expect(url == "https://files.example.com/assets/a%20b.png")
    }

    /// §7.2: staging は日付 prefix だけで自己完結する判定にする
    @Test("staging key は日付 prefix を持つ")
    func stagingKeyHasDatePrefix() {
        var calendar = Calendar(identifier: .gregorian)
        let tz = TimeZone(identifier: "Asia/Tokyo")!
        calendar.timeZone = tz
        let now = calendar.date(from: DateComponents(year: 2026, month: 1, day: 9))!
        let key = PublicKeyTemplate.stagingKey(fileName: "A B.txt", now: now, timeZone: tz,
                                               nonce: "NONCE")
        #expect(key == "share-staging/20260109/NONCE/a-b.txt")
        // 掃除は日付 prefix で判定するので、乱数が入っても対象になる
        #expect(StagingRetention.stampOfStagingKey(key) == "20260109")
    }

    /// **同じ日に同名の別ファイルを共有しても衝突しないこと。**
    ///
    /// 衝突すると 2 本目のアップロードが 1 本目のオブジェクトを黙って置き換え、
    /// **1 本目の presigned URL が有効なまま 2 本目の中身を配信する**。
    /// 最初にリンクを渡した相手に、渡すつもりのなかったファイルが届く（最長 7 日）。
    @Test("同じ日に同名のファイルを共有しても staging key が衝突しない")
    func stagingKeysDoNotCollide() {
        var calendar = Calendar(identifier: .gregorian)
        let tz = TimeZone(identifier: "Asia/Tokyo")!
        calendar.timeZone = tz
        let now = calendar.date(from: DateComponents(year: 2026, month: 1, day: 9))!
        let keys = Set((0..<50).map { _ in
            PublicKeyTemplate.stagingKey(fileName: "report.pdf", now: now, timeZone: tz)
        })
        #expect(keys.count == 50, "同じ日・同じ名前で key が重複した: \(keys.count)/50")
        // それでも掃除の判定は日付だけで効く（§7.2 の冪等性）
        #expect(keys.allSatisfy { StagingRetention.stampOfStagingKey($0) == "20260109" })
    }
}

@Suite("staging の保持期間（§7.2・14 日）")
struct StagingRetentionTests {

    private let tz = TimeZone(identifier: "Asia/Tokyo")!
    private var now: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        return calendar.date(from: DateComponents(year: 2026, month: 1, day: 20))!
    }

    @Test("14 日より古い日付 prefix だけを対象にする")
    func selectsOldOnly() {
        let cutoff = StagingRetention.cutoffStamp(now: now, retentionDays: 14, timeZone: tz)
        #expect(cutoff == "20260106")
        #expect(StagingRetention.isExpiredStagingKey("share-staging/20260105/a.txt",
                                                     cutoffStamp: cutoff))
        #expect(!StagingRetention.isExpiredStagingKey("share-staging/20260106/a.txt",
                                                      cutoffStamp: cutoff))
        #expect(!StagingRetention.isExpiredStagingKey("share-staging/20260119/a.txt",
                                                      cutoffStamp: cutoff))
    }

    /// staging 以外のキーを巻き込まない
    @Test("staging 以外のキーは対象外")
    func ignoresNonStaging() {
        let cutoff = StagingRetention.cutoffStamp(now: now, retentionDays: 14, timeZone: tz)
        #expect(!StagingRetention.isExpiredStagingKey("assets/2026/a.png", cutoffStamp: cutoff))
        #expect(!StagingRetention.isExpiredStagingKey("gone/assets/a.png", cutoffStamp: cutoff))
        #expect(!StagingRetention.isExpiredStagingKey("share-staging/notadate/a.txt",
                                                      cutoffStamp: cutoff))
    }

    /// §8.6.3: 何度実行しても同じ集合が対象になる（冪等）
    @Test("判定は冪等")
    func isIdempotent() {
        let cutoff = StagingRetention.cutoffStamp(now: now, retentionDays: 14, timeZone: tz)
        let key = "share-staging/20251201/a.txt"
        #expect(StagingRetention.isExpiredStagingKey(key, cutoffStamp: cutoff)
                == StagingRetention.isExpiredStagingKey(key, cutoffStamp: cutoff))
    }
}
