import Foundation

/// G1-9「実アカウントでの通し確認」を 1 コマンドで実行する。
///
/// 設計書 §11 G1-9 は、S3（R2）固有の挙動が**まだ一度も確認されていない**ため
/// 「省略して G2 へ進んではならない」と規定している。
/// ここではその 8 項目を、アプリ本体と同じコード経路（`RcdLaunchSpec` → `RcClient`）で実行する。
///
/// 実行方法:
/// ```
/// SKYFOLDER_ACCOUNT_ID=... SKYFOLDER_ACCESS_KEY_ID=... SKYFOLDER_SECRET_ACCESS_KEY=... \
/// SKYFOLDER_PRIVATE_BUCKET=... [SKYFOLDER_PUBLIC_BUCKET=... SKYFOLDER_PUBLIC_BASE_URL=...] \
/// SkyFolder.app/Contents/MacOS/SkyFolder --verify-r2
/// ```
public enum R2Verification {

    public struct Input: Sendable {
        public var accountId: String
        public var accessKeyId: String
        public var secretAccessKey: String
        public var privateBucket: String
        public var publicBucket: String?
        public var publicBaseURL: String?
        /// ② マルチパート（128MB 超）。時間と転送量がかかるので既定では実行しない。
        public var runMultipart: Bool
        /// ④ presigned の失効確認は 61 秒待つ。
        public var runExpiryWait: Bool

        public static func fromEnvironment() -> Input? {
            let env = ProcessInfo.processInfo.environment
            func value(_ key: String) -> String? {
                env[key].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .flatMap { $0.isEmpty ? nil : $0 }
            }
            guard let accountId = value("SKYFOLDER_ACCOUNT_ID"),
                  let accessKeyId = value("SKYFOLDER_ACCESS_KEY_ID"),
                  let secret = value("SKYFOLDER_SECRET_ACCESS_KEY"),
                  let privateBucket = value("SKYFOLDER_PRIVATE_BUCKET")
            else { return nil }
            return Input(accountId: accountId,
                         accessKeyId: accessKeyId,
                         secretAccessKey: secret,
                         privateBucket: privateBucket,
                         publicBucket: value("SKYFOLDER_PUBLIC_BUCKET"),
                         publicBaseURL: value("SKYFOLDER_PUBLIC_BASE_URL"),
                         runMultipart: value("SKYFOLDER_RUN_MULTIPART") == "1",
                         runExpiryWait: value("SKYFOLDER_RUN_EXPIRY_WAIT") != "0")
        }

        public static let usage = """
        G1-9（実 R2 アカウントでの通し確認）を実行します。次の環境変数が要ります:

          SKYFOLDER_ACCOUNT_ID          Cloudflare の Account ID（32 桁）
          SKYFOLDER_ACCESS_KEY_ID       R2 API トークンの Access Key ID
          SKYFOLDER_SECRET_ACCESS_KEY   同 Secret Access Key
          SKYFOLDER_PRIVATE_BUCKET      非公開バケット名

        任意:
          SKYFOLDER_PUBLIC_BUCKET       公開バケット名（⑤ Cache-Control の確認に使う）
          SKYFOLDER_PUBLIC_BASE_URL     公開用ドメイン（https://…・末尾スラッシュなし）
          SKYFOLDER_RUN_MULTIPART=1     ② 128MB のマルチパートも実行する（時間と転送量がかかる）
          SKYFOLDER_RUN_EXPIRY_WAIT=0   ④ の 61 秒待ちを省略する

        トークンは Object Read & Write 権限・対象バケット限定で発行してください（SEC-01）。
        テスト用のオブジェクトは `.skyfolder-probe-*` の名前で作成し、実行後に削除します。
        """
    }

    public struct Check: Sendable {
        public let id: String
        public let name: String
        public let passed: Bool
        public let detail: String
        /// 設計書の記述と食い違った場合の注記
        public let deviation: String?

        init(_ id: String, _ name: String, _ passed: Bool, _ detail: String,
             deviation: String? = nil) {
            self.id = id; self.name = name; self.passed = passed
            self.detail = detail; self.deviation = deviation
        }
    }

    // MARK: - 実行

    public static func run(input: Input, rcloneURL: URL) async -> [Check] {
        var checks: [Check] = []
        func add(_ c: Check) { checks.append(c) }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(AppIdentity.bundleIdentifier).r2verify.\(UUID().uuidString)",
                                    isDirectory: true)
        try? AppPaths.ensureDirectory(work, mode: 0o700)
        defer { try? FileManager.default.removeItem(at: work) }

        let logFile = work.appendingPathComponent("rcd.log")
        FileManager.default.createFile(atPath: logFile.path, contents: nil)

