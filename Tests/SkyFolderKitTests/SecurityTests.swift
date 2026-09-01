import Foundation
import Testing
@testable import SkyFolderKit

@Suite("rcd 起動仕様（SEC-G01 / SEC-G02 / §6.1）")
struct RcdLaunchSpecTests {

    private func makeSpec() -> RcdLaunchSpec {
        RcdLaunchSpec(rcloneURL: URL(fileURLWithPath: "/tmp/rclone"),
                      profile: TestSupport.sampleProfile(),
                      credentials: R2Credentials(accessKeyId: "AKIA_TEST_KEY_ID_VALUE",
                                                 secretAccessKey: "s3cr3t-value-must-not-leak"),
                      paths: AppPaths(home: URL(fileURLWithPath: "/tmp/home")))
    }

    /// T-G04: `ps aux` で見えるのはコマンドライン引数。
    /// **Secret Access Key・`--rc-user` / `--rc-pass` の値のいずれも含まれていないこと。**
    /// `--rc-user` という文字列自体が引数に現れないことも確認する。
    @Test("T-G04: 引数に秘密情報が一切現れない")
    func argumentsContainNoSecrets() {
        let spec = makeSpec()
        let joined = spec.arguments.joined(separator: " ")

        #expect(!joined.contains("s3cr3t-value-must-not-leak"))
        #expect(!joined.contains("AKIA_TEST_KEY_ID_VALUE"))
        #expect(!joined.contains(spec.rcUser))
        #expect(!joined.contains(spec.rcPassword))
        // 文字列自体が現れないこと
        #expect(!joined.contains("--rc-user"))
        #expect(!joined.contains("--rc-pass"))
    }

    /// SEC-G01: rc-user / rc-pass は環境変数から注入する
    @Test("rc の認証情報は環境変数に入る")
    func credentialsGoToEnvironment() {
        let spec = makeSpec()
        #expect(spec.environment["RCLONE_RC_USER"] == spec.rcUser)
        #expect(spec.environment["RCLONE_RC_PASS"] == spec.rcPassword)
        #expect(spec.rcUser.count == 24)
        #expect(spec.rcPassword.count == 32)
    }

    /// SEC-G01 (b): バインドアドレスは 127.0.0.1 に限定し 0.0.0.0 にしてはならない。
    /// ポートを固定しない（:0）のは、他プロセスが待ち構えることを困難にするため。
    @Test("待受は 127.0.0.1:0 に限定される")
    func bindsToLoopbackWithEphemeralPort() {
        let spec = makeSpec()
        guard let index = spec.arguments.firstIndex(of: "--rc-addr") else {
            Issue.record("--rc-addr がない"); return
        }
        #expect(spec.arguments[index + 1] == "127.0.0.1:0")
        #expect(!spec.arguments.contains("--rc-no-auth"))
        #expect(!spec.arguments.joined().contains("0.0.0.0"))
    }

    /// §4.1 MUST: 既定の rclone.conf を読まない・書かない。設定ファイルは生成しない。
    @Test("--config は空文字を明示する")
    func configIsEmpty() {
        let spec = makeSpec()
        guard let index = spec.arguments.firstIndex(of: "--config") else {
            Issue.record("--config がない"); return
        }
        #expect(spec.arguments[index + 1] == "")
    }

    /// §6.1: --rc-serve は v1.0 では付けない（rc ポートでリモート内容の HTTP 配信が有効になるため）
    @Test("--rc-serve を付けない")
    func doesNotServeRemoteContent() {
        #expect(!makeSpec().arguments.contains("--rc-serve"))
    }

