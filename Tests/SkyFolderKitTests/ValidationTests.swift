import Foundation
import Testing
@testable import SkyFolderKit

@Suite("入力バリデーション（§4.3）")
struct ValidationTests {

    // MARK: - V-01

    @Test("V-01: accountId は 32 桁の小文字 hex")
    func accountId() {
        #expect(ProfileValidator.isValidAccountId(String(repeating: "0123abcd", count: 4)))
        #expect(ProfileValidator.isValidAccountId("  " + String(repeating: "0123ABCD", count: 4) + " "))
        #expect(!ProfileValidator.isValidAccountId("0123abcd"))
        #expect(!ProfileValidator.isValidAccountId(String(repeating: "0123abcz", count: 4)))
    }

    // MARK: - V-02

    @Test("V-02: バケット名は 3〜63 文字で先頭末尾が英数字", arguments: [
        ("abc", true), ("ab", false),
        ("flab-stor-private", true),
        ("-abc", false), ("abc-", false),
        ("ABC", false), ("a_c", false),
        (String(repeating: "a", count: 63), true),
        (String(repeating: "a", count: 64), false),
    ])
    func bucketName(input: String, expected: Bool) {
        #expect(ProfileValidator.isValidBucketName(input) == expected)
    }

    // MARK: - V-03

    @Test("V-03: alias は小文字英数とハイフン 1〜32 文字", arguments: [
        ("private", true), ("a", true), ("a-b-1", true),
        ("", false), ("Private", false), ("a_b", false),
        (String(repeating: "a", count: 33), false),
    ])
    func alias(input: String, expected: Bool) {
        #expect(ProfileValidator.isValidAlias(input) == expected)
    }

    @Test("V-03: alias の重複を検出する")
    func aliasDuplication() {
        let profile = TestSupport.sampleProfile(buckets: [
            BucketConfig(alias: "a", bucketName: "bucket-one", visibility: .privateBucket,
                         mountPath: "~/SkyFolder/x/1"),
            BucketConfig(alias: "a", bucketName: "bucket-two", visibility: .privateBucket,
                         mountPath: "~/SkyFolder/x/2"),
        ])
        let issues = ProfileValidator.validate(profile, secretProvided: true)
        #expect(issues.contains { $0.rule == "V-03" && $0.message.contains("重複") })
    }

    // MARK: - V-04

    @Test("V-04: 同一プロファイル内で mountPath の重複を拒否する")
    func mountPathDuplication() {
        let profile = TestSupport.sampleProfile(buckets: [
            BucketConfig(alias: "a", bucketName: "bucket-one", visibility: .privateBucket,
                         mountPath: "~/SkyFolder/x/same"),
            BucketConfig(alias: "b", bucketName: "bucket-two", visibility: .privateBucket,
                         mountPath: "~/SkyFolder/x/same"),
        ])
        let issues = ProfileValidator.validate(profile, secretProvided: true)
        #expect(issues.contains { $0.rule == "V-04" })
    }

    @Test("V-04: 他プロファイルとの mountPath 重複も拒否する")
    func mountPathCrossProfile() {
        let other = Profile(id: "prof_OTHER", displayName: "other",
                            accountId: String(repeating: "0", count: 32),
                            buckets: [BucketConfig(alias: "x", bucketName: "bucket-one",
                                                   visibility: .privateBucket,
                                                   mountPath: "~/SkyFolder/shared/x")])
        let profile = TestSupport.sampleProfile(buckets: [
            BucketConfig(alias: "y", bucketName: "bucket-two", visibility: .privateBucket,
                         mountPath: "~/SkyFolder/shared/x"),
        ])
        let issues = ProfileValidator.validate(profile, otherProfiles: [other], secretProvided: true)
        #expect(issues.contains { $0.rule == "V-04" && $0.message.contains("他のプロファイル") })
    }

    @Test("V-04: 相対パスを拒否する")
    func mountPathMustBeAbsolute() {
        let profile = TestSupport.sampleProfile(buckets: [
            BucketConfig(alias: "a", bucketName: "bucket-one", visibility: .privateBucket,
                         mountPath: "relative/path"),
        ])
        let issues = ProfileValidator.validate(profile, secretProvided: true)
        #expect(issues.contains { $0.rule == "V-04" })
    }

    // MARK: - V-05 / V-06