        let profile = Profile(displayName: "verify",
                              accountId: input.accountId,
                              buckets: [BucketConfig(alias: "private",
                                                     bucketName: input.privateBucket,
                                                     visibility: .privateBucket,
                                                     mountPath: work.appendingPathComponent("mnt").path)])
        let paths = AppPaths(home: work)
        try? paths.ensureDirectories(profileId: profile.id)
        let supervisor = RcdSupervisor(rcloneURL: rcloneURL, paths: paths)
        let credentials = R2Credentials(accessKeyId: input.accessKeyId,
                                        secretAccessKey: input.secretAccessKey)

        let client: RcClient
        do {
            let endpoint = try await supervisor.start(specFactory: {
                RcdLaunchSpec(rcloneURL: rcloneURL, profile: profile,
                              credentials: credentials, paths: paths)
            })
            client = RcClient(endpoint: endpoint)
            add(Check("G1-9.0", "rcd を起動できる", true, "port=\(endpoint.port)"))
        } catch {
            add(Check("G1-9.0", "rcd を起動できる", false, String(describing: error)))
            await supervisor.stop()
            return checks
        }

        // **`defer` で止めてはいけない。** `defer` の中では `await` できないため
        // `Task { await supervisor.stop() }` と書くことになるが、それは
        // **停止の完了を待たずに `run` が返る**。呼び出し側（`SkyFolderApp.runCommandLine`）は
        // 戻り値を受け取った直後に `exit()` するので、停止用の Task が走り切る前に
        // プロセスが消え、**rcd が launchd に引き取られて孤児化する**
        // — CRIT-03 としてアプリ自身が警戒している状態を、検証ツールが確実に作る。
        //
        // したがって**すべての脱出経路で明示的に `await supervisor.stop()` を呼ぶ**。
        // 早期 return を足すときは、その直前に必ず入れること。

        let fs = AppIdentity.fs(bucketName: input.privateBucket)
        let probeKey = "\(AppIdentity.probeKeyPrefix)\(RandomToken.probeSuffix()).txt"
        let probeBody = "SkyFolder G1-9 verification\n"

        // ---- ① SigV4 署名の成立・実バケットへの読み書き ----
        do {
            _ = try await client.call(RcPath.operationsList,
                                      params: ["fs": fs, "remote": "", "opt": ["maxDepth": 1]],
                                      as: RcListResponse.self)
            add(Check("G1-9.1a", "SigV4 署名が成立し operations/list が通る", true, fs))
        } catch let error as RcError {
            add(Check("G1-9.1a", "SigV4 署名が成立し operations/list が通る", false, error.message))
            await supervisor.stop()
            return checks
        } catch {
            add(Check("G1-9.1a", "SigV4 署名が成立し operations/list が通る", false,
                      error.localizedDescription))
            await supervisor.stop()
            return checks
        }

        let localDir = work.appendingPathComponent("upload", isDirectory: true)
        try? AppPaths.ensureDirectory(localDir, mode: 0o700)
        try? Data(probeBody.utf8).write(to: localDir.appendingPathComponent(probeKey))

        do {
            try await client.callAsyncJob(RcPath.operationsCopyFile, params: [
                "srcFs": AppIdentity.localFs(directory: localDir.path), "srcRemote": probeKey,
                "dstFs": fs, "dstRemote": probeKey,
            ])
            add(Check("G1-9.1b", "実バケットへ書き込める", true, probeKey))
        } catch {
            add(Check("G1-9.1b", "実バケットへ書き込める", false, String(describing: error)))
        }

        // ---- ③ no_check_bucket の効果・権限境界 ----
        // アカウント全体の列挙はバケットスコープトークンでは失敗する（DD-001 F-01）。
        // **これは正常**であり、疎通判定に使ってはならない。ここでは「失敗すること」を確認する。
        do {
            _ = try await client.call(RcPath.operationsList,
                                      params: ["fs": "\(AppIdentity.remoteName.lowercased()):",
                                               "remote": ""],
                                      as: RcListResponse.self)
            add(Check("G1-9.3", "バケット名なしの列挙は権限境界の外（失敗するはず）", false,
                      "成功してしまった — Admin 権限のトークンの可能性がある（SEC-01: 非推奨）",
                      deviation: "バケットスコープのトークンを使ってください"))
        } catch {
            add(Check("G1-9.3", "バケット名なしの列挙が失敗する（DD-001 F-01 の前提）", true,
                      "疎通判定に使ってはならない経路であることを確認"))
        }

