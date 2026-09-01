import Foundation
import Testing
@testable import SkyFolderKit

@Suite("ライフサイクルの判断（§8.2 / §8.3 / §5.5）")
struct LifecyclePolicyTests {

    private let buckets = ["private": "/Users/x/SkyFolder/p/private",
                           "public": "/Users/x/SkyFolder/p/public"]

    // MARK: - T-G14 / §8.2 マウント断の検知

    /// Finder から手動で取り出したら通知する（自動再マウントはしない）
    @Test("T-G14: 手動アンマウントされたマウントを検知する")
    func detectsManualUnmount() {
        let lost = LifecyclePolicy.mountsLost(
            previous: Set(buckets.values),
            current: ["/Users/x/SkyFolder/p/private"],
            buckets: buckets,
            manuallyUnmounted: [])
        #expect(lost == ["public"])
    }

    /// アプリからアンマウントしたものは通知しない（意図的な操作）
    @Test("アプリからのアンマウントでは通知しない")
    func ignoresIntentionalUnmount() {
        let lost = LifecyclePolicy.mountsLost(
            previous: Set(buckets.values),
            current: ["/Users/x/SkyFolder/p/private"],
            buckets: buckets,
            manuallyUnmounted: ["public"])
        #expect(lost.isEmpty)
    }

    @Test("変化がなければ通知しない")
    func noChangeNoNotification() {
        #expect(LifecyclePolicy.mountsLost(previous: Set(buckets.values),
                                           current: Set(buckets.values),
                                           buckets: buckets,
                                           manuallyUnmounted: []).isEmpty)
    }

    /// 新しくマウントされた（増えた）ときは通知しない
    @Test("マウントが増えたときは通知しない")
    func mountAddedIsNotLoss() {
        #expect(LifecyclePolicy.mountsLost(previous: ["/Users/x/SkyFolder/p/private"],
                                           current: Set(buckets.values),
                                           buckets: buckets,
                                           manuallyUnmounted: []).isEmpty)
    }

    /// 2 つ同時に外れたら 2 つとも通知する
    @Test("複数同時の断を取りこぼさない")
    func detectsMultipleLosses() {
        let lost = LifecyclePolicy.mountsLost(previous: Set(buckets.values),
                                              current: [],
                                              buckets: buckets,
                                              manuallyUnmounted: [])
        #expect(lost == ["private", "public"])
    }

    // MARK: - T-G17 / §8.3 終了時のデータ保護

    /// 未送信があるなら終了を保留してユーザーに尋ねる。
    /// これを省くと、保存済みに見えてまだクラウドに無いデータが失われる（DD-001 R-03）。
    @Test("T-G17: 未送信があれば終了を保留する")
    func holdsTerminationWhenPending() {
        #expect(LifecyclePolicy.terminationDecision(pendingUploads: 3) == .askUser(pending: 3))
        #expect(LifecyclePolicy.terminationDecision(pendingUploads: 0) == .proceed)
        #expect(LifecyclePolicy.terminationDecision(pendingUploads: 1) == .askUser(pending: 1))
    }

    /// R-G10: ログアウト・シャットダウン時は OS の強制終了タイムアウトがあるため 20 秒に短縮する
    @Test("R-G10: ログアウト時は待機を 20 秒に短縮する")
    func shortensWaitOnLogout() {
        #expect(LifecyclePolicy.uploadWaitLimit(isSystemLogout: false) == 300)
        #expect(LifecyclePolicy.uploadWaitLimit(isSystemLogout: true) == 20)
    }

    /// R-G08: 切替時も同じ判定を行う。省くと切替経路で同じデータ喪失が起きる。
    @Test("R-G08: 未送信があればプロファイル切替を止める")
    func blocksProfileSwitchWhenPending() {
        #expect(LifecyclePolicy.profileSwitchDecision(pendingUploads: 2) == .blocked(pending: 2))
        #expect(LifecyclePolicy.profileSwitchDecision(pendingUploads: 0) == .proceed)
    }

    // MARK: - §5.5 メニューバーの状態

    private func state(engineRunning: Bool = true,
                       startupFinished: Bool = true,
                       hasProfile: Bool = true,
                       expected: Set<String> = ["private"],
                       actual: Set<String> = ["private"],
                       transferring: Bool = false,
                       speed: Double = 0,
                       pending: Int = 0) -> LifecyclePolicy.MenuBarState {
        LifecyclePolicy.menuBarState(engineRunning: engineRunning,
                                     startupFinished: startupFinished,
                                     hasProfile: hasProfile,
                                     expectedMountedAliases: expected,
                                     actuallyMountedAliases: actual,
                                     isTransferring: transferring,
                                     transferSpeed: speed,
                                     pendingUploads: pending)
    }

    @Test("すべて正常なら normal")
    func normalState() { #expect(state() == .normal) }

    /// **異常側を正常表示で隠さない**
    @Test("rcd 停止はほかの何より優先して出す")
    func engineStoppedWins() {
        #expect(state(engineRunning: false, transferring: true, pending: 5) == .engineStopped)
    }

    @Test("マウント断は転送中表示より優先する")
    func mountLostBeatsTransferring() {
        #expect(state(expected: ["private", "public"], actual: ["private"],
                      transferring: true, pending: 3) == .mountLost(alias: "public"))
    }

    /// 起動シーケンスの途中で「まだマウントしていない」状態を断と誤認しない
    @Test("起動中は未マウントを断と誤認しない")
    func doesNotReportLossDuringStartup() {
        #expect(state(startupFinished: false, expected: ["private"], actual: []) == .normal)
    }

    @Test("プロファイル未設定なら rcd 停止を報告しない（オンボーディング中）")
    func noEngineComplaintWithoutProfile() {
        #expect(state(engineRunning: false, hasProfile: false, expected: [], actual: []) == .normal)
    }

    @Test("転送中は速度と残件数を出す")
    func transferringState() {
        #expect(state(transferring: true, speed: 1024, pending: 2)
                == .transferring(speed: 1024, remaining: 2))
    }

    @Test("転送が止まっていて未送信が残っていれば警告する")
    func pendingWithoutTransfer() {
        #expect(state(transferring: false, pending: 4) == .pendingUploads(count: 4))
    }

    // MARK: - §8.6.3 autoMount のスコープ

    /// `autoMount`（永続設定）は**起動時に一度だけ評価する**。
    /// 実行中の手動アンマウントは永続化しないので、次回起動時は再びマウントされる。
    @Test("§8.6.3: 起動時は手動アンマウントの記憶を持ち越さない")
    func startupIgnoresSessionState() {
        let buckets = [(alias: "private", autoMount: true),
                       (alias: "public", autoMount: true),
                       (alias: "archive", autoMount: false)]
        #expect(LifecyclePolicy.aliasesToMountAtStartup(buckets: buckets) == ["private", "public"])
        // 実行中の再マウントでは手動アンマウントを尊重する
        #expect(LifecyclePolicy.aliasesToRemount(buckets: buckets,
                                                 manuallyUnmounted: ["public"]) == ["private"])
    }
}