    @Test("V-05: publicBaseURL は https:// 始まり・末尾スラッシュなしに正規化する")
    func publicBaseURLNormalization() {
        #expect(ProfileValidator.normalizePublicBaseURL(" https://a.example.com/// ")
                == "https://a.example.com")
        #expect(ProfileValidator.isValidPublicBaseURL("https://a.example.com"))
        #expect(!ProfileValidator.isValidPublicBaseURL("http://a.example.com"))
        #expect(!ProfileValidator.isValidPublicBaseURL("a.example.com"))
    }

    /// SEC-05: r2.dev はレート制限付きで本番非推奨 → **警告**であってエラーではない
    @Test("V-05: *.r2.dev は警告になる（保存は妨げない）")
    func r2DevWarning() {
        let profile = TestSupport.sampleProfile(buckets: [
            BucketConfig(alias: "public", bucketName: "bucket-one", visibility: .publicBucket,
                         mountPath: "~/SkyFolder/x/public",
                         publicBaseURL: "https://pub-abc.r2.dev"),
        ])
        let issues = ProfileValidator.validate(profile, secretProvided: true)
        let r2dev = issues.first { $0.rule == "V-05" }
        #expect(r2dev?.severity == .warning)
        #expect(!ProfileValidator.hasBlockingErrors(issues.filter { $0.rule == "V-05" }))
    }

    @Test("V-06: public バケットに publicBaseURL がないとエラー")
    func publicRequiresBaseURL() {
        let profile = TestSupport.sampleProfile(buckets: [
            BucketConfig(alias: "public", bucketName: "bucket-one", visibility: .publicBucket,
                         mountPath: "~/SkyFolder/x/public", publicBaseURL: ""),
        ])
        let issues = ProfileValidator.validate(profile, secretProvided: true)
        #expect(issues.contains { $0.rule == "V-06" })
    }

    // MARK: - V-07 / E-11
    //
    // M-11 (2): rclone は上限超過をエラーにせず黙って 7 日に丸める。
    // アプリが検証しないと「8 日で発行できた」と誤認したまま 7 日で切れる URL を配ることになる。

    @Test("V-07: 期限の解釈", arguments: [
        ("1h", 3600), ("24h", 86400), ("7d", 604800), ("90m", 5400), ("3600s", 3600), ("120", 120),
    ])
    func parsesExpire(input: String, expected: Int) {
        #expect(ProfileValidator.parseExpire(input) == expected)
    }

    /// T-G24: 8 日を入力すると拒否される
    @Test("V-07 / E-11: 7 日を超える期限を拒否する")
    func rejectsTooLongExpire() {
        #expect(ProfileValidator.isValidExpire("7d"))
        #expect(!ProfileValidator.isValidExpire("8d"))
        #expect(!ProfileValidator.isValidExpire("169h"))
        #expect(ProfileValidator.maxExpireSeconds == 604800)
    }

    @Test("V-07: 1 分未満を拒否する")
    func rejectsTooShortExpire() {
        #expect(!ProfileValidator.isValidExpire("30s"))
        #expect(ProfileValidator.isValidExpire("60s"))
    }

    // MARK: - V-08

    /// DD-001 §10 のコスト制約。60 未満は Class A 課金が増える。
    @Test("V-08: dirCacheTime は 60 秒未満を拒否する")
    func rejectsShortDirCacheTime() {
        #expect(!ProfileValidator.isValidDirCacheTime(59))
        #expect(ProfileValidator.isValidDirCacheTime(60))

        var profile = TestSupport.sampleProfile()
        profile.advanced.dirCacheTimeSec = 30
        let issues = ProfileValidator.validate(profile, secretProvided: true)
        #expect(issues.contains { $0.rule == "V-08" })
    }

    // MARK: - V-09

    @Test("V-09: secret 未設定はエラー")
    func requiresSecret() {
        let issues = ProfileValidator.validate(TestSupport.sampleProfile(), secretProvided: false)
        #expect(issues.contains { $0.rule == "V-09" })
    }

    // MARK: - 許容範囲

    @Test("advanced の許容範囲を検証する")
    func advancedRanges() {
        var profile = TestSupport.sampleProfile()
        profile.advanced.vfsCacheMaxSizeGB = 100
        profile.advanced.vfsWriteBackSec = 1
        profile.advanced.transfers = 32
        let issues = ProfileValidator.validate(profile, secretProvided: true)
        #expect(issues.contains { $0.rule == "V-10" })
        #expect(issues.contains { $0.rule == "V-11" })
        #expect(issues.contains { $0.rule == "V-12" })
    }

    @Test("正しいプロファイルはブロッキングエラーを出さない")
    func validProfilePasses() {
        let issues = ProfileValidator.validate(TestSupport.sampleProfile(), secretProvided: true)
        #expect(!ProfileValidator.hasBlockingErrors(issues), "\(issues)")
    }

    // MARK: - V-03b

    @Test("既定 mountPath はプロダクト名 + slug + alias で組み立てる")
    func defaultMountPath() {
        let profile = TestSupport.sampleProfile()
        #expect(ProfileValidator.defaultMountPath(profile: profile, alias: "private")
                == "~/SkyFolder/fracturelab/private")
    }
}