    /// U-01: 環境変数のみでリモートを定義する（G-04 第 1 案）
    @Test("S3 リモートを環境変数で定義する")
    func definesRemoteViaEnvironment() {
        let spec = makeSpec()
        #expect(spec.environment["RCLONE_CONFIG_R2_TYPE"] == "s3")
        #expect(spec.environment["RCLONE_CONFIG_R2_PROVIDER"] == "Cloudflare")
        #expect(spec.environment["RCLONE_CONFIG_R2_ACCESS_KEY_ID"] == "AKIA_TEST_KEY_ID_VALUE")
        #expect(spec.environment["RCLONE_CONFIG_R2_SECRET_ACCESS_KEY"] == "s3cr3t-value-must-not-leak")
        #expect(spec.environment["RCLONE_CONFIG_R2_ACL"] == "private")
        // DD-001 §6.2: バケット作成権限がないトークンで必須
        #expect(spec.environment["RCLONE_CONFIG_R2_NO_CHECK_BUCKET"] == "true")
        #expect(spec.environment["RCLONE_CONFIG_R2_ENDPOINT"]?
            .hasSuffix(".r2.cloudflarestorage.com") == true)
    }

    /// K-02: --no-unicode-normalization は既定 false のまま維持する。
    /// 環境変数でもフラグでも変更しない。
    @Test("K-02: Unicode 正規化の設定を触らない")
    func doesNotTouchUnicodeNormalization() {
        let spec = makeSpec()
        #expect(spec.environment["RCLONE_NO_UNICODE_NORMALIZATION"] == nil)
        #expect(!spec.arguments.joined(separator: " ").contains("unicode-normalization"))
    }

    /// U-09: 既定値が既に 1000000 なので環境変数で渡さない
    @Test("U-09: nfs-cache-handle-limit を環境変数で渡さない")
    func doesNotSetHandleLimit() {
        #expect(makeSpec().environment["RCLONE_NFS_CACHE_HANDLE_LIMIT"] == nil)
    }

    /// SEC-G01: rc-user / rc-pass は**プロセス起動ごとの乱数**。
    ///
    /// これを「呼び出し側が毎回新しい spec を作る」慣習に依存させると、
    /// spec を外に括り出しただけで黙って破れる。構造で担保していることを固定する。
    @Test("SEC-G01: spec を使い回しても rc 認証情報は作り直される")
    func credentialsAreRegeneratedPerLaunch() {
        let spec = makeSpec()
        let again = spec.regeneratingCredentials()

        #expect(again.rcUser != spec.rcUser)
        #expect(again.rcPassword != spec.rcPassword)
        // 環境変数にも反映されていること（プロセスに渡るのはこちら）
        #expect(again.environment["RCLONE_RC_USER"] == again.rcUser)
        #expect(again.environment["RCLONE_RC_PASS"] == again.rcPassword)
        #expect(again.environment["RCLONE_RC_USER"] != spec.rcUser)

        // R2 の認証情報は変えない（変えたら接続できなくなる）
        #expect(again.environment["RCLONE_CONFIG_R2_ACCESS_KEY_ID"]
                == spec.environment["RCLONE_CONFIG_R2_ACCESS_KEY_ID"])
        #expect(again.environment["RCLONE_CONFIG_R2_SECRET_ACCESS_KEY"]
                == spec.environment["RCLONE_CONFIG_R2_SECRET_ACCESS_KEY"])
        // 引数も変わらない
        #expect(again.arguments == spec.arguments)
        #expect(again.executableURL == spec.executableURL)
    }

    /// §6.2 注入経路表: 環境変数で渡す設定は rcd の起動時にしか反映できない。
    /// 変わったかどうかを判定できないと、「設定を保存したのに効かない」状態になる。
    @Test("再起動が要る設定の変更を指紋で検出できる")
    func detectsSettingsThatRequireRestart() {
        let base = makeSpec()

        // rc-user / rc-pass は毎回変わるが、それでは再起動しない
        #expect(base.regeneratingCredentials().restartSignature == base.restartSignature)

        // accountId が変わったら再起動が要る
        var other = TestSupport.sampleProfile()
        other.accountId = String(repeating: "ffffffff", count: 4)
        let changedAccount = RcdLaunchSpec(
            rcloneURL: URL(fileURLWithPath: "/tmp/rclone"), profile: other,
            credentials: R2Credentials(accessKeyId: "AKIA_TEST_KEY_ID_VALUE",
                                       secretAccessKey: "s3cr3t-value-must-not-leak"),
            paths: AppPaths(home: URL(fileURLWithPath: "/tmp/home")))
        #expect(changedAccount.restartSignature != base.restartSignature)

        // 認証情報が変わったら再起動が要る
        let changedSecret = RcdLaunchSpec(
            rcloneURL: URL(fileURLWithPath: "/tmp/rclone"), profile: TestSupport.sampleProfile(),
            credentials: R2Credentials(accessKeyId: "AKIA_TEST_KEY_ID_VALUE",
                                       secretAccessKey: "rotated-secret-value"),
            paths: AppPaths(home: URL(fileURLWithPath: "/tmp/home")))
        #expect(changedSecret.restartSignature != base.restartSignature)

        // transfers（環境変数）が変わったら再起動が要る
        var faster = TestSupport.sampleProfile()
        faster.advanced.transfers = 16
        let changedTransfers = RcdLaunchSpec(
            rcloneURL: URL(fileURLWithPath: "/tmp/rclone"), profile: faster,
            credentials: R2Credentials(accessKeyId: "AKIA_TEST_KEY_ID_VALUE",
                                       secretAccessKey: "s3cr3t-value-must-not-leak"),
            paths: AppPaths(home: URL(fileURLWithPath: "/tmp/home")))
        #expect(changedTransfers.restartSignature != base.restartSignature)

        // vfsOpt で渡す設定（mount/mount ごとに渡す）は再起動が要らない
        var biggerCache = TestSupport.sampleProfile()
        biggerCache.advanced.vfsCacheMaxSizeGB = 40
        biggerCache.advanced.vfsWriteBackSec = 45
        biggerCache.advanced.dirCacheTimeSec = 120
        let changedVfs = RcdLaunchSpec(
            rcloneURL: URL(fileURLWithPath: "/tmp/rclone"), profile: biggerCache,
            credentials: R2Credentials(accessKeyId: "AKIA_TEST_KEY_ID_VALUE",
                                       secretAccessKey: "s3cr3t-value-must-not-leak"),
            paths: AppPaths(home: URL(fileURLWithPath: "/tmp/home")))
        #expect(changedVfs.restartSignature == base.restartSignature,
                "vfsOpt の変更で不要な再起動が起きる")
    }

    /// §6.2 注入経路表
    @Test("グローバル / S3 のオプションは環境変数で渡す")
    func globalOptionsGoToEnvironment() {
        let spec = makeSpec()
        #expect(spec.environment["RCLONE_TRANSFERS"] == "8")
        #expect(spec.environment["RCLONE_S3_CHUNK_SIZE"] == "64M")
        #expect(spec.environment["RCLONE_S3_UPLOAD_CUTOFF"] == "128M")
    }
}

