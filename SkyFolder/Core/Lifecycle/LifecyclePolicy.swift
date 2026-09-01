import Foundation

/// §8.2 / §8.3 / §5.5 の判断を、副作用のない関数として切り出したもの。
///
/// これらの判断は本来アプリ本体（`@MainActor` の ObservableObject）に埋まりがちだが、
/// そこに置くと**テストできない**。マウント断の検知・終了時のデータ保護・
/// メニューバーの状態は誤ると実害が出る（通知が出ない・未送信データが消える）ので、
/// 判断だけをここへ出して単体で検証する。
public enum LifecyclePolicy {

    // MARK: - §8.2 マウント断の検知（T-G14）

    /// 直前に見えていたマウントと今回の応答を比べ、**通知すべき alias** を返す。
    ///
    /// - ユーザーがアプリからアンマウントしたものは通知しない（意図的な操作）
    /// - Finder / コマンドで手動アンマウントされたものだけを通知する
    /// - **自動再マウントはしない**（意図的な取り出しを尊重する・§8.2）
    ///
    /// - Parameters:
    ///   - previous: 直前のポーリングで見えていたマウントポイント（正規化済み）
    ///   - current: 今回の `listmounts` で見えたマウントポイント（正規化済み）
    ///   - buckets: alias → 正規化済みマウントパス
    ///   - manuallyUnmounted: アプリから明示的にアンマウントした alias（セッションスコープ）
    public static func mountsLost(previous: Set<String>,
                                  current: Set<String>,
                                  buckets: [String: String],
                                  manuallyUnmounted: Set<String>) -> [String] {
        let lost = previous.subtracting(current)
        guard !lost.isEmpty else { return [] }
        return buckets
            .filter { alias, path in lost.contains(path) && !manuallyUnmounted.contains(alias) }
            .keys
            .sorted()
    }

    // MARK: - §8.3 終了シーケンス（T-G17）

    public enum TerminationDecision: Sendable, Equatable {
        /// 未送信が 0 なので、そのまま終了してよい
        case proceed
        /// 未送信があるので、ユーザーに尋ねる
        case askUser(pending: Int)
    }

    /// 終了要求時の判断。**未送信データを無視して rcd を殺すとそのデータは失われる**（DD-001 R-03）。
    public static func terminationDecision(pendingUploads: Int) -> TerminationDecision {
        pendingUploads > 0 ? .askUser(pending: pendingUploads) : .proceed
    }

    /// 「送信完了を待つ」を選んだときの上限。
    ///
    /// 通常は 5 分。**システムのログアウト・シャットダウン時は OS の強制終了タイムアウトがあるため
    /// 20 秒に短縮する**（R-G10）。送り切れない場合は次回起動時に通知する。
    public static func uploadWaitLimit(isSystemLogout: Bool) -> TimeInterval {
        isSystemLogout ? 20 : 300
    }

    // MARK: - §8.2 ネットワーク断

    /// `core/stats` の errors から断を判定する（§8.2）。
    ///
    /// **この信号だけでは「回復した」と「リトライがバックオフに入った」を区別できない。**
    /// errors は累積カウンタで、増分が止まった理由が回線復帰なのか、rclone が再試行を
    /// 間引いたのか、そもそも転送が無いのかを、値からは判別できない。そこが分かっていない境界で、
    /// 確実にするには実際の疎通確認（軽い RC 呼び出し）が要る。
    ///
    /// そのうえで、**サンプリング間隔への依存だけは外す**:
    ///
    /// - **検知**: 直近 `window` 秒に `requiredIncreases` 回以上の増加があったか。
    ///   「連続する 2 回のポーリングで増加」を要求してはいけない — 前景・転送中の
    ///   `core/stats` は 1 秒間隔だが、rclone のリトライはバックオフを挟むので
    ///   増加は数秒〜数十秒おきになる。連続を求めると**実際に断でも検知できない**（偽陰性）
    /// - **解除**: 窓の中の増加が 0 になって初めて解除する。増えなかった 1 回で戻すと、
    ///   **断が続いている最中に「復帰」と誤認**して `vfs/refresh` を撃ち、
    ///   断→解除→refresh→増加→断 のフラップになる
    ///
    /// - Parameter recentIncreases: errors が増えた時刻。呼び出し側が窓の外を捨てて渡す
    public static func isOffline(recentIncreases: [Date], now: Date = Date(),
                                 window: TimeInterval = offlineWindow,
                                 requiredIncreases: Int = 2) -> Bool {
        recentIncreases.filter { now.timeIntervalSince($0) <= window }.count >= requiredIncreases
    }

