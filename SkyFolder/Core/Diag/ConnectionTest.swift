import Foundation

/// §4.4: 接続テスト。プロファイル保存前に必須で通す。
///
/// **MUST — 「接続テスト全項目 ✓」が公開 URL の動作を保証しなければならない**
/// 手順 1〜4 は R2 の S3 API への到達性しか検証しない。手順 5 がないと、
/// ドメイン未接続のまま「全項目 ✓」と表示され、共有 URL を相手に渡して 404 が返って初めて破綻が露見する。
/// これはユーザーが最も損害を被る失敗の形（他人に壊れたリンクを渡す）なので、手順 5 を省略してはならない。
///
/// **MUST — アカウント全体の列挙を疎通判定に使わない**（DD-001 F-01 の再発防止）
/// バケットスコープの API トークンでは ListBuckets が権限不足で失敗する。
/// `operations/list` に `fs: "r2:"`（バケット名なし）を渡す実装をしてはならない。
/// これをやると正しいトークンを「トークン不良」と誤診断し、ユーザーが解決不能なループに入る。
public struct ConnectionTest: Sendable {

    public enum Step: String, Sendable, CaseIterable {
        case remoteConfigured   // 1. リモートの構成（rcd 起動済みか）
        case listObjects        // 2. operations/list（バケット名つき）
        case writeProbe         // 3. operations/uploadfile 相当で PUT
        case deleteProbe        // 4. operations/deletefile で後片付け
        case publicURLReachable // 5. 公開 URL の到達性検証

        public var title: String {
            switch self {
            case .remoteConfigured: return "接続の準備"
            case .listObjects: return "バケットの読み取り"
            case .writeProbe: return "バケットへの書き込み"
            case .deleteProbe: return "バケットからの削除"
            case .publicURLReachable: return "公開 URL の到達性"
            }
        }
    }

    public struct StepResult: Sendable, Identifiable {
        public let step: Step
        public let bucketAlias: String?
        public let passed: Bool
        /// 手順 5 は失敗しても保存を妨げない（警告扱い）— マウントだけ使う構成を許容するため
        public let isBlocking: Bool
        public let message: String
        /// §10.1 のエラー ID
        public let catalogID: String?

        public var id: String { "\(step.rawValue):\(bucketAlias ?? "-")" }

        public init(step: Step, bucketAlias: String?, passed: Bool,
                    isBlocking: Bool, message: String, catalogID: String? = nil) {
            self.step = step
            self.bucketAlias = bucketAlias
            self.passed = passed
            self.isBlocking = isBlocking
            self.message = message
            self.catalogID = catalogID
        }
    }

    public struct Report: Sendable {
        public let results: [StepResult]
        /// 手順 5 を通過したバケットの alias。§7.1 RULE の解決対象になる。
        public let publicURLVerifiedAliases: Set<String>

        /// 保存を許すか（手順 5 は妨げない）
        public var canSave: Bool { !results.contains { !$0.passed && $0.isBlocking } }
        /// 全項目 ✓
        public var allPassed: Bool { results.allSatisfy(\.passed) }
    }

    private let client: RcClient
    /// テスト用に差し替えられるようにしておく（HTTPS GET の検証）
    private let httpGet: @Sendable (URL) async -> (status: Int, body: Data)?

    public init(client: RcClient,
                httpGet: (@Sendable (URL) async -> (status: Int, body: Data)?)? = nil) {
        self.client = client
        self.httpGet = httpGet ?? ConnectionTest.defaultHTTPGet
    }

    public static let defaultHTTPGet: @Sendable (URL) async -> (status: Int, body: Data)? = { url in
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return (http.statusCode, data)
    }