        // ---- ⑧ deletefile の冪等性 ----
        var deleteRaised: RcError?
        do {
            try await client.callRaw(RcPath.operationsDeleteFile,
                                     params: ["fs": fs, "remote": probeKey])
        } catch let error as RcError { deleteRaised = error } catch {}
        add(Check("G1-9.8a", "存在するキーを削除できる", deleteRaised == nil,
                  deleteRaised?.message ?? "OK"))

        var secondDelete: RcError?
        do {
            try await client.callRaw(RcPath.operationsDeleteFile,
                                     params: ["fs": fs, "remote": probeKey])
        } catch let error as RcError { secondDelete = error } catch {}
        if let secondDelete {
            add(Check("G1-9.8b", "存在しないキーの削除はエラーになる（成功扱いにする根拠）",
                      secondDelete.meansObjectNotFound,
                      "HTTP \(secondDelete.statusCode): \(secondDelete.message)"))
        } else {
            add(Check("G1-9.8b", "存在しないキーの削除", true,
                      "エラーにならなかった（S3 は 404 を返さない実装だった）",
                      deviation: "local で観測した 404 と挙動が違う。成功扱いの実装で問題ないが記録する"))
        }

        // ---- ④ U-13: presigned URL の実発行 ----
        let linkKey = "\(AppIdentity.probeKeyPrefix)\(RandomToken.probeSuffix()).txt"
        try? Data(probeBody.utf8).write(to: localDir.appendingPathComponent(linkKey))
        var linkUploaded = false
        do {
            try await client.callAsyncJob(RcPath.operationsCopyFile, params: [
                "srcFs": AppIdentity.localFs(directory: localDir.path), "srcRemote": linkKey,
                "dstFs": fs, "dstRemote": linkKey,
            ])
            linkUploaded = true
        } catch {}

        if linkUploaded {
            do {
                let response = try await client.call(
                    RcPath.operationsPublicLink,
                    params: ["fs": fs, "remote": linkKey, "expire": "1m"],
                    as: RcPublicLinkResponse.self)
                let url = response.url
                add(Check("G1-9.4a", "U-13: presigned URL を発行できる", true,
                          maskSignature(url)))
                // ホストが {accountId}.r2.cloudflarestorage.com 固定であること（D-04 / R-05）
                add(Check("G1-9.4b", "ホストはアカウントの endpoint 固定（カスタムドメイン不可）",
                          url.contains(".r2.cloudflarestorage.com"),
                          URL(string: url)?.host ?? "?"))

                if let u = URL(string: url), let (status, body) = await httpGet(u) {
                    add(Check("G1-9.4c", "発行直後の GET が 200 を返す", status == 200,
                              "HTTP \(status) / \(body.count) bytes"))
                } else {
                    add(Check("G1-9.4c", "発行直後の GET", false, "リクエストに失敗"))
                }

                if input.runExpiryWait {
                    try? await Task.sleep(nanoseconds: 61_000_000_000)
                    if let u = URL(string: url), let (status, _) = await httpGet(u) {
                        add(Check("G1-9.4d", "61 秒後の GET が 403 になる", status == 403,
                                  "HTTP \(status)"))
                    } else {
                        add(Check("G1-9.4d", "61 秒後の GET", false, "リクエストに失敗"))
                    }
                } else {
                    add(Check("G1-9.4d", "61 秒後の失効確認", false,
                              "SKYFOLDER_RUN_EXPIRY_WAIT=0 のため省略（未検証）"))
                }
            } catch let error as RcError {
                add(Check("G1-9.4a", "U-13: presigned URL を発行できる", false, error.message))
            } catch {
                add(Check("G1-9.4a", "U-13: presigned URL を発行できる", false,
                          error.localizedDescription))
            }

            // M-11 (2): 8 日を指定すると黙って 7 日に丸められる（エラーにならない）
            do {
                let response = try await client.call(
                    RcPath.operationsPublicLink,
                    params: ["fs": fs, "remote": linkKey, "expire": "8d"],
                    as: RcPublicLinkResponse.self)
                let expires = expiresParameter(of: response.url)
                add(Check("M-11(2)", "8 日指定はエラーにならず 7 日に丸められる", true,
                          "X-Amz-Expires=\(expires ?? "?")（604800 なら 7 日に丸め）",
                          deviation: expires == "604800" ? nil
                              : "丸めが観測できなかった。アプリ側のバリデーション（E-11）は維持すること"))
            } catch let error as RcError {
                add(Check("M-11(2)", "8 日指定の挙動", true,
                          "エラーになった: \(error.message)",
                          deviation: "ソース読解では丸められるはずだった。E-11 のバリデーションは維持する"))
            } catch {}

            // M-11 (3): ディレクトリは共有できない
            do {
                _ = try await client.call(RcPath.operationsPublicLink,
                                          params: ["fs": fs, "remote": "somedir/", "expire": "1h"],
                                          as: RcPublicLinkResponse.self)
                add(Check("M-11(3)", "ディレクトリの共有は拒否される", false, "成功してしまった"))
            } catch let error as RcError {
                add(Check("M-11(3)", "ディレクトリの共有は拒否される", true, error.message))
            } catch {}

            _ = try? await client.callRaw(RcPath.operationsDeleteFile,
                                          params: ["fs": fs, "remote": linkKey])
        }