    /// 断の判定に使う時間窓。検知にも解除にも同じ窓を使う。
    public static let offlineWindow: TimeInterval = 30

    // MARK: - R-G08 プロファイル切替

    public enum SwitchDecision: Sendable, Equatable {
        case proceed
        /// 未送信があるので切替を保留する。省くとアプリ終了時と同じデータ喪失が切替経路で起きる。
        case blocked(pending: Int)
    }

    public static func profileSwitchDecision(pendingUploads: Int) -> SwitchDecision {
        pendingUploads > 0 ? .blocked(pending: pendingUploads) : .proceed
    }

    // MARK: - §5.5 メニューバーの状態

    public enum MenuBarState: Sendable, Equatable {
        case normal
        case transferring(speed: Double, remaining: Int)
        case pendingUploads(count: Int)
        case mountLost(alias: String)
        case engineStopped
    }

    /// 表示すべき状態を決める。**危険側・異常側を優先して出す**（正常表示で異常を隠さない）。
    ///
    /// - Parameters:
    ///   - engineRunning: rcd が稼働しているか
    ///   - startupFinished: 起動シーケンスが終わったか（途中の未マウントを断と誤認しないため）
    ///   - expectedMountedAliases: マウントされているべき alias（autoMount かつ手動アンマウトしていない）
    ///   - actuallyMountedAliases: いま実際にマウントされている alias
    public static func menuBarState(engineRunning: Bool,
                                    startupFinished: Bool,
                                    hasProfile: Bool,
                                    expectedMountedAliases: Set<String>,
                                    actuallyMountedAliases: Set<String>,
                                    isTransferring: Bool,
                                    transferSpeed: Double,
                                    pendingUploads: Int) -> MenuBarState {
        if startupFinished, hasProfile, !engineRunning { return .engineStopped }
        if startupFinished {
            let missing = expectedMountedAliases.subtracting(actuallyMountedAliases).sorted()
            if let alias = missing.first { return .mountLost(alias: alias) }
        }
        if isTransferring {
            return .transferring(speed: transferSpeed, remaining: pendingUploads)
        }
        if pendingUploads > 0 { return .pendingUploads(count: pendingUploads) }
        return .normal
    }

    // MARK: - §8.6.3 autoMount のスコープ

    /// 起動時にマウントすべき alias。
    ///
    /// `autoMount`（永続設定）は**起動時に一度だけ評価する**。
    /// 実行中に手動アンマウントされた事実はセッションスコープのメモリにのみ保持し、永続化しない。
    /// したがって次回起動時は再び `autoMount` に従ってマウントされる
    /// — アンマウントしたまま覚えておく実装にはしない。
    public static func aliasesToMountAtStartup(buckets: [(alias: String, autoMount: Bool)])
        -> [String] {
        buckets.filter(\.autoMount).map(\.alias)
    }

    /// 実行中（rcd の自動再起動後など）にマウントし直すべき alias。
    /// こちらは手動アンマウントの事実を尊重する。
    public static func aliasesToRemount(buckets: [(alias: String, autoMount: Bool)],
                                        manuallyUnmounted: Set<String>) -> [String] {
        buckets.filter { $0.autoMount && !manuallyUnmounted.contains($0.alias) }.map(\.alias)
    }
}
