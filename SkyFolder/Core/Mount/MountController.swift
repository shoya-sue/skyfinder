import Foundation

/// §10.1 のエラーカタログに対応する、マウント経路のエラー。
public enum MountError: Error, LocalizedError, Sendable, Equatable {
    /// E-03: mount/types に nfsmount が無い
    case mountTypeUnavailable(requested: String, available: [String])
    /// E-04: OS 側に管理外の stale mount
    case foreignStaleMount(path: String)
    /// E-05: mountPoint が空でない（V-04 違反・既存データの隠蔽を防ぐ）
    case mountPointNotEmpty(path: String)
    /// E-15: マウント時の認証エラー（S3 は NewFs で疎通するため接続テスト後でも起きうる）
    case authenticationFailed(alias: String, detail: String)
    case mountFailed(alias: String, detail: String)
    case mountPointCreationFailed(path: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .mountTypeUnavailable(let requested, let available):
            return "このビルドはマウント機能に対応していません。共有機能のみ利用できます。"
                + "（要求: \(requested) / 利用可能: \(available.joined(separator: ", "))）"
        case .foreignStaleMount(let path):
            return "\(path) が別のプロセスによってマウントされています。Finder で取り出してから再試行してください。"
        case .mountPointNotEmpty(let path):
            return "\(path) には既にファイルがあります。空のフォルダを指定してください。"
        case .authenticationFailed(let alias, let detail):
            return "\(alias) をマウントできませんでした。R2 への接続を確認してください。\n\(detail)"
        case .mountFailed(let alias, let detail):
            return "\(alias) をマウントできませんでした。\n\(detail)"
        case .mountPointCreationFailed(let path, let detail):
            return "\(path) を作成できませんでした。\n\(detail)"
        }
    }

    /// §10.1 のエラー ID（診断画面とテストで参照する）
    public var catalogID: String {
        switch self {
        case .mountTypeUnavailable: return "E-03"
        case .foreignStaleMount: return "E-04"
        case .mountPointNotEmpty: return "E-05"
        case .authenticationFailed: return "E-15"
        case .mountFailed, .mountPointCreationFailed: return "E-15"
        }
    }
}

/// §6.2 / §8.4 / §8.6: マウントとアンマウント。
///
/// PRINCIPLE — 「操作」ではなく「望む終了状態」に対して冪等にする。
/// 「マウントする」ではなく「マウントされている状態にする」を実装の単位とする。
public struct MountController: Sendable {

    private let client: RcClient
    private let home: URL

    public init(client: RcClient, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.client = client
        self.home = home
    }

    /// CRIT-01 / E-03: nfsmount が使えるかを起動時に 1 回確認する。
    public func verifyMountTypeAvailable(_ requested: String) async throws -> [String] {
        let types = try await client.mountTypes()
        guard types.contains(requested) else {
            throw MountError.mountTypeUnavailable(requested: requested, available: types)
        }
        return types
    }

    // MARK: - §8.4 stale mount の掃除