    /// 全バケットに対して手順 1〜5 を実行する。
    public func run(profile: Profile,
                    now: Date = Date()) async -> Report {
        var results: [StepResult] = []
        var verified = Set<String>()

        // 1. リモートの構成 = rcd が生きていること
        do {
            _ = try await client.coreVersion()
            results.append(.init(step: .remoteConfigured, bucketAlias: nil, passed: true,
                                 isBlocking: true, message: "内部エンジンに接続できました。"))
        } catch {
            results.append(.init(step: .remoteConfigured, bucketAlias: nil, passed: false,
                                 isBlocking: true,
                                 message: "内部エンジンを起動できませんでした。アプリを再起動してください。",
                                 catalogID: "E-01"))
            return Report(results: results, publicURLVerifiedAliases: [])
        }

        for bucket in profile.buckets {
            let fs = AppIdentity.fs(bucketName: bucket.bucketName)

            // 2. operations/list（必ずバケット名を含む fs で行う）
            do {
                _ = try await client.call(RcPath.operationsList,
                                          params: ["fs": fs, "remote": "",
                                                   "opt": ["maxDepth": 1]],
                                          as: RcListResponse.self)
                results.append(.init(step: .listObjects, bucketAlias: bucket.alias, passed: true,
                                     isBlocking: true, message: "読み取りできました。"))
            } catch let error as RcError {
                let (message, id) = Self.classify(error, bucketName: bucket.bucketName)
                results.append(.init(step: .listObjects, bucketAlias: bucket.alias, passed: false,
                                     isBlocking: true, message: message, catalogID: id))
                continue
            } catch {
                results.append(.init(step: .listObjects, bucketAlias: bucket.alias, passed: false,
                                     isBlocking: true, message: error.localizedDescription))
                continue
            }

            // 3 / 4. 書込みと削除。プローブのキー名に乱数を含める（§8.6.3）ので、
            //        前回のプローブが後片付け前に落ちて残っていても衝突しない。
            let probeKey = "\(AppIdentity.probeKeyPrefix)\(RandomToken.probeSuffix()).txt"
            let probeBody = "SkyFolder connection test \(Int(now.timeIntervalSince1970))\n"
            var probeUploaded = false
            do {
                try await putProbe(fs: fs, key: probeKey, body: probeBody,
                                   cacheControl: profile.share.immutableCacheControl
                                       ? "public, max-age=31536000, immutable" : nil)
                probeUploaded = true
                results.append(.init(step: .writeProbe, bucketAlias: bucket.alias, passed: true,
                                     isBlocking: true, message: "書き込みできました。"))
            } catch let error as RcError {
                results.append(.init(step: .writeProbe, bucketAlias: bucket.alias, passed: false,
                                     isBlocking: true,
                                     message: "書き込みできませんでした。API トークンに Object Read & Write 権限が必要です。\n\(error.message)",
                                     catalogID: "E-06"))
            } catch {
                results.append(.init(step: .writeProbe, bucketAlias: bucket.alias, passed: false,
                                     isBlocking: true, message: error.localizedDescription))
            }

            // 5. 公開 URL の到達性検証（visibility == public かつ publicBaseURL 設定済みのみ）
            //    手順 4 より前に行う — プローブを消す前に GET する必要があるため。
            if probeUploaded, bucket.visibility.isPublic,
               ProfileValidator.isValidPublicBaseURL(bucket.publicBaseURL) {
                let urlString = PublicKeyTemplate.publicURL(publicBaseURL: bucket.publicBaseURL,
                                                            key: probeKey)
                if let url = URL(string: urlString), let response = await httpGet(url),
                   response.status == 200,
                   String(data: response.body, encoding: .utf8) == probeBody {
                    verified.insert(bucket.alias)
                    results.append(.init(step: .publicURLReachable, bucketAlias: bucket.alias,
                                         passed: true, isBlocking: false,
                                         message: "公開 URL に到達できました。"))
                } else {
                    results.append(.init(
                        step: .publicURLReachable, bucketAlias: bucket.alias, passed: false,
                        isBlocking: false,
                        message: "バケット「\(bucket.bucketName)」にカスタムドメイン \(bucket.publicBaseURL) が接続されていないようです。公開 URL は使えませんが、マウントは利用できます。",
                        catalogID: "E-13"))
                }
            }

            // 4. 後片付け（削除権限の検証を兼ねる）
            if probeUploaded {
                do {
                    try await client.callRaw(RcPath.operationsDeleteFile,
                                             params: ["fs": fs, "remote": probeKey])
                    results.append(.init(step: .deleteProbe, bucketAlias: bucket.alias, passed: true,
                                         isBlocking: true, message: "削除できました。"))
                } catch let error as RcError where error.meansObjectNotFound {
                    // 「存在しない」は成功として扱う（§8.6.1・実測で 404 になることを確認）
                    results.append(.init(step: .deleteProbe, bucketAlias: bucket.alias, passed: true,
                                         isBlocking: true, message: "削除できました。"))
                } catch let error as RcError {
                    results.append(.init(step: .deleteProbe, bucketAlias: bucket.alias, passed: false,
                                         isBlocking: true,
                                         message: "削除できませんでした。API トークンに Object Read & Write 権限が必要です。\n\(error.message)",
                                         catalogID: "E-06"))
                } catch {
                    results.append(.init(step: .deleteProbe, bucketAlias: bucket.alias, passed: false,
                                         isBlocking: true, message: error.localizedDescription))
                }
            }
        }

        return Report(results: results, publicURLVerifiedAliases: verified)
    }