        // ---- ⑤ U-04: Cache-Control の実付与 ----
        if let publicBucket = input.publicBucket,
           let baseURL = input.publicBaseURL, ProfileValidator.isValidPublicBaseURL(baseURL) {
            let publicFs = AppIdentity.fs(bucketName: publicBucket)
            let cacheKey = "\(AppIdentity.probeKeyPrefix)\(RandomToken.probeSuffix()).txt"
            try? Data(probeBody.utf8).write(to: localDir.appendingPathComponent(cacheKey))
            do {
                try await client.callAsyncJob(RcPath.operationsCopyFile, params: [
                    "srcFs": AppIdentity.localFs(directory: localDir.path), "srcRemote": cacheKey,
                    "dstFs": publicFs, "dstRemote": cacheKey,
                    "_config": ["UploadHeaders": [["Key": "Cache-Control",
                                                   "Value": "public, max-age=31536000, immutable"]]],
                ])
                let urlString = PublicKeyTemplate.publicURL(publicBaseURL: baseURL, key: cacheKey)
                if let u = URL(string: urlString), let (status, headers, body) = await httpGetFull(u) {
                    add(Check("G1-9.5a", "公開 URL に到達できる（§4.4 手順 5）",
                              status == 200 && String(data: body, encoding: .utf8) == probeBody,
                              "HTTP \(status) — \(urlString)"))
                    let cacheControl = headers["Cache-Control"] ?? headers["cache-control"]
                    let applied = cacheControl?.contains("max-age=31536000") == true
                    add(Check("G1-9.5b", "U-04: Cache-Control がオブジェクトに付与される", applied,
                              cacheControl ?? "（ヘッダなし）",
                              deviation: applied ? nil
                                  : "付与されていない。immutableCacheControl 機能を v1.0 スコープから外すこと"))
                } else {
                    add(Check("G1-9.5a", "公開 URL に到達できる（§4.4 手順 5）", false,
                              "GET に失敗 — カスタムドメインが接続されていない可能性（E-13）"))
                }
                _ = try? await client.callRaw(RcPath.operationsDeleteFile,
                                              params: ["fs": publicFs, "remote": cacheKey])
            } catch {
                add(Check("G1-9.5a", "公開バケットへの書き込み", false, String(describing: error)))
            }
        } else {
            add(Check("G1-9.5", "U-04: Cache-Control の実付与", false,
                      "SKYFOLDER_PUBLIC_BUCKET / SKYFOLDER_PUBLIC_BASE_URL が未指定のため未検証"))
        }