    /// マウント実行前に必ず行う。
    ///
    /// - Parameter reclaimedByUs: 手順 0-b で回収した孤児 rcd が居たか。
    ///   居た場合、OS 側に残ったマウントは自分由来と断定できるのでアプリから外してよい（§8.4 手順 2 の例外）。
    public func prepareMountPoint(_ resolvedPath: String,
                                  reclaimedByUs: Bool) async throws {
        // 1. rcd の管理下にあるなら先に外す
        let mounts = (try? await client.listMounts()) ?? []
        if mounts.contains(where: { canonical($0.mountPoint) == canonical(resolvedPath) }) {
            try await ensureUnmounted(resolvedPath)
        }

        // 2. rcd の管理外だが OS 側ではマウント状態
        //
        // **判定に `statfs` を使ってはならない。**
        // ここで相手にするのは「サーバ（rcd）が死んだかもしれないマウント」であり、
        // hard mount の上では `statfs` も `open` も**永久に返らない**。
        // E-04 を出すつもりの検査が、そのままアプリのハングになる。
        // カーネルのマウント表（`getmntinfo`）だけを見る判定を使う。
        if SystemMountTable.isMountedAccordingToTable(resolvedPath) {
            if reclaimedByUs {
                // 自分由来と断定できる残骸。SIGKILL まで進んだ場合にここへ来る。
                // `umount` はパスを traverse しないので、詰まったマウントにも使える。
                _ = SystemMountTable.forceUnmount(resolvedPath)
                if SystemMountTable.isMountedAccordingToTable(resolvedPath) {
                    throw MountError.foreignStaleMount(path: resolvedPath)
                }
            } else {
                throw MountError.foreignStaleMount(path: resolvedPath)
            }
        }

        // ここから先はマウントが無いことを確認済みなので、ファイルシステムに触れてよい
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: resolvedPath, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw MountError.mountPointNotEmpty(path: resolvedPath)
            }
            // 4. 存在し、かつ空でない → V-04 違反。マウントを中止し E-05
            let contents = (try? fm.contentsOfDirectory(atPath: resolvedPath)) ?? []
            let significant = contents.filter { $0 != ".DS_Store" }
            if !significant.isEmpty {
                throw MountError.mountPointNotEmpty(path: resolvedPath)
            }
        } else {
            // 3. 存在しない → 作成（0700）
            do {
                try fm.createDirectory(atPath: resolvedPath, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
            } catch {
                throw MountError.mountPointCreationFailed(path: resolvedPath,
                                                          detail: error.localizedDescription)
            }
        }
    }

    // MARK: - §8.6.1 冪等なマウント / アンマウント

    /// 「マウントされている状態にする」。
    ///
    /// すでにマウント済みなら成功として返す — `already mounted` / `exit status 78` は
    /// 「望む終了状態にすでに達している」ことを示すため、エラーにしない（§8.6.1 MUST）。
    ///
    /// - Returns: 実行後に `listmounts` で確認した実際のマウントポイント（§6.2 RULE の `mountPoint`）
    @discardableResult
    public func ensureMounted(bucket: BucketConfig,
                              advanced: AdvancedSettings,
                              reclaimedByUs: Bool = false) async throws -> RcMountPoint {
        let resolved = bucket.resolvedMountPath(home: home)
        try await prepareMountPoint(resolved, reclaimedByUs: reclaimedByUs)

        let params = MountOptionsBuilder.mountParams(bucket: bucket,
                                                     advanced: advanced,
                                                     resolvedMountPoint: resolved)
        do {
            // §6.5: マウント操作は同期で呼ぶ（失敗を即座に返す必要があり、処理が短いため）
            try await client.callRaw(RcPath.mountMount, params: params, timeout: 60)
        } catch let error as RcError {
            if error.meansAlreadyMounted {
                // 状態としては達成されている（listmounts は 1 件のまま・実測）
            } else if error.meansForbidden {
                throw MountError.authenticationFailed(alias: bucket.alias, detail: error.message)
            } else {
                throw MountError.mountFailed(alias: bucket.alias, detail: error.message)
            }
        }

        // §02 DESIGN INVARIANT: 実行後に listmounts で確認し、その結果のみを UI に反映する。
        //
        // **要求したパスで照合する。** バケット名（fs）だけのフォールバックを置くと、
        // 同じバケットが別のパスにマウントされているときに、
        // 要求したパスには何も無いのに「成功」と返してしまう。
        // rclone は渡したパス表現をそのまま返すので（M-18）、正常系でフォールバックは要らない。
        let mounts = try await client.listMounts()
        guard let actual = mounts.first(where: { canonical($0.mountPoint) == canonical(resolved) })
        else {
            throw MountError.mountFailed(alias: bucket.alias,
                                         detail: "マウント後に listmounts で確認できませんでした")
        }
        return actual
    }

    /// 「マウントされていない状態にする」。
    ///
    /// `mount not found` は成功として扱う（§8.6.1 MUST）。
    ///
    /// **MUST — rclone の `mount/unmount` だけに頼らない（M-23）。**
    ///
    /// 実測（rclone v1.75.0 / macOS 26.6.2）: 生きている nfsmount に対する
    /// `mount/unmount` と `mount/unmountall` は、**応答を返さないことがある**
    /// （25 秒以上待っても返らず、rclone のログにも受信行以降が出ない）。
    /// 一方 `/sbin/umount` は同じマウントを **0.017 秒**で外せる。
    ///
    /// §8.6 の原則は「操作ではなく**望む終了状態**に対して冪等にする」であり、
    /// 目的は「マウントされていない状態」である。
    /// RC API が期限内にそこへ到達させられないなら、OS の `umount` で到達させる。
    /// 順序を逆にしない（まず RC API を試すのは、rclone 側の後始末を走らせるため）。
    public func ensureUnmounted(_ mountPoint: String,
                                rcTimeout: TimeInterval = 10) async throws {
        // 既に外れているなら何もしない（判定はファイルシステムに触れない方法で行う）
        guard SystemMountTable.isMountedAccordingToTable(mountPoint) else { return }

        var rcError: RcError?
        do {
            try await client.callRaw(RcPath.mountUnmount, params: ["mountPoint": mountPoint],
                                     timeout: rcTimeout)
        } catch let error as RcError {
            // `mount not found` は成功扱い。それ以外は握って OS 側の unmount へ進む。
            if !error.meansMountNotFound { rcError = error }
        }

        // 望む終了状態に達したか確認する
        if !SystemMountTable.isMountedAccordingToTable(mountPoint) { return }

        // 到達していないので OS の unmount で外す。
        // これはパスを traverse しないので、詰まったマウントにも効く。
        if SystemMountTable.forceUnmount(mountPoint),
           !SystemMountTable.isMountedAccordingToTable(mountPoint) {
            return
        }
        throw MountError.mountFailed(
            alias: mountPoint,
            detail: rcError?.message ?? "アンマウントできませんでした（OS 側の解除も失敗）")
    }

    /// 終了時・プロファイル切替時に使う。マウントが 0 件でも `{}` を返す（実測）。
    ///
    /// **M-23**: 生きた nfsmount がある状態では応答が返らないことがあるため、
    /// 期限を切って、到達していなければ OS の `umount` で仕上げる。
    /// アプリ終了時にここで詰まると、ユーザーは終了できないアプリを抱えることになる。
    ///
    /// - Parameter knownMountPoints: RC API が応答しなかった場合に OS 側で外す対象。
    ///   空なら `listmounts` の結果を使うが、それ自体が応答しない場合に備えて呼び出し側が渡せる。
    public func unmountAll(knownMountPoints: [String] = [],
                           rcTimeout: TimeInterval = 10) async throws {
        let targets = knownMountPoints.isEmpty
            ? ((try? await client.listMounts()) ?? []).map(\.mountPoint)
            : knownMountPoints

        do {
            try await client.callRaw(RcPath.mountUnmountAll, timeout: rcTimeout)
        } catch {
            // 応答が無くても、望む終了状態に達していれば問題ない
        }

        for path in targets where SystemMountTable.isMountedAccordingToTable(path) {
            _ = SystemMountTable.forceUnmount(path)
        }
    }

    /// §02 DESIGN INVARIANT: マウント状態の唯一の情報源。
    public func currentMounts() async throws -> [RcMountPoint] {
        try await client.listMounts()
    }

    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