@Suite("ログのマスク（SEC-G04）")
struct LogMaskerTests {

    /// T-G27: Secret Access Key・presigned URL の署名部分が含まれていないこと
    @Test("secret と Access Key をマスクする")
    func masksSecrets() {
        let masker = LogMasker(secrets: ["AKIA_TEST_KEY", "s3cr3t-value"])
        let masked = masker.mask("key=AKIA_TEST_KEY secret=s3cr3t-value")
        #expect(!masked.contains("AKIA_TEST_KEY"))
        #expect(!masked.contains("s3cr3t-value"))
    }

    /// M-04: rclone は `Using --user {rc-user} --pass XXXX` を出力し、
    /// パスワードはマスクされるが**ユーザー名は平文**で出る。
    @Test("M-04: 起動ログの rc-user をマスクする（実値を知らなくても）")
    func masksRcUserFromLogPattern() {
        let masked = LogMasker().mask(
            "2026/08/31 16:21:14 INFO  : Using --user u57744 --pass XXXX as authenticated user")
        #expect(!masked.contains("u57744"))
        #expect(masked.contains("Using --user ***"))
    }

    /// M-06: S3 操作の失敗時にエラー本文へ endpoint（= accountId）が含まれる
    @Test("M-06: accountId 由来の endpoint をマスクする")
    func masksAccountEndpoint() {
        let account = String(repeating: "0123abcd", count: 4)
        let masked = LogMasker().mask(
            "operation error S3: Get \"https://\(account).r2.cloudflarestorage.com/bucket?list-type=2\"")
        #expect(!masked.contains(account))
        #expect(masked.contains("{account-id}"))
        // 診断の役には立つため完全な削除はしない
        #expect(masked.contains("r2.cloudflarestorage.com"))
    }