        // ---- ⑦ U-11 の再計測 + ⑥ M-03 の裏取り ----
        let mountPoint = work.appendingPathComponent("mnt")
        try? AppPaths.ensureDirectory(mountPoint, mode: 0o700)
        let bucket = profile.buckets[0]
        let mountStart = Date()
        do {
            try await client.callRaw(RcPath.mountMount,
                                     params: MountOptionsBuilder.mountParams(
                                        bucket: bucket, advanced: profile.advanced,
                                        resolvedMountPoint: mountPoint.path),
                                     timeout: 120)
            let elapsed = Date().timeIntervalSince(mountStart)
            add(Check("G1-9.7", "U-11 再計測: S3 バックエンドでの mount/mount の応答時間", true,
                      String(format: "%.3f 秒（local では 0.036 秒。NewFs の疎通ぶん遅い）", elapsed)))

            // ⑥ M-03: uploadsQueued が実際に増減するか
            let file = mountPoint.appendingPathComponent(
                "\(AppIdentity.probeKeyPrefix)\(RandomToken.probeSuffix()).bin")
            try? Data(repeating: 0x41, count: 4 * 1024 * 1024).write(to: file)

            var sawQueue = false
            var maxPending = 0
            for _ in 0..<60 {
                if let stats = try? await client.vfsStats() {
                    maxPending = max(maxPending, stats.pendingUploads)
                    if stats.pendingUploads > 0 { sawQueue = true }
                    if sawQueue, stats.pendingUploads == 0 { break }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            add(Check("G1-9.6", "M-03: vfs/stats の uploadsQueued が実際に増減する", sawQueue,
                      "観測した最大の未送信件数 = \(maxPending)",
                      deviation: sawQueue ? nil
                          : "キューを観測できなかった。§5.2「未送信 N 件」の表示根拠を再検討すること"))

            try? FileManager.default.removeItem(at: file)

            // ② マルチパート（128MB 超）
            if input.runMultipart {
                let big = mountPoint.appendingPathComponent(
                    "\(AppIdentity.probeKeyPrefix)\(RandomToken.probeSuffix()).bin")
                let chunk = Data(repeating: 0x42, count: 8 * 1024 * 1024)
                FileManager.default.createFile(atPath: big.path, contents: nil)
                if let handle = try? FileHandle(forWritingTo: big) {
                    for _ in 0..<17 { try? handle.write(contentsOf: chunk) }   // 136MB
                    try? handle.close()
                }
                var done = false
                for _ in 0..<600 {
                    if let stats = try? await client.vfsStats(), stats.pendingUploads == 0 {
                        done = true; break
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                add(Check("G1-9.2", "マルチパートアップロード（136MB / cutoff 128MB）", done,
                          done ? "送信完了" : "10 分以内に送信し切れなかった"))
                try? FileManager.default.removeItem(at: big)
            } else {
                add(Check("G1-9.2", "マルチパートアップロード（128MB 超）", false,
                          "SKYFOLDER_RUN_MULTIPART=1 が未指定のため未検証"))
            }

            _ = try? await client.callRaw(RcPath.mountUnmountAll)
        } catch let error as RcError {
            // E-15: S3 は NewFs で疎通するため、接続テストを通った後でもここで失敗しうる
            add(Check("G1-9.7", "S3 バックエンドでのマウント", false,
                      "E-15 の経路: \(error.message)"))
        } catch {
            add(Check("G1-9.7", "S3 バックエンドでのマウント", false, error.localizedDescription))
        }

        // ---- 後片付け ----
        let leftovers = (try? await client.call(RcPath.operationsList,
                                                params: ["fs": fs, "remote": "",
                                                         "opt": ["maxDepth": 1, "filesOnly": true]],
                                                as: RcListResponse.self))?.list ?? []
        var removed = 0
        for entry in leftovers
        where AppIdentity.allProbeKeyPrefixes.contains(where: { entry.path.hasPrefix($0) }) {
            if (try? await client.callRaw(RcPath.operationsDeleteFile,
                                          params: ["fs": fs, "remote": entry.path])) != nil {
                removed += 1
            }
        }
        add(Check("CLEANUP", "プローブを片付けた", true, "\(removed) 件削除"))

        // 正常終了の経路。呼び出し側は戻り値を受け取ってすぐ exit() するので、
        // ここで rcd の停止を**待ち切ってから**返す。
        await supervisor.stop()
        return checks
    }

    // MARK: - 補助

    private static func httpGet(_ url: URL) async -> (Int, Data)? {
        guard let (status, _, body) = await httpGetFull(url) else { return nil }
        return (status, body)
    }

    private static func httpGetFull(_ url: URL) async -> (Int, [String: String], Data)? {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 30
        guard let (data, response) = try? await URLSession(configuration: .ephemeral).data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let k = key as? String, let v = value as? String { headers[k] = v }
        }
        return (http.statusCode, headers, data)
    }

    /// SEC-G04: 署名部分を出力しない
    private static func maskSignature(_ url: String) -> String {
        LogMasker().mask(url)
    }

    private static func expiresParameter(of url: String) -> String? {
        URLComponents(string: url)?.queryItems?
            .first { $0.name.lowercased() == "x-amz-expires" }?.value
    }

    public static func report(_ checks: [Check]) -> String {
        var lines: [String] = []
        let passed = checks.filter(\.passed).count
        lines.append("G1-9 実 R2 アカウントでの通し確認: \(passed)/\(checks.count) 通過")
        lines.append(String(repeating: "-", count: 72))
        for c in checks {
            lines.append("\(c.passed ? "PASS" : "FAIL")  \(c.id.padding(toLength: 10, withPad: " ", startingAt: 0)) \(c.name)")
            if !c.detail.isEmpty { lines.append("      \(c.detail)") }
            if let deviation = c.deviation {
                lines.append("      ⚠️ 設計との差分: \(deviation)")
            }
        }
        if passed < checks.count {
            lines.append("")
            lines.append("未通過の項目があります。設計書 §11 G1-9 は「省略して G2 へ進んではならない」と規定しています。")
        }
        return lines.joined(separator: "\n")
    }
}