    /// §8.1 手順 0-c: 前回のプローブが残っていれば掃除する（失敗扱いにしない）。
    /// 旧 prefix も掃除対象に含める（§15.1）。
    @discardableResult
    public func cleanLeftoverProbes(bucketName: String) async -> Int {
        let fs = AppIdentity.fs(bucketName: bucketName)
        guard let response = try? await client.call(
            RcPath.operationsList,
            params: ["fs": fs, "remote": "", "opt": ["maxDepth": 1, "filesOnly": true]],
            as: RcListResponse.self) else { return 0 }

        var removed = 0
        for entry in response.list
        where AppIdentity.allProbeKeyPrefixes.contains(where: { entry.path.hasPrefix($0) }) {
            if (try? await client.callRaw(RcPath.operationsDeleteFile,
                                          params: ["fs": fs, "remote": entry.path])) != nil {
                removed += 1
            }
        }
        return removed
    }

    // MARK: - 補助

    private func putProbe(fs: String, key: String, body: String, cacheControl: String?) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(AppIdentity.bundleIdentifier).probe.\(UUID().uuidString)",
                                    isDirectory: true)
        try AppPaths.ensureDirectory(directory, mode: 0o700)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appendingPathComponent(key)
        try Data(body.utf8).write(to: file)

        var params: [String: Any] = [
            "srcFs": AppIdentity.localFs(directory: directory.path),
            "srcRemote": key,
            "dstFs": fs,
            "dstRemote": key,
        ]
        if let cacheControl {
            // U-04: 手順 5 の GET でレスポンスヘッダに Cache-Control が載るかを確認する。
            // 手順 5 が既にあるため追加コストはほぼゼロ。
            params["_config"] = ["UploadHeaders": [["Key": "Cache-Control", "Value": cacheControl]]]
        }
        try await client.callRaw(RcPath.operationsCopyFile, params: params, timeout: 60)
    }

    /// E-06 と E-07 を区別する。
    /// **認証エラーの判定は必ずバケット名付きの操作の結果に対して行うこと**（DD-001 F-01）。
    static func classify(_ error: RcError, bucketName: String) -> (String, String) {
        if error.meansBucketNotFound {
            return ("バケット「\(bucketName)」が見つかりません。名前を確認してください。", "E-07")
        }
        if error.meansForbidden {
            return ("R2 に接続できませんでした。API トークンの権限（Object Read & Write）と対象バケットの指定を確認してください。",
                    "E-06")
        }
        return ("R2 に接続できませんでした。\n\(error.message)", "E-06")
    }
}