    /// SEC-G05 / T-G27: presigned URL の署名部分
    @Test("presigned URL の署名をマスクする")
    func masksSignature() {
        let url = "https://acct.r2.cloudflarestorage.com/b/k?X-Amz-Algorithm=AWS4-HMAC-SHA256"
            + "&X-Amz-Credential=AKIAX%2F20260831&X-Amz-Signature=deadbeefcafe1234"
        let masked = LogMasker().mask(url)
        #expect(!masked.contains("deadbeefcafe1234"))
        #expect(!masked.contains("AKIAX%2F20260831"))
        #expect(masked.contains("X-Amz-Signature=***"))
        // URL 自体は残す
        #expect(masked.contains("X-Amz-Algorithm=AWS4-HMAC-SHA256"))
    }

    @Test("短すぎるリテラルは本文を壊さない")
    func ignoresShortLiterals() {
        let masker = LogMasker(secrets: ["ab"])
        #expect(masker.mask("about") == "about")
    }

    @Test("マスク漏れを自己検査できる")
    func selfCheck() {
        let masker = LogMasker(secrets: ["s3cr3t-value"])
        #expect(masker.containsSecret("secret=s3cr3t-value"))
        #expect(!masker.containsSecret(masker.mask("secret=s3cr3t-value")))
    }
}

@Suite("乱数トークン（SEC-G01）")
struct RandomTokenTests {

    @Test("要求した長さで生成される")
    func hasRequestedLength() {
        #expect(RandomToken.make(length: 24).count == 24)
        #expect(RandomToken.make(length: 32).count == 32)
    }

    @Test("毎回異なる値になる")
    func isRandom() {
        let values = Set((0..<50).map { _ in RandomToken.make(length: 24) })
        #expect(values.count == 50)
    }

    @Test("ULID は時刻順に並び、毎回異なる")
    func ulidOrdering() {
        let a = ULID.generate(now: Date(timeIntervalSince1970: 1_000_000))
        let b = ULID.generate(now: Date(timeIntervalSince1970: 2_000_000))
        #expect(a < b)
        #expect(a.hasPrefix("prof_"))
        #expect(Set((0..<50).map { _ in ULID.generate() }).count == 50)
    }
}

@Suite("E-14 の検知（read-only への書込み試行）")
struct LogWatcherTests {

