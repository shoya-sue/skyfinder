import Foundation

/// rcd の接続情報。rc-user / rc-pass はプロセス起動ごとの乱数で、
/// ディスク・ログ・引数のいずれにも出さない（SEC-G01）。
public struct RcEndpoint: Sendable, Equatable {
    public let port: Int
    public let user: String
    public let password: String

    public init(port: Int, user: String, password: String) {
        self.port = port
        self.user = user
        self.password = password
    }

    /// 127.0.0.1 に限定。0.0.0.0 にしてはならない（SEC-G01 (b)）
    public var baseURL: URL { URL(string: "http://127.0.0.1:\(port)/")! }

    public var basicAuthHeader: String {
        let raw = "\(user):\(password)"
        return "Basic " + Data(raw.utf8).base64EncodedString()
    }
}

/// §06: RC API への HTTP クライアント。全 rclone 操作はこの層を通る。
///
/// Basic 認証・タイムアウト・_async ジョブのポーリング・エラー本文の構造化を担う。
public final class RcClient: @unchecked Sendable {
    private let endpoint: RcEndpoint
    private let session: URLSession
    private let defaultTimeout: TimeInterval

    public init(endpoint: RcEndpoint, timeout: TimeInterval = 30) {
        self.endpoint = endpoint
        self.defaultTimeout = timeout
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        // localhost へのプロキシ経由を避ける
        config.connectionProxyDictionary = [:]
        config.httpAdditionalHeaders = [:]
        self.session = URLSession(configuration: config)
    }

    public var port: Int { endpoint.port }

    // MARK: - 生の呼び出し

    /// RC API を 1 回叩き、生の JSON を返す。
    @discardableResult
    public func callRaw(_ path: String,
                        params: [String: Any] = [:],
                        timeout: TimeInterval? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(endpoint.basicAuthHeader, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout ?? defaultTimeout
        request.httpBody = params.isEmpty
            ? Data("{}".utf8)
            : try JSONSerialization.data(withJSONObject: params, options: [])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RcError(path: path, statusCode: -1, message: error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        guard (200..<300).contains(status) else {
            // rclone は失敗時に {"error": "...", "path": "...", "status": 500} を返す
            let message = (json["error"] as? String)
                ?? String(data: data, encoding: .utf8)
                ?? "unknown error"
            throw RcError(path: path, statusCode: status, message: message)
        }
        // 200 でも error フィールドが載る経路があるため確認する
        if let message = json["error"] as? String, !message.isEmpty {
            throw RcError(path: path, statusCode: status, message: message)
        }
        return json
    }

    /// 応答を Decodable に写す。
    public func call<T: Decodable>(_ path: String,
                                   params: [String: Any] = [:],
                                   as type: T.Type,
                                   timeout: TimeInterval? = nil) async throws -> T {
        let json = try await callRaw(path, params: params, timeout: timeout)
        let data = try JSONSerialization.data(withJSONObject: json)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw RcError(path: path, statusCode: 200,
                          message: "応答を解釈できません: \(error.localizedDescription)")
        }
    }

    // MARK: - §6.5 非同期ジョブ
    //
    // 大きなファイルのアップロード・コピー・移動は _async: true で発行し、
    // 返る jobid を job/status でポーリングする（1 秒間隔）。
    // マウント操作は同期で呼ぶ（失敗を即座にユーザーへ返す必要があり、処理が短いため）。

    /// _async でジョブを起動し、完了まで待つ。
    /// - Parameter onProgress: 1 秒ごとに job/status の結果を渡す（UI の進捗表示用）
    @discardableResult
    public func callAsyncJob(_ path: String,
                             params: [String: Any] = [:],
                             pollInterval: TimeInterval = 1.0,
                             onProgress: (@Sendable (RcJobStatus) -> Void)? = nil) async throws -> RcJobStatus {
        var p = params
        p["_async"] = true
        let handle = try await call(path, params: p, as: RcAsyncJobHandle.self)

        while true {
            try Task.checkCancellation()
            let status = try await call(RcPath.jobStatus, params: ["jobid": handle.jobid],
                                        as: RcJobStatus.self)
            onProgress?(status)
            if status.finished {
                if !status.success {
                    throw RcError(path: path, statusCode: 500,
                                  message: status.error ?? "ジョブが失敗しました")
                }
                return status
            }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }

    // MARK: - よく使うエンドポイント

    public func coreVersion() async throws -> RcCoreVersion {
        try await call(RcPath.coreVersion, as: RcCoreVersion.self)
    }

    /// 起動時に 1 回。nfsmount の存在確認（E-03）と「詳細設定」の選択肢構成に使う。
    public func mountTypes() async throws -> [String] {
        try await call(RcPath.mountTypes, as: RcMountTypesResponse.self).mountTypes
    }

    /// §02 DESIGN INVARIANT: マウント状態の唯一の情報源。
    public func listMounts() async throws -> [RcMountPoint] {
        try await call(RcPath.mountListMounts, as: RcListMountsResponse.self).mountPoints
    }

    public func coreStats() async throws -> RcCoreStats {
        try await call(RcPath.coreStats, as: RcCoreStats.self)
    }

    public func vfsStats() async throws -> RcVfsStats {
        try await call(RcPath.vfsStats, as: RcVfsStats.self)
    }

    /// §6.2 表: nfs-cache-handle-limit は既定が 1000000 なので通常は不要。
    /// options/set は冪等（同値 2 回でも {}）なので起動のたびに無条件で送ってよい。
    public func optionsSet(_ options: [String: Any]) async throws {
        try await callRaw(RcPath.optionsSet, params: options)
    }

    public func optionsGet() async throws -> [String: Any] {
        try await callRaw(RcPath.optionsGet)
    }

    /// M-05: 環境変数由来のリモートは現れない（空になる）。これは異常ではない。
    /// リモート定義の確認に使ってはならない — 確認は operations/list の成否で行う。
    /// Access Key も Secret も出ないため、診断表示に使っても安全。
    public func configDump() async throws -> [String: Any] {
        try await callRaw(RcPath.configDump)
    }
}