/// §8.2「ネットワーク断」の判定。
///
/// 設計書の断対応表は 4 行あり、他の 3 行（アプリからのアンマウント・手動アンマウント・
/// rcd 死亡）は実装されていたが、**この行だけ丸ごと未実装だった**。
/// `RcCoreStats.errors` はデコードされるだけでどこからも読まれない
/// デッドフィールドになっていた。
@Suite("§8.2 ネットワーク断の判定")
struct OfflineDecisionTests {

    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    @Test("増加が無ければ断ではない")
    func noIncreaseIsNotOffline() {
        #expect(!LifecyclePolicy.isOffline(recentIncreases: [], now: now))
    }

    /// 単発の転送失敗でも errors は増える。1 回で断にするとバッジが点滅する。
    @Test("窓の中に 1 回だけなら断にしない")
    func singleIncreaseIsNotOffline() {
        #expect(!LifecyclePolicy.isOffline(recentIncreases: [ago(5)], now: now))
    }

    /// **「連続する 2 回のポーリング」ではなく「窓の中に 2 回」で判定する。**
    /// 前景・転送中の core/stats は 1 秒間隔だが、rclone のリトライはバックオフを挟むので
    /// 増加は数秒〜数十秒おき。連続を求めると実際の断でも検知できない。
    @Test("窓の中に 2 回あれば、間隔が空いていても断とみなす")
    func twoIncreasesWithinWindowMeanOffline() {
        #expect(LifecyclePolicy.isOffline(recentIncreases: [ago(25), ago(3)], now: now),
                "22 秒空いていても、窓の中に 2 回あれば断")
    }

    /// 解除は窓が空くまで待つ。1 回静かなだけで戻すと、断の最中に「復帰」と誤認して
    /// vfs/refresh を撃ち、断→解除→refresh→増加→断 のフラップになる。
    @Test("窓の外へ出た増加は数えない（解除にヒステリシスが効く）")
    func increasesOutsideWindowAreIgnored() {
        #expect(!LifecyclePolicy.isOffline(recentIncreases: [ago(120), ago(90)], now: now),
                "どちらも 30 秒の窓の外なので解除されていること")
    }

    @Test("窓の内と外が混ざる場合、内側だけを数える")
    func onlyIncreasesInsideWindowCount() {
        #expect(!LifecyclePolicy.isOffline(recentIncreases: [ago(100), ago(2)], now: now),
                "窓の中は 1 回だけなので断にしない")
        #expect(LifecyclePolicy.isOffline(recentIncreases: [ago(100), ago(20), ago(2)], now: now),
                "窓の中が 2 回になれば断")
    }

    @Test("窓と必要回数は呼び出し側で変えられる")
    func windowAndThresholdAreConfigurable() {
        #expect(LifecyclePolicy.isOffline(recentIncreases: [ago(5)], now: now, requiredIncreases: 1))
        #expect(!LifecyclePolicy.isOffline(recentIncreases: [ago(25), ago(3)], now: now, window: 10),
                "窓を 10 秒にすると ago(25) は外れて 1 回になる")
    }
}