    private func detections(from log: String) async -> [LogWatcher.Detection] {
        let dir = TestSupport.makeTemporaryDirectory("logwatch")
        defer { TestSupport.remove(dir) }
        let file = dir.appendingPathComponent("rcd.log")
        FileManager.default.createFile(atPath: file.path, contents: nil)

        let watcher = LogWatcher(logFile: file)
        let collected = Mutex<[LogWatcher.Detection]>([])
        watcher.start { detection in
            collected.set(collected.get() + [detection])
        }
        watcher.setReadOnlyMounts(["public": "/Users/x/SkyFolder/p/public"])
        // 監視は「起動後に追記された分」だけを見る
        try? await Task.sleep(nanoseconds: 200_000_000)
        if let handle = try? FileHandle(forWritingTo: file) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(log.utf8))
            try? handle.close()
        }
        try? await Task.sleep(nanoseconds: 600_000_000)
        watcher.stop()
        return collected.get()
    }

    /// 実測（M-17）: INFO レベルで出るのはこの 1 行だけ
    @Test("実測どおりの行を検知する")
    func detectsMeasuredLine() async {
        let found = await detections(
            from: "2026/08/31 19:23:24 ERROR : nfs: Error Creating: Read only file system\n")
        #expect(found.count == 1, "検知できていない: \(found)")
    }

    /// 設計書 M-02 が挙げる errno はログには出ない。
    /// これらを検知語にしても発火しないことを、意図として固定しておく。
    @Test("クライアント側の errno 文言では発火しない")
    func doesNotFireOnClientErrno() async {
        let found = await detections(from: """
        2026/08/31 19:23:24 INFO  : something permission denied happened
        2026/08/31 19:23:24 INFO  : Input/output error occurred
        """)
        #expect(found.isEmpty, "ログに出ない文言で発火した: \(found)")
    }

    /// Finder が勝手に作るメタデータファイルの拒否で通知しない（DD-001 R-10 / R-G05）。
    /// これを弾かないと、公開マウントを開くだけで警告が鳴り続ける。
    @Test("AppleDouble / .DS_Store の拒否では通知しない")
    func ignoresSystemMetadata() async {
        let found = await detections(from: """
        2026/08/31 19:23:27 DEBUG : ._existing.txt: >Create: <nil>, err=Read only file system
        2026/08/31 19:23:27 ERROR : nfs: Error Creating: Read only file system
        2026/08/31 19:23:27 DEBUG : .DS_Store: >Create: <nil>, err=Read only file system
        """)
        // 2 行目（ファイル名を含まない汎用行）だけが残る
        #expect(found.count == 1, "\(found.map(\.line))")
        #expect(!found.contains { $0.line.contains("._") })
        #expect(!found.contains { $0.line.contains(".DS_Store") })
    }

    @Test("無関係な行では発火しない")
    func ignoresUnrelatedLines() async {
        let found = await detections(from: """
        2026/08/31 19:23:24 NOTICE: Serving remote control on http://127.0.0.1:1234/
        2026/08/31 19:23:24 INFO  : Using --user abc --pass XXXX as authenticated user
        """)
        #expect(found.isEmpty)
    }
}

@Suite("独立レビューで指摘された経路（回帰防止）")
struct ReviewFindingsTests {

    /// SEC-G03（MUST）: **永続的なオプトアウト設定を提供しない。**
    ///
    /// 設定画面のトグルを消すだけでは、profiles.json を手で書き換えたり
    /// 古い版が書いた false が残っていたりすると復活する。値を読まないことで構造的に守る。
    @Test("SEC-G03: 永続化された stripImageMetadata=false を読まない")
    func stripImageMetadataIsAlwaysOn() throws {
        #expect(ShareSettings().stripImageMetadata)

        // 過去の版が書いた false が残っていても true として読む
        let json = """
        {"defaultExpire":"24h","stripImageMetadata":false,
         "publicKeyTemplate":"{prefix}/{yyyy}/{slug}.{ext}",
         "defaultPrefix":"assets","immutableCacheControl":false}
        """
        let decoded = try JSONDecoder().decode(ShareSettings.self, from: Data(json.utf8))
        #expect(decoded.stripImageMetadata, "永続化された false を読んでしまっている")
    }

