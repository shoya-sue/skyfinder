import Foundation

/// §6.4 のポーリングで集めた状態。UI はこれだけを描画する。
public struct LiveState: Sendable, Equatable {
    /// §02 DESIGN INVARIANT: マウント状態の真実は `listmounts` の応答であり、アプリ内のフラグではない。
    public var mounts: [RcMountPoint] = []
    public var coreStats: RcCoreStats?
    public var vfsStats: RcVfsStats?
    public var lastUpdated: Date?
    public var lastError: String?

    public var isTransferring: Bool { (coreStats?.transfers ?? 0) > 0 }
    /// §5.2「未送信 N 件」
    public var pendingUploads: Int { vfsStats?.pendingUploads ?? 0 }
    public var erroredFiles: Int { vfsStats?.erroredFiles ?? 0 }
    public var transferSpeed: Double { coreStats?.speed ?? 0 }

    public init() {}

    public func isMounted(_ resolvedPath: String) -> Bool {
        let canonical = URL(fileURLWithPath: resolvedPath).standardizedFileURL.path
        return mounts.contains {
            URL(fileURLWithPath: $0.mountPoint).standardizedFileURL.path == canonical
        }
    }

    public func mount(for resolvedPath: String) -> RcMountPoint? {
        let canonical = URL(fileURLWithPath: resolvedPath).standardizedFileURL.path
        return mounts.first {
            URL(fileURLWithPath: $0.mountPoint).standardizedFileURL.path == canonical
        }
    }
}

/// §6.4: 統計ポーリング。
///
/// **状態変更をまたいだ応答は破棄する（MUST）**:
/// アンマウント等の状態変更操作を発行した時刻より前に開始されたポーリング応答が、
/// 操作の完了後に到着することがある。これをそのまま描画すると UI が一瞬「マウント済み」に戻る。
/// 各ポーリング要求に単調増加のシーケンス番号を持たせ、
/// 直近の状態変更操作より古い応答は捨てる。
///
/// §02 の DESIGN INVARIANT は「listmounts の応答が真実」と述べているが、
/// それは**最新の応答**についてであり、古い応答まで信じてよいという意味ではない。
public actor StatsPoller {

    /// §6.4 の間隔表。実装者はこの値をそのまま使うこと。
    public struct Intervals: Sendable {
        public var listMountsForeground: TimeInterval = 5
        public var listMountsBackground: TimeInterval = 15   // 断検知のため、他より短く保つ
        public var coreStatsForeground: TimeInterval = 1     // 転送中のみ
        public var coreStatsBackground: TimeInterval = 30
        public var vfsStatsForeground: TimeInterval = 5
        public var vfsStatsBackground: TimeInterval = 30
        /// 転送が 0 になったら core/stats を 5 秒間隔へ落とす
        public var coreStatsIdleForeground: TimeInterval = 5

        public init() {}
    }

    private let client: RcClient
    private let intervals: Intervals
    private var isForeground = true
    private var task: Task<Void, Never>?
    private var state = LiveState()
    private var observer: (@Sendable (LiveState) -> Void)?

    /// 単調増加のシーケンス番号。状態変更のたびに進める。
    private var stateGeneration: UInt64 = 0

    public init(client: RcClient, intervals: Intervals = Intervals()) {
        self.client = client
        self.intervals = intervals
    }

    public func setObserver(_ observer: @escaping @Sendable (LiveState) -> Void) {
        self.observer = observer
    }

    public func currentState() -> LiveState { state }

    /// マウント / アンマウント等の状態変更を発行したら呼ぶ。
    /// これより前に開始されたポーリング応答は破棄される。
    public func invalidate() {
        stateGeneration &+= 1
    }

    public func setForeground(_ foreground: Bool) {
        isForeground = foreground
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.loop()
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    private func loop() async {
        var lastCoreStats = Date.distantPast
        var lastVfsStats = Date.distantPast
        var lastListMounts = Date.distantPast

        while !Task.isCancelled {
            let now = Date()

            if now.timeIntervalSince(lastListMounts) >= listMountsInterval {
                lastListMounts = now
                await pollListMounts()
            }
            if now.timeIntervalSince(lastVfsStats) >= vfsStatsInterval {
                lastVfsStats = now
                await pollVfsStats()
            }
            if now.timeIntervalSince(lastCoreStats) >= coreStatsInterval {
                lastCoreStats = now
                await pollCoreStats()
            }

            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private var listMountsInterval: TimeInterval {
        isForeground ? intervals.listMountsForeground : intervals.listMountsBackground
    }
    private var vfsStatsInterval: TimeInterval {
        isForeground ? intervals.vfsStatsForeground : intervals.vfsStatsBackground
    }
    private var coreStatsInterval: TimeInterval {
        guard isForeground else { return intervals.coreStatsBackground }
        return state.isTransferring ? intervals.coreStatsForeground : intervals.coreStatsIdleForeground
    }

    // MARK: - 個別のポーリング（応答の陳腐化を判定してから反映する）

    private func pollListMounts() async {
        let generation = stateGeneration
        do {
            let mounts = try await client.listMounts()
            guard generation == stateGeneration else { return }   // 状態変更より古い応答は捨てる
            state.mounts = mounts
            state.lastUpdated = Date()
            state.lastError = nil
        } catch {
            guard generation == stateGeneration else { return }
            state.lastError = (error as? RcError)?.message ?? error.localizedDescription
        }
        observer?(state)
    }

    private func pollVfsStats() async {
        let generation = stateGeneration
        guard let stats = try? await client.vfsStats() else { return }
        guard generation == stateGeneration else { return }
        state.vfsStats = stats
        state.lastUpdated = Date()
        observer?(state)
    }

    private func pollCoreStats() async {
        let generation = stateGeneration
        guard let stats = try? await client.coreStats() else { return }
        guard generation == stateGeneration else { return }
        state.coreStats = stats
        state.lastUpdated = Date()
        observer?(state)
    }

    /// §8.3: 終了判定のように「最新の値でなければ困る」場面で、
    /// 呼び出し側が取り直した `vfs/stats` を反映する。
    /// ポーリング間隔（前景 5 秒）ぶん古い値で判断させないための経路。
    public func applyFreshVfsStats(_ stats: RcVfsStats) {
        invalidate()
        state.vfsStats = stats
        state.lastUpdated = Date()
        observer?(state)
    }

    /// 状態変更操作の直後に、待たずに 1 回だけ取り直す。
    public func refreshNow() async {
        invalidate()
        await pollListMounts()
        await pollVfsStats()
        await pollCoreStats()
    }
}
