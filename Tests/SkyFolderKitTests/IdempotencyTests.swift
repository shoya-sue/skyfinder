import Foundation
import Testing
@testable import SkyFolderKit

@Suite("RC API の冪等性判定（§8.6.1）")
struct RcErrorIdempotencyTests {

    /// `mount/mount` の 2 回目。実測のメッセージそのままで判定できること。
    /// nfsmount でも「FUSE」と表示される（M-07）— この文言を見て macFUSE の問題と誤診断しない。
    /// 判定は**末尾の実体**（exit status 78）で行う。
    @Test("already mounted / exit status 78 を成功として扱う")
    func alreadyMounted() {
        let measured = RcError(
            path: "mount/mount", statusCode: 500,
            message: "failed to mount FUSE fs: mount: localhost:/ is already mounted at "
                + "/Users/x/SkyFolder/a: failed to mount NFS volume: exit status 78")
        #expect(measured.meansAlreadyMounted)
        #expect(RcError(path: "mount/mount", statusCode: 500,
                        message: "exit status 78").meansAlreadyMounted)
        #expect(!RcError(path: "mount/mount", statusCode: 500,
                         message: "no such host").meansAlreadyMounted)
    }

    /// `mount/unmount` の 2 回目 / 存在しないパス。実測: `"mount not found"` / HTTP 500
    @Test("mount not found を成功として扱う")
    func mountNotFound() {
        #expect(RcError(path: "mount/unmount", statusCode: 500,
                        message: "mount not found").meansMountNotFound)
        #expect(!RcError(path: "mount/unmount", statusCode: 500,
                         message: "permission denied").meansMountNotFound)
    }

    /// 実測（本実装で確認）: 存在しないキーへの deletefile は **HTTP 404 / `object not found`**。
    /// 接続テストの後片付けと staging の掃除で重複実行が起こりうるため、成功扱いにする。
    @Test("object not found を成功として扱う")
    func objectNotFound() {
        let measured = RcError(path: "operations/deletefile", statusCode: 404,
                               message: "object not found")
        #expect(measured.meansObjectNotFound)
        #expect(!RcError(path: "operations/deletefile", statusCode: 403,
                         message: "AccessDenied").meansObjectNotFound)
    }

    /// E-06 / E-07 の区別。誤診断を生む導線を作らない（DD-001 F-01）。
    @Test("認証エラーとバケット不存在を区別する")
    func classifiesErrors() {
        let forbidden = RcError(path: "operations/list", statusCode: 403,
                                message: "AccessDenied: Access Denied")
        #expect(forbidden.meansForbidden)
        #expect(!forbidden.meansBucketNotFound)

        let missing = RcError(path: "operations/list", statusCode: 404,
                              message: "NoSuchBucket: The specified bucket does not exist")
        #expect(missing.meansBucketNotFound)

        let (message, id) = ConnectionTest.classify(missing, bucketName: "flab-stor-private")
        #expect(id == "E-07")
        #expect(message.contains("flab-stor-private"))

        let (message2, id2) = ConnectionTest.classify(forbidden, bucketName: "flab-stor-private")
        #expect(id2 == "E-06")
        // 「トークンを作り直せ」ではなく「権限とバケット名を確認」の文言であること（T-G08）
        #expect(message2.contains("権限"))
        #expect(!message2.contains("作り直"))
    }

    /// M-11 (3): ディレクトリは共有できない
    @Test("ディレクトリ共有のエラーを識別する")
    func cantShareDirectories() {
        #expect(RcError(path: "operations/publiclink", statusCode: 500,
                        message: "can't share directories").meansCantShareDirectories)
    }
}

@Suite("マウントオプションの組み立て（§6.2 / G-08）")
struct MountOptionsTests {

    private let advanced = AdvancedSettings()
    private let privateBucket = BucketConfig(alias: "private", bucketName: "b1",
                                             visibility: .privateBucket, mountPath: "~/x/1")
    private let publicBucket = BucketConfig(alias: "public", bucketName: "b2",
                                            visibility: .publicBucket, mountPath: "~/x/2",
                                            publicBaseURL: "https://files.example.com")

    /// CRIT-01: mountType を省略すると cmount が選ばれ、macFUSE 未導入の環境では失敗する。
    @Test("CRIT-01: mountType を必ず明示する")
    func alwaysSpecifiesMountType() {
        let params = MountOptionsBuilder.mountParams(bucket: privateBucket, advanced: advanced,
                                                     resolvedMountPoint: "/tmp/x")
        #expect(params["mountType"] as? String == "nfsmount")
    }

    /// U-02: Duration / SizeSuffix はナノ秒 / バイトの**整数**で渡す（文字列にしない）
    @Test("U-02: 時間とサイズは整数で渡す")
    func usesNumericDurations() {
        let vfs = MountOptionsBuilder.vfsOpt(for: privateBucket, advanced: advanced)
        #expect(vfs["WriteBack"] as? Int64 == 15_000_000_000)        // 15s
        #expect(vfs["DirCacheTime"] as? Int64 == 60_000_000_000)     // 60s
        #expect(vfs["CacheMaxSize"] as? Int64 == 10_737_418_240)     // 10GB
        #expect(vfs["CacheMaxAge"] as? Int64 == 259_200_000_000_000) // 72h
        #expect(vfs["ChunkSize"] as? Int64 == 16_777_216)            // 16M
        #expect(vfs["ChunkSizeLimit"] as? Int64 == 536_870_912)      // 512M

        let mount = MountOptionsBuilder.mountOpt(for: privateBucket)
        #expect(mount["AttrTimeout"] as? Int64 == 5_000_000_000)     // 5s
        #expect(mount["VolumeName"] as? String == "SkyFolder-private")

        // 文字列で渡していないこと（"15s" のような表記になっていない）
        #expect(!(vfs["WriteBack"] is String))
    }

