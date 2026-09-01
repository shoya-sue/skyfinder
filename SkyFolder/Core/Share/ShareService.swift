import Foundation

public enum ShareError: Error, LocalizedError, Sendable {
    /// E-10: 公開バケットに publicBaseURL 未設定 / 解決できる公開先が 0 個
    case noPublicDestination
    /// 期限付き共有には非公開バケットが必要（§7.1 RULE）
    case noPrivateDestination
    /// E-11: presigned の期限が上限超過
    case expireTooLong(requested: String)
    case expireInvalid(requested: String)
    /// §7.2: ディレクトリは共有できない（M-11 (3)）
    case cannotShareDirectory(String)
    /// 上書き確認が必要（無確認上書きを禁止・DD-001 §8.2）
    case overwriteConfirmationRequired(key: String)
    /// E-12: アップロードジョブ失敗
    case uploadFailed(fileName: String, detail: String)
    case fileNotFound(String)
    /// K-05: 1 オブジェクト 300GB 上限
    case objectTooLarge(bytes: Int64)
    /// §7.1 RULE: 期限付き共有の staging 先は非公開バケットに限る
    case stagingBucketMustBePrivate(alias: String)
    /// §8.6.1 MUST: 1 回の操作から 1 本しか発行しない
    case issueInProgress(name: String)

    public var errorDescription: String? {
        switch self {
        case .noPublicDestination:
            return "公開 URL を発行するには、公開用ドメインの設定が必要です。"
        case .noPrivateDestination:
            return "期限付き共有には非公開バケットが必要です。"
        case .expireTooLong:
            return "期限付きリンクは最長 7 日です。それ以上の共有には恒久公開をご利用ください。"
        case .expireInvalid(let raw):
            return "有効期限「\(raw)」を解釈できません。1h / 24h / 7d のような形式で指定してください。"
        case .cannotShareDirectory:
            return "フォルダは共有できません。ファイルを選んでください。"
        case .overwriteConfirmationRequired(let key):
            return "\(key) は既に存在します。上書きしますか？"
        case .uploadFailed(let name, let detail):
            return "\(name) のアップロードに失敗しました。\n\(detail)"
        case .fileNotFound(let path):
            return "ファイルが見つかりません: \(path)"
        case .objectTooLarge(let bytes):
            let gb = Double(bytes) / 1_073_741_824
            return String(format: "1 ファイル 300GB を超えています（%.1f GB）。R2 の上限を超えるためアップロードできません。", gb)
        case .stagingBucketMustBePrivate(let alias):
            return "「\(alias)」は公開バケットです。期限付きリンクは非公開バケット上のファイルにのみ発行できます。"
        case .issueInProgress(let name):
            return "\(name) のリンクを発行しています。完了までお待ちください。"
        }
    }

    public var catalogID: String {
        switch self {
        case .noPublicDestination: return "E-10"
        case .expireTooLong, .expireInvalid: return "E-11"
        case .uploadFailed: return "E-12"
        default: return "E-12"
        }
    }
}

/// §7.1 RULE: 共有先バケットの解決規則。実装者はこの規則から逸脱してはならない。
public struct ShareDestinationResolver: Sendable {

    /// §4.4 手順 5（公開 URL の到達性検証）を通過したバケットの alias。
    /// 未通過（「公開 URL 未確認」状態）のバケットは解決対象から除外する
    /// — E-13 の「恒久公開の機能は無効化」と条件を一致させるため。
    public let publicURLVerifiedAliases: Set<String>

    public init(publicURLVerifiedAliases: Set<String>) {
        self.publicURLVerifiedAliases = publicURLVerifiedAliases
    }

    /// 恒久公開の宛先候補
    public func permanentDestinations(in profile: Profile) -> [BucketConfig] {
        profile.buckets.filter {
            $0.visibility.isPublic
                && !ProfileValidator.normalizePublicBaseURL($0.publicBaseURL).isEmpty
                && publicURLVerifiedAliases.contains($0.alias)
        }
    }