    /// SEC-G06 (a): `kSecAttrAccessibleWhenUnlocked` は **data protection keychain 専用**の属性。
    /// `kSecUseDataProtectionKeychain` を付けないと login.keychain へ行き、属性が解釈されない。
    ///
    /// ところがその指定は application-identifier entitlement を要求し、
    /// **Team ID の無いビルド（ad-hoc 署名・テストバンドル）では `errSecMissingEntitlement`** になる。
    /// そこで実装は「使えるなら data protection、駄目なら legacy」に落ちる。
    /// **落ちたことが分かること**が要件 — 黙って落ちると SEC-G06(a) の未達が見えなくなる。
    @Test("SEC-G06: 使えるモードを選び、どちらを使ったか分かる")
    func keychainModeIsObservable() throws {
        let store = KeychainStore(service: "dev.fracturelab.skyfolder.tests.dpk")
        let account = "dpk.\(UUID().uuidString)"
        defer { try? store.delete(account: account) }

        // entitlement が無くても保存できること（アプリが使えなくなってはいけない）
        try store.write("value", account: account)
        #expect(try store.read(account: account) == "value")

        // どちらを使ったかが外から分かること
        #expect(store.activeMode != .undetermined)
        #expect(store.activeMode.satisfiesLockProtection == (store.activeMode == .dataProtection))

        // ソース上で両方の指定が残っていること（片方を消すと無言で要件が落ちる）
        let source = try String(
            contentsOf: TestSupport.repoRoot
                .appendingPathComponent("SkyFolder/Core/Store/KeychainStore.swift"),
            encoding: .utf8)
        #expect(source.contains("kSecUseDataProtectionKeychain"))
        #expect(source.contains("kSecAttrAccessibleWhenUnlocked"))
    }

    /// SEC-G04: マスク対象のリテラルは、リモート名を変えても取り出せること。
    /// キーを直書きすると、名前を変えた瞬間に**無言で空配列**になりマスクが外れる。
    @Test("SEC-G04: secretValues がリモート名から組み立てられる")
    func secretValuesUseRemoteName() {
        let spec = RcdLaunchSpec(
            rcloneURL: URL(fileURLWithPath: "/tmp/rclone"),
            profile: TestSupport.sampleProfile(),
            credentials: R2Credentials(accessKeyId: "AKIA_MASK_ME",
                                       secretAccessKey: "SECRET_MASK_ME"),
            paths: AppPaths(home: URL(fileURLWithPath: "/tmp/home")))

        #expect(spec.secretValues.contains("AKIA_MASK_ME"))
        #expect(spec.secretValues.contains("SECRET_MASK_ME"))
        #expect(spec.secretValues.contains(spec.rcPassword))
        #expect(spec.maskableUserNames == [spec.rcUser])

        // 実際にマスクを構成すると、すべて消えること
        let masker = LogMasker(secrets: spec.secretValues, rcUsers: spec.maskableUserNames)
        let line = "key=AKIA_MASK_ME secret=SECRET_MASK_ME pass=\(spec.rcPassword) user=\(spec.rcUser)"
        let masked = masker.mask(line)
        #expect(!masked.contains("AKIA_MASK_ME"))
        #expect(!masked.contains("SECRET_MASK_ME"))
        #expect(!masked.contains(spec.rcPassword))
        #expect(!masked.contains(spec.rcUser))
    }

    /// G5-3: 公証はバンドル内のすべての署名に secure timestamp を要求する。
    /// 同梱バイナリを `--timestamp=none` で署名すると Developer ID でも公証が落ちる。
    @Test("G5-3: Developer ID 署名時は secure timestamp を打つ")
    func signingUsesSecureTimestampForDeveloperID() throws {
        let spec = try String(
            contentsOf: TestSupport.repoRoot.appendingPathComponent("project.yml"),
            encoding: .utf8)
        // ad-hoc のときだけ timestamp を省く分岐になっていること
        #expect(spec.contains("--timestamp=none --sign -"))
        #expect(spec.contains("--timestamp \\"))
        #expect(spec.contains("EXPANDED_CODE_SIGN_IDENTITY"))
    }
}