    /// G-08: read-only は visibility から**自動導出**する。独立フィールドとして持たない。
    @Test("G-08: public は read-only、private は read-write")
    func derivesReadOnlyFromVisibility() {
        let publicOpt = MountOptionsBuilder.vfsOpt(for: publicBucket, advanced: advanced)
        let privateOpt = MountOptionsBuilder.vfsOpt(for: privateBucket, advanced: advanced)
        #expect(publicOpt["ReadOnly"] as? Bool == true)
        #expect(privateOpt["ReadOnly"] as? Bool == false)
    }

    /// 覆せるのは advanced.allowDirectWriteToPublic のみ
    @Test("G-08: allowDirectWriteToPublic だけが read-only を覆せる")
    func allowDirectWriteOverrides() {
        var overridden = AdvancedSettings()
        overridden.allowDirectWriteToPublic = true
        let opt = MountOptionsBuilder.vfsOpt(for: publicBucket, advanced: overridden)
        #expect(opt["ReadOnly"] as? Bool == false)
        // private は影響を受けない
        #expect(MountOptionsBuilder.vfsOpt(for: privateBucket,
                                           advanced: overridden)["ReadOnly"] as? Bool == false)
    }

    /// D-05: CacheMode は full 固定。PollInterval は 0（S3 は変更通知非対応）
    @Test("D-05: CacheMode は full、PollInterval は 0")
    func fixedValues() {
        let vfs = MountOptionsBuilder.vfsOpt(for: privateBucket, advanced: advanced)
        #expect(vfs["CacheMode"] as? String == "full")
        #expect(vfs["PollInterval"] as? Int == 0)
    }

    /// §6.3 第 1 層 / U-08: _filter で ExcludeRule を渡す
    @Test("K-04: 除外パターンを _filter で渡す")
    func passesExcludeRules() {
        let params = MountOptionsBuilder.mountParams(bucket: privateBucket, advanced: advanced,
                                                     resolvedMountPoint: "/tmp/x")
        let filter = params["_filter"] as? [String: Any]
        let rules = filter?["ExcludeRule"] as? [String]
        #expect(rules?.contains(".DS_Store") == true)
        #expect(rules?.contains("._*") == true)
    }

    @Test("fs はバケット名つきで組み立てる（DD-001 F-01）")
    func fsIncludesBucketName() {
        let params = MountOptionsBuilder.mountParams(bucket: privateBucket, advanced: advanced,
                                                     resolvedMountPoint: "/tmp/x")
        #expect(params["fs"] as? String == "r2:b1")
        // バケット名なしの "r2:" を渡してはならない
        #expect(params["fs"] as? String != "r2:")
    }
}

@Suite("rcd のポート取得（M-12）")
struct RcdPortReaderTests {

    /// §6.1 が必須としている --log-file を指定すると、
    /// `Serving remote control on ...` は stdout でも stderr でもなくログファイルに出る。
    @Test("ログ行からポートを取り出す")
    func parsesPort() {
        let line = "2026/08/31 16:21:14 NOTICE: Serving remote control on http://127.0.0.1:54681/"
        #expect(RcdPortReader.parsePort(in: line) == 54681)
    }

    @Test("localhost 表記も受ける")
    func parsesLocalhost() {
        #expect(RcdPortReader.parsePort(in: "Serving remote control on http://localhost:1234/")
                == 1234)
    }

    @Test("該当行がなければ nil")
    func returnsNilWhenAbsent() {
        #expect(RcdPortReader.parsePort(in: "INFO: Using --user abc --pass XXXX") == nil)
    }

    /// 起動前のサイズから後ろだけを読む。
    /// これをしないと前回起動時の古いポートを掴む（CRIT-03 と同種の事故）。
    @Test("起動前に書かれていた古いポートを拾わない")
    func ignoresPreviousRun() throws {
        let dir = TestSupport.makeTemporaryDirectory("portreader")
        defer { TestSupport.remove(dir) }
        let log = dir.appendingPathComponent("rcd.log")

        try "NOTICE: Serving remote control on http://127.0.0.1:11111/\n"
            .write(to: log, atomically: true, encoding: .utf8)

        // ここでリーダーを作る（= 起動直前）
        let reader = RcdPortReader(logFile: log)
        #expect(reader.tryRead() == nil, "起動前の行を読んではいけない")

        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("NOTICE: Serving remote control on http://127.0.0.1:22222/\n".utf8))
        try handle.close()

        #expect(reader.tryRead() == 22222)
    }
}

@Suite("バージョン比較（§8.1 手順 3）")
struct VersionComparisonTests {

    @Test("v1.68 以上を判定する", arguments: [
        ("v1.75.0", true), ("v1.68.0", true), ("v1.68", true),
        ("v1.67.9", false), ("v1.5.0", false), ("v2.0.0", true),
    ])
    func compares(found: String, expected: Bool) {
        #expect(RcdSupervisor.versionAtLeast(found, "1.68") == expected)
    }
}