    /// 期限付き共有の staging 先候補
    public func stagingDestinations(in profile: Profile) -> [BucketConfig] {
        profile.buckets.filter { !$0.visibility.isPublic }
    }
}

/// §07: 公開 URL の組み立て、presigned URL の発行、Exif 除去、アップロード、gone 移動。
public actor ShareService {

    private let client: RcClient
    private let history: ShareHistoryStore
    private let stripper = ImageMetadataStripper()

    /// §8.6.1 MUST: `operations/publiclink` は本質的に非冪等で、しかもエラーにならないぶん危険。
    /// 2 回呼ぶと署名の異なる有効な presigned URL が 2 本発行され、両方が生きる。
    /// SEC-G05 で URL を保存せず §7.2 で失効不可としているため、
    /// 二度押しで生まれた 2 本目は追跡も失効もできない公開面になる。
    ///
    /// UI 側のボタン無効化に加えて、サービス層でも in-flight を弾く。
    private var inFlightPublicLinks: Set<String> = []
    private var inFlightPublishes: Set<String> = []

    public init(client: RcClient, history: ShareHistoryStore) {
        self.client = client
        self.history = history
    }

    // MARK: - §7.2 期限付きリンク（presigned URL）

    public struct PresignedLink: Sendable {
        public let url: String
        public let key: String
        public let bucketName: String
        public let issuedAt: Date
        public let expiresAt: Date
        /// ホストは {accountId}.r2.cloudflarestorage.com 固定。カスタムドメインでは presigned を使えない。
        public var usesAccountEndpoint: Bool { url.contains(".r2.cloudflarestorage.com") }
    }

    /// バケット上のオブジェクトに対して presigned URL を発行する。
    ///
    /// - 上限 7 日をアプリ側で拒否する（M-11 (2)）。rclone は超過をエラーにせず黙って 7 日に丸めるため、
    ///   アプリが検証しないとユーザーは「8 日で発行できた」と誤認したまま 7 日で切れる URL を配ることになる。
    /// - **`unlink` を送らない**（M-11 (1)）。S3 バックエンドでは受け取るだけで一度も使われておらず、
    ///   エラーも返らないため「失効させられた」と誤認する導線になる。
    public func issuePresignedLink(bucketName: String,
                                   key: String,
                                   expire: String,
                                   now: Date = Date()) async throws -> PresignedLink {
        guard let seconds = ProfileValidator.parseExpire(expire) else {
            throw ShareError.expireInvalid(requested: expire)
        }
        guard seconds <= ProfileValidator.maxExpireSeconds else {
            throw ShareError.expireTooLong(requested: expire)
        }
        guard seconds >= ProfileValidator.minExpireSeconds else {
            throw ShareError.expireInvalid(requested: expire)
        }
        // §7.2: ディレクトリは共有できない。UI でも選ばせないが、ここでも弾く。
        guard !key.hasSuffix("/") else { throw ShareError.cannotShareDirectory(key) }

        let token = "\(bucketName)/\(key)"
        guard !inFlightPublicLinks.contains(token) else {
            // 1 回のユーザー操作から 1 本しか発行されないことを保証する（§8.6.1 MUST）
            throw ShareError.issueInProgress(name: key)
        }
        inFlightPublicLinks.insert(token)
        defer { inFlightPublicLinks.remove(token) }

        do {
            // expire は **文字列**（"1d" 形式）。vfsOpt の Duration が数値なのとは扱いが違う。
            let response = try await client.call(
                RcPath.operationsPublicLink,
                params: ["fs": AppIdentity.fs(bucketName: bucketName),
                         "remote": key,
                         "expire": expire],
                as: RcPublicLinkResponse.self)

            let link = PresignedLink(url: response.url,
                                     key: key,
                                     bucketName: bucketName,
                                     issuedAt: now,
                                     expiresAt: now.addingTimeInterval(Double(seconds)))
            // SEC-G05: URL 文字列は保存しない
            history.append(ShareHistoryEntry(bucketName: bucketName, key: key,
                                             issuedAt: link.issuedAt, expiresAt: link.expiresAt))
            return link
        } catch let error as RcError {
            if error.meansCantShareDirectories { throw ShareError.cannotShareDirectory(key) }
            throw ShareError.uploadFailed(fileName: key, detail: error.message)
        }
    }

    /// §7.1: ローカルファイルを private バケットの `share-staging/{YYYYMMDD}/` へ上げてから発行する。
    /// **§7.1 RULE**: staging 先は `visibility == "private"` のバケットに限る。
    /// 公開バケットへ上げると「非公開のまま・期限あり」という UI の説明が嘘になる
    /// （そのオブジェクトは `publicBaseURL` 経由で誰でも恒久的に取れる）。
    public func issuePresignedLinkForLocalFile(_ fileURL: URL,
                                               stagingBucket: BucketConfig,
                                               expire: String,
                                               now: Date = Date()) async throws -> PresignedLink {
        guard !stagingBucket.visibility.isPublic else {
            throw ShareError.stagingBucketMustBePrivate(alias: stagingBucket.alias)
        }
        try checkFile(fileURL)
        let key = PublicKeyTemplate.stagingKey(fileName: fileURL.lastPathComponent, now: now)

        // §8.6.1 MUST: 1 回のユーザー操作から 1 本しか発行されないことを保証する。
        // **ガードはアップロードの前に置く。** 発行の直前だけに置くと、二度押しの 2 本目が
        // アップロードを終えたころには 1 本目が token を解放しており、
        // 署名の異なる有効な presigned URL が 2 本出てしまう。
        let token = "local:\(stagingBucket.bucketName)/\(fileURL.standardizedFileURL.path)"
        guard !inFlightPublicLinks.contains(token) else {
            throw ShareError.issueInProgress(name: fileURL.lastPathComponent)
        }
        inFlightPublicLinks.insert(token)
        defer { inFlightPublicLinks.remove(token) }

        // 期限付き共有では Exif を除去しない（DD-001 §8.3 継承:
        // 受け渡し先で原本が必要なユースケースを想定）
        try await copyLocalFile(fileURL, toBucket: stagingBucket.bucketName, key: key,
                                cacheControl: nil)
        return try await issuePresignedLink(bucketName: stagingBucket.bucketName,
                                            key: key, expire: expire, now: now)
    }

    // MARK: - §7.3 恒久公開（この順序を変えてはならない）

    public struct PublishResult: Sendable {
        public let key: String
        public let url: String
        public let bucketName: String
        public let metadataStripped: Bool
    }

    /// 手順 2: 既存 key の衝突確認。存在する場合は上書き確認ダイアログを挟む（無確認上書き禁止）。
    public func objectExists(bucketName: String, key: String) async throws -> Bool {
        let json = try await client.callRaw(RcPath.operationsStat,
                                            params: ["fs": AppIdentity.fs(bucketName: bucketName),
                                                     "remote": key])
        // 実測: 存在しない場合は {"item": null}
        if let item = json["item"], !(item is NSNull) { return true }
        return false
    }

    /// 恒久公開。
    ///
    /// 1. key の組み立て（publicKeyTemplate + slug 化）
    /// 2. `operations/stat` で既存 key の衝突確認 → 上書き確認
    /// 3. Exif 除去（対象拡張子かつ stripImageMetadata: true のとき）。**一時ディレクトリの複製に対して行い、原本は変更しない**
    /// 4. アップロード（`_async: true`）。immutableCacheControl が true なら Cache-Control を付与
    /// 5. 一時ディレクトリの削除
    /// 6. `{publicBaseURL}/{key}` を組み立て、クリップボードへ（呼び出し側）
    public func publishPermanently(fileURL: URL,
                                   bucket: BucketConfig,
                                   share: ShareSettings,
                                   prefixOverride: String? = nil,
                                   stripMetadata: Bool? = nil,
                                   confirmedOverwrite: Bool = false,
                                   now: Date = Date(),
                                   onProgress: (@Sendable (RcJobStatus) -> Void)? = nil)
        async throws -> PublishResult {

        try checkFile(fileURL)

        // 1. key の組み立て
        let key = PublicKeyTemplate.render(template: share.publicKeyTemplate,
                                           prefix: prefixOverride ?? share.defaultPrefix,
                                           fileName: fileURL.lastPathComponent,
                                           now: now)

        let token = "\(bucket.bucketName)/\(key)"
        guard !inFlightPublishes.contains(token) else {
            throw ShareError.uploadFailed(fileName: fileURL.lastPathComponent,
                                          detail: "公開処理が進行中です。")
        }
        inFlightPublishes.insert(token)
        defer { inFlightPublishes.remove(token) }

        // 2. 衝突確認（毎回行う・§8.6.3）
        if !confirmedOverwrite, try await objectExists(bucketName: bucket.bucketName, key: key) {
            throw ShareError.overwriteConfirmationRequired(key: key)
        }

        // 3. Exif 除去。失敗したらアップロードを中止する
        //    （DD-001 §8.3 の「警告のみで続行しない」を継承・E-09）
        // **除去できない形式の画像を、無加工で公開しない（fail-closed）。**
        //
        // 一覧外の拡張子だと除去をスキップして原本を上げていた。RAW（.dng / .cr2 /
        // .arw / .nef）や .heif / .avif がそれに当たり、**GPS 座標や機材シリアルを
        // 抱えたまま public バケットへ上がる**。UI にも警告が出ないので気づけない。
        //
        // 「除去する」が有効なのに除去できない形式なら、E-09 と同じく**中止する**。
        // 黙って素通しにするより、公開できないほうが安全側。
        let wantsStrip = stripMetadata ?? share.stripImageMetadata
        if wantsStrip,
           !ImageMetadataStripper.isTargetFile(fileURL),
           ImageMetadataStripper.carriesMetadata(fileURL) {
            throw ImageMetadataError.unsupportedFormat(fileURL.pathExtension)
        }
        let shouldStrip = wantsStrip && ImageMetadataStripper.isTargetFile(fileURL)
        var uploadSource = fileURL
        var temporaryDirectory: URL?
        // 途中で失敗しても一時ディレクトリを消す（defer 相当の確実な後始末・§8.6.3）
        defer {
            if let dir = temporaryDirectory {
                try? FileManager.default.removeItem(at: dir)
            }
        }
        if shouldStrip {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(AppIdentity.bundleIdentifier).publish.\(UUID().uuidString)",
                                        isDirectory: true)
            try AppPaths.ensureDirectory(dir, mode: 0o700)
            temporaryDirectory = dir
            uploadSource = try stripper.strip(fileURL, into: dir)
        }

        // 4. アップロード
        let cacheControl = share.immutableCacheControl
            ? "public, max-age=31536000, immutable" : nil
        do {
            try await copyLocalFile(uploadSource, toBucket: bucket.bucketName, key: key,
                                    cacheControl: cacheControl, onProgress: onProgress)
        } catch let error as RcError {
            throw ShareError.uploadFailed(fileName: fileURL.lastPathComponent, detail: error.message)
        }

        // 5. 一時ディレクトリは defer で削除される
        // 6. URL の組み立て
        return PublishResult(key: key,
                             url: PublicKeyTemplate.publicURL(publicBaseURL: bucket.publicBaseURL,
                                                              key: key),
                             bucketName: bucket.bucketName,
                             metadataStripped: shouldStrip)
    }

    // MARK: - §5.4 公開物一覧・取り下げ

    /// `gone/` 配下は既定で非表示。
    public func listObjects(bucketName: String,
                            recurse: Bool = true,
                            includeGone: Bool = false) async throws -> [RcListEntry] {
        let response = try await client.call(
            RcPath.operationsList,
            params: ["fs": AppIdentity.fs(bucketName: bucketName),
                     "remote": "",
                     "opt": ["recurse": recurse, "filesOnly": true]],
            as: RcListResponse.self)
        guard !includeGone else { return response.list }
        return response.list.filter { !$0.path.hasPrefix("\(PublicKeyTemplate.gonePrefix)/") }
    }

    /// 取り下げ。**削除ではなく `gone/` へサーバサイド移動**する（DD-001 §4.4 の URL 不変性）。
    ///
    /// **M-14（実測）**: `operations/movefile` は移動先が既に存在しても**エラーにならず黙って上書きする**。
    /// §8.6.3 は「失敗しうる」を前提にフォールバックを規定していたが、実際の危険は逆で、
    /// 二度押しすると先に取り下げた `gone/{key}` を失う。
    /// したがって**移動前に `stat` で存在を確かめ**、あればタイムスタンプ付きの key へ退避する。
    @discardableResult
    public func takedown(bucketName: String, key: String, now: Date = Date()) async throws -> String {
        // §8.6.1 の原則: 目的は「その key が公開面に無い状態」。すでにそうなら達成されている。
        // 二度押しの 2 回目は**移動元がもう無い**ので、これを失敗にしてはならない。
        // （設計書 §8.6.3 は移動先の衝突だけを想定していたが、実際の失敗要因は移動元の消失）
        guard try await objectExists(bucketName: bucketName, key: key) else {
            return PublicKeyTemplate.goneKey(key)
        }
        var destination = PublicKeyTemplate.goneKey(key)
        if try await objectExists(bucketName: bucketName, key: destination) {
            destination = PublicKeyTemplate.goneKeyFallback(key, now: now)
        }
        let fs = AppIdentity.fs(bucketName: bucketName)
        do {
            try await client.callRaw(RcPath.operationsMoveFile,
                                     params: ["srcFs": fs, "srcRemote": key,
                                              "dstFs": fs, "dstRemote": destination])
        } catch let error as RcError where error.meansObjectNotFound {
            // 確認と移動の間に消えた場合も、望む終了状態には達している
            return PublicKeyTemplate.goneKey(key)
        }
        return destination
    }

    /// §5.4 四半期棚卸し: `gone/` 配下の一括削除。
    @discardableResult
    public func purgeGone(bucketName: String) async throws -> Int {
        let all = try await listObjects(bucketName: bucketName, recurse: true, includeGone: true)
        let targets = all.filter { $0.path.hasPrefix("\(PublicKeyTemplate.gonePrefix)/") }
        for entry in targets {
            try await deleteObject(bucketName: bucketName, key: entry.path)
        }
        return targets.count
    }

    /// `gone/` と `share-staging/` の合計サイズ（R-G09 / SEC-07 の常時表示に使う）
    public func housekeepingSizes(bucketName: String) async throws -> (gone: Int64, staging: Int64) {
        let all = try await listObjects(bucketName: bucketName, recurse: true, includeGone: true)
        let gone = all.filter { $0.path.hasPrefix("\(PublicKeyTemplate.gonePrefix)/") }
            .reduce(Int64(0)) { $0 + $1.size }
        let staging = all.filter { $0.path.hasPrefix("\(PublicKeyTemplate.stagingPrefix)/") }
            .reduce(Int64(0)) { $0 + $1.size }
        return (gone, staging)
    }

    // MARK: - §7.2 staging の掃除

    /// 日付 prefix が 14 日以上前になったものを削除する（起動時に 1 回）。
    ///
    /// 判定に発行履歴を使わないのは、履歴が直近 50 件しかなく、
    /// 51 件目以降・再インストール後・別マシンからは期限が取得できないため。
    /// 日付 prefix だけで自己完結する判定にする。
    ///
    /// 14 日の根拠: presigned の最大期限 7 日 + 猶予 7 日。
    @discardableResult
    public func cleanStaging(bucketName: String,
                             retentionDays: Int = 14,
                             now: Date = Date(),
                             timeZone: TimeZone = .current) async throws -> Int {
        let all = try await listObjects(bucketName: bucketName, recurse: true, includeGone: true)
        let cutoff = StagingRetention.cutoffStamp(now: now, retentionDays: retentionDays,
                                                  timeZone: timeZone)
        var removed = 0
        for entry in all where StagingRetention.isExpiredStagingKey(entry.path, cutoffStamp: cutoff) {
            try await deleteObject(bucketName: bucketName, key: entry.path)
            removed += 1
        }
        return removed
    }

    // MARK: - 低レベル

    /// §8.6.1: 存在しないキーへの削除は **HTTP 404 / `object not found`**（実測）。
    /// 接続テストの後片付けと staging の掃除で重複実行が起こりうるため、成功として扱う。
    public func deleteObject(bucketName: String, key: String) async throws {
        do {
            try await client.callRaw(RcPath.operationsDeleteFile,
                                     params: ["fs": AppIdentity.fs(bucketName: bucketName),
                                              "remote": key])
        } catch let error as RcError {
            guard error.meansObjectNotFound else { throw error }
            // 目的は「そのオブジェクトが存在しない状態」であり、すでにそうなら達成されている
        }
    }

    /// ローカルファイルをバケットへ上げる。
    ///
    /// **M-13（実測）**: 設計書 §7.3 手順 4 は `operations/uploadfile（_async: true）` としているが、
    /// `uploadfile` は multipart/form-data で、`_async` を form field で渡しても **jobid を返さず同期実行**になる。
    /// 進捗表示（G4 AC の「ジョブの完了を待ってからコピー」）を成立させるには
    /// `operations/copyfile` を使う必要がある — こちらは `_async` で jobid を返し、
    /// `_config.UploadHeaders`（U-04）も受理する。したがって本実装は copyfile を使う。
    private func copyLocalFile(_ fileURL: URL,
                               toBucket bucketName: String,
                               key: String,
                               cacheControl: String?,
                               onProgress: (@Sendable (RcJobStatus) -> Void)? = nil) async throws {
        let directory = fileURL.deletingLastPathComponent().path
        var params: [String: Any] = [
            "srcFs": AppIdentity.localFs(directory: directory),
            "srcRemote": fileURL.lastPathComponent,
            "dstFs": AppIdentity.fs(bucketName: bucketName),
            "dstRemote": key,
        ]
        if let cacheControl {
            // U-04: 実付与は R2 で確認する（G1-9 ⑤）。形式の受理は実測済み。
            params["_config"] = ["UploadHeaders": [["Key": "Cache-Control", "Value": cacheControl]]]
        }
        try await client.callAsyncJob(RcPath.operationsCopyFile, params: params,
                                      onProgress: onProgress)
    }

    /// K-05: 1 オブジェクト 300GB 上限。共有ダイアログで警告を表示する。
    public static let maxObjectBytes: Int64 = 300 * 1024 * 1024 * 1024

    private nonisolated func checkFile(_ fileURL: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            throw ShareError.fileNotFound(fileURL.path)
        }
        guard !isDirectory.boolValue else {
            throw ShareError.cannotShareDirectory(fileURL.lastPathComponent)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64)
            ?? nil
        if let size, size > Self.maxObjectBytes {
            throw ShareError.objectTooLarge(bytes: size)
        }
    }
}

/// §7.2 の staging 掃除の判定。日付 prefix だけで自己完結する。
public enum StagingRetention {

    /// `share-staging/YYYYMMDD/...` の日付部分を取り出す
    public static func stampOfStagingKey(_ key: String) -> String? {
        let prefix = "\(PublicKeyTemplate.stagingPrefix)/"
        guard key.hasPrefix(prefix) else { return nil }
        let rest = key.dropFirst(prefix.count)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let stamp = String(rest[rest.startIndex..<slash])
        guard stamp.count == 8, stamp.allSatisfy(\.isNumber) else { return nil }
        return stamp
    }

    public static func cutoffStamp(now: Date, retentionDays: Int, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let cutoff = cal.date(byAdding: .day, value: -retentionDays, to: now) ?? now
        let c = cal.dateComponents([.year, .month, .day], from: cutoff)
        return String(format: "%04d%02d%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    /// 何度実行しても同じ集合が対象になる（冪等・§8.6.3）
    public static func isExpiredStagingKey(_ key: String, cutoffStamp: String) -> Bool {
        guard let stamp = stampOfStagingKey(key) else { return false }
        return stamp < cutoffStamp
    }
}
