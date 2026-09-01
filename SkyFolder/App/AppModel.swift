import AppKit
import Combine
import Foundation
import os
import ServiceManagement
import SwiftUI
import UserNotifications
import SkyFolderKit

/// §5.5: メニューバーの 5 状態。判定は `LifecyclePolicy` にあり、ここは別名だけ。
typealias MenuBarState = LifecyclePolicy.MenuBarState

/// アプリ全体の状態と、§08 のライフサイクルを持つ。
///
/// **§02 DESIGN INVARIANT**: 「マウントされているか」の真実は常に `mount/listmounts` の応答であり、
/// アプリ内のフラグではない。マウント状態は `StatsPoller` が listmounts から再構築し、
/// UI はその結果のみを描画する。**アプリがマウント要求を出したこと自体を状態として保持してはならない。**
@MainActor
final class AppModel: ObservableObject {

    private let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "model")

    // MARK: - 公開状態

    @Published private(set) var document = ProfilesDocument()
    @Published private(set) var liveState = LiveState()
    @Published private(set) var rcdStatus = RcdStatus()
    @Published private(set) var mountTypes: [String] = []
    @Published private(set) var rcloneVersion = ""
    /// docs/BUNDLED.md と照合できるのはこちら（配布物・署名前）
    @Published private(set) var rcloneDistributionSHA256 = ""
    /// 署名後の実体。照合対象ではない（T-G30 の注記を参照）
    @Published private(set) var rcloneEmbeddedSHA256 = ""

    @Published var currentError: CatalogedError?
    @Published var toast: String?
    @Published private(set) var isBusy = false
    @Published private(set) var startupFinished = false

    /// §4.4 手順 5 を通過したバケット。§7.1 RULE の解決対象になる。
    @Published private(set) var publicURLVerifiedAliases: Set<String> = []
    @Published private(set) var connectionResults: [ConnectionTest.StepResult] = []

    /// §8.2: 実行中に手動アンマウントされた事実は**セッションスコープのメモリにのみ**保持し、
    /// 永続化しない。したがって次回起動時は再び autoMount に従ってマウントされる（§8.6.3）。
    private var manuallyUnmountedAliases: Set<String> = []
    /// 直前のポーリングで見えていたマウント。断の検知に使う。
    private var previouslyMountedPaths: Set<String> = []

    @Published private(set) var isTerminating = false
    /// R-G10: ログアウト・シャットダウン時は OS の強制終了タイムアウトがあるため待機を短縮する
    private(set) var systemLogoutInProgress = false
    @Published var pendingUploadsAtTermination: Int?
    private(set) var isReadyToTerminate = false

    /// 起動時に孤児 rcd を回収したか。§8.4 手順 2 の例外規定に使う。
    ///
    /// **このフラグは「起動時の自動マウント」だけに渡す。**
    /// セッション中ずっと渡し続けると、数時間後にユーザーが同じパスへ別のもの
    /// （自前の rclone / sshfs / ディスクイメージ）をマウントしていた場合に、
    /// E-04 の手動解除案内を出さずにアプリが**他人のボリュームを強制解除する**。
    /// §8.4 手順 2 の例外は「手順 0-b で回収した孤児が残したマウント」に限定されている。
    private var reclaimedOrphans = false

    // MARK: - 依存

    let paths = AppPaths()
    private(set) var profileStore: ProfileStore
    private let historyStore: ShareHistoryStore
    private let rcloneURL: URL
    private var supervisor: RcdSupervisor?
    private(set) var client: RcClient?
    private var poller: StatsPoller?
    private var logWatcher: LogWatcher?
    private(set) var shareService: ShareService?

    private var masker = LogMasker()

    /// SEC-G04: マスク対象の実値を登録し直す。
    /// rc-user / rc-pass は**プロセス起動ごとに変わる**ので、endpoint が確定した時点で作り直す。
    ///
    /// 正規表現（`Using --user (\S+)`）だけに頼ると、rclone がログの書式を変えた瞬間に
    /// rc-user が診断画面へ平文で出る。リテラル照合と併せて二重防御にする。
    private func rebuildMasker(credentials: R2Credentials, accountId: String,
                               endpoint: RcEndpoint?) {
        masker = LogMasker(secrets: [credentials.accessKeyId, credentials.secretAccessKey]
                                    + (endpoint.map { [$0.password] } ?? []),
                           accountIds: [accountId],
                           rcUsers: endpoint.map { [$0.user] } ?? [])
    }

    /// 現在の rcd に適用済みの設定の指紋。
    /// 環境変数で渡す設定は**プロセス起動時にしか反映できない**ので、
    /// 変わったかどうかをここで判定する（§6.2 注入経路表）。
    private var appliedRestartSignature: String?

    init() {
        // 同梱 rclone。Bundle.main.url(forResource:) で取得する（G0 AC）。
        rcloneURL = Bundle.main.url(forResource: "rclone", withExtension: nil)
            ?? URL(fileURLWithPath: "/nonexistent/rclone")
        profileStore = ProfileStore(paths: paths)
        historyStore = ShareHistoryStore(paths: paths)
    }

    var activeProfile: Profile? { document.activeProfile }
    var needsOnboarding: Bool { document.profiles.isEmpty || document.activeProfileId.isEmpty }

    // MARK: - §8.1 起動シーケンス
    //
    // 手順 0〜8 は「前回どこで落ちたか」を問わず毎回すべて実行する。
    // 途中再開のための進捗記録を持たない（その記録自体が壊れうる）。

    func start() async {
        guard !startupFinished else { return }
        do {
            try paths.ensureDirectories(profileId: nil)

            // 0-b. rcd の重複を防ぐ（CRIT-03 / §8.6.2）
            let supervisor = RcdSupervisor(rcloneURL: rcloneURL, paths: paths)
            self.supervisor = supervisor
            let reclaim = await supervisor.reclaimOrphans()
            reclaimedOrphans = !reclaim.reclaimedPIDs.isEmpty
            if reclaimedOrphans {
                logger.notice("孤児 rcd を回収: \(reclaim.reclaimedPIDs.count, privacy: .public) 件")
            }

            // 1. profiles.json 読込・スキーマバージョン検証
            document = try profileStore.load()

            // 3. 同梱 rclone のバージョン確認（v1.68 未満なら E-02）
            let version = try await supervisor.verifyVersion()
            rcloneVersion = version.version
            rcloneEmbeddedSHA256 = DiagnosticsCollector.sha256(ofFileAt: rcloneURL) ?? ""
            rcloneDistributionSHA256 = DiagnosticsCollector.distributionSHA256()?.sha ?? ""

            await supervisor.setHandlers(
                onRestarted: { [weak self] endpoint in
                    await self?.handleRcdRestarted(endpoint)
                },
                onGaveUp: { [weak self] error in
                    await self?.presentError(error)
                },
                statusObserver: { [weak self] status in
                    Task { @MainActor in self?.rcdStatus = status }
                })

            guard let profile = document.activeProfile else {
                // オンボーディングへ。rcd はプロファイル確定後に起動する。
                startupFinished = true
                return
            }
            try await activate(profile: profile)
            startupFinished = true
        } catch {
            presentErrorSync(error)
            startupFinished = true
        }
    }

    /// プロファイルを有効化する（起動時・設定保存・プロファイル切替の共通経路）。
    ///
    /// **環境変数で渡す設定は rcd のプロセス起動時にしか反映できない**（§6.2 注入経路表）。
    /// したがって accountId / 認証情報 / transfers / チャンクサイズが変わったときは
    /// rcd を作り直す必要がある。変わっていなければ作り直さない
    /// — 再起動は全マウントの解除を伴うので、設定を触るたびに起こしてよいものではない。
    func activate(profile: Profile) async throws {
        guard let supervisor else { return }
        try paths.ensureDirectories(profileId: profile.id)

        // 2. Keychain から認証情報を取得。失敗したら設定画面へ誘導して停止する。
        let credentials = try profileStore.credentials(for: profile)

        // SEC-G04: 実値をマスカに登録する
        masker = LogMasker(secrets: [credentials.accessKeyId, credentials.secretAccessKey],
                           accountIds: [profile.accountId])

        let rcloneURL = self.rcloneURL
        let paths = self.paths
        let makeSpec: @Sendable () -> RcdLaunchSpec = {
            RcdLaunchSpec(rcloneURL: rcloneURL, profile: profile,
                          credentials: credentials, paths: paths)
        }
        let signature = makeSpec().restartSignature
        let alreadyRunning = await supervisor.currentStatus().isRunning
        let needsRestart = !alreadyRunning || appliedRestartSignature != signature

        // 走っているポーリングと監視を必ず止める（止めないと呼ぶたびに積み上がる）
        await poller?.stop()
        poller = nil
        logWatcher?.stop()
        logWatcher = nil

        if needsRestart, alreadyRunning {
            // R-G08 と同じ理由: 作り直す前に未送信データを守る。
            // これを省くと、設定を保存しただけでアプリ終了時と同じデータ喪失が起きる。
            if liveState.pendingUploads > 0 {
                toast = "未送信のファイルが \(liveState.pendingUploads) 件あるため、"
                    + "接続設定の変更は送信完了後に反映されます。"
                await restartPolling(profile: profile)
                return
            }
            if let client {
                try? await MountController(client: client).unmountAll(rcTimeout: 5)
            }
            await supervisor.stop()
        }

        // 4. rcd 起動 → 実ポートを取得 → rcd.pid に記録
        let endpoint = try await supervisor.start(specFactory: makeSpec)
        appliedRestartSignature = signature
        rebuildMasker(credentials: credentials, accountId: profile.accountId, endpoint: endpoint)
        let client = RcClient(endpoint: endpoint)
        self.client = client
        self.shareService = ShareService(client: client, history: historyStore)

        // 5. mount/types → nfsmount の存在確認（無ければ E-03・マウント機能を無効化）
        let controller = MountController(client: client)
        do {
            mountTypes = try await controller.verifyMountTypeAvailable(profile.advanced.mountType)
        } catch {
            mountTypes = (try? await client.mountTypes()) ?? []
            presentErrorSync(error)
        }

        // 6. mount/listmounts → この rcd が管理するマウントの把握
        // 8. ポーリング開始
        await restartPolling(profile: profile)

        // 0-c. 前回のプローブが残っていれば掃除する（失敗扱いにしない）
        let test = ConnectionTest(client: client)
        for bucket in profile.buckets {
            _ = await test.cleanLeftoverProbes(bucketName: bucket.bucketName)
        }

        // §7.2: staging の掃除（起動時に 1 回）
        if let shareService {
            for bucket in profile.buckets where !bucket.visibility.isPublic {
                _ = try? await shareService.cleanStaging(bucketName: bucket.bucketName)
            }
        }

        // 7. autoMount=true のバケットを順にマウント
        guard !mountTypes.isEmpty else { return }
        for alias in LifecyclePolicy.aliasesToMountAtStartup(
            buckets: profile.buckets.map { ($0.alias, $0.autoMount) }) {
            guard let bucket = profile.bucket(alias: alias) else { continue }
            await mount(bucket: bucket, profile: profile,
                        announceErrors: false, isStartupAutoMount: true)
        }
        await poller?.refreshNow()
    }

    /// ポーリングとログ監視を張り直す。古いものは呼び出し側が止めておくこと。
    private func restartPolling(profile: Profile) async {
        guard let client else { return }
        let poller = StatsPoller(client: client)
        self.poller = poller
        await poller.setObserver { [weak self] state in
            Task { @MainActor in self?.apply(state) }
        }
        await poller.start()

        // E-14 の検知: rclone のログを監視する
        let watcher = LogWatcher(logFile: paths.logFile(profileId: profile.id))
        self.logWatcher = watcher
        watcher.start { [weak self] detection in
            Task { @MainActor in self?.handleReadOnlyDenial(detection) }
        }
        updateReadOnlyWatchTargets(profile: profile)
    }

    // MARK: - マウント操作

    /// - Parameter isStartupAutoMount: 起動シーケンス（§8.1 手順 7）からの呼び出しか。
    ///   §8.4 手順 2 の例外（自分由来の残骸を強制解除してよい）は**この経路にだけ**適用する。
    func mount(bucket: BucketConfig, profile: Profile,
               announceErrors: Bool = true,
               isStartupAutoMount: Bool = false) async {
        guard let client else { return }
        isBusy = true
        defer { isBusy = false }
        // 状態を変えるので、進行中のポーリング応答を陳腐化させる（§6.4）
        await poller?.invalidate()
        let controller = MountController(client: client)
        do {
            _ = try await controller.ensureMounted(
                bucket: bucket, advanced: profile.advanced,
                reclaimedByUs: isStartupAutoMount && reclaimedOrphans)
            manuallyUnmountedAliases.remove(bucket.alias)
            await poller?.refreshNow()
            updateReadOnlyWatchTargets(profile: profile)
        } catch {
            if announceErrors { presentErrorSync(error) }
            else {
                // SEC-G04 / M-06: rclone の生エラー本文には endpoint（= accountId）が、
                // SigV4 系の失敗では AccessKeyId が載りうる。
                // 統合ログ（log show / sysdiagnose）は第三者に渡りうるので必ずマスクを通す。
                let masked = masker.mask(String(describing: error))
                logger.error("自動マウントに失敗: \(masked, privacy: .public)")
            }
        }
    }

    func unmount(bucket: BucketConfig, profile: Profile) async {
        guard let client else { return }
        isBusy = true
        defer { isBusy = false }
        let controller = MountController(client: client)
        let resolved = bucket.resolvedMountPath()
        // 実際の操作には listmounts が返した mountPoint を使う（§6.2 RULE）
        let target = liveState.mount(for: resolved)?.mountPoint ?? resolved
        // §8.2: ユーザーがアプリからアンマウントした場合は再マウントせず、通知も出さない。
        // **`await` の前に記録する。** 後に置くと、`ensureUnmounted` の中断中に
        // ポーリング応答が着弾して「マウントが外れました」の誤通知が出る。
        // autoMount の値は変更しない（次回起動時は再びマウントされる）。
        manuallyUnmountedAliases.insert(bucket.alias)
        // 状態を変えるので、進行中のポーリング応答を陳腐化させる（§6.4）
        await poller?.invalidate()
        do {
            try await controller.ensureUnmounted(target)
            await poller?.refreshNow()
        } catch {
            // 失敗したら記録を戻す（アンマウントされていないので断の通知は出るべき）
            manuallyUnmountedAliases.remove(bucket.alias)
            presentErrorSync(error)
        }
    }

    func toggleMount(bucket: BucketConfig) async {
        guard let profile = activeProfile else { return }
        if liveState.isMounted(bucket.resolvedMountPath()) {
            await unmount(bucket: bucket, profile: profile)
        } else {
            await mount(bucket: bucket, profile: profile)
        }
    }

    /// §3.7 NOTE: `allowDirectWriteToPublic` の変更は**即座に該当バケットを再マウントして反映する**。
    /// 手動再マウントを待つ実装にしてはならない — 「設定したのに反映されていない」状態が生まれ、
    /// ユーザーが read-only だと誤認したまま書込みを試みることになる。
    func setAllowDirectWriteToPublic(_ allow: Bool) async {
        guard var profile = activeProfile, let client else { return }
        guard profile.advanced.allowDirectWriteToPublic != allow else { return }
        profile.advanced.allowDirectWriteToPublic = allow
        do {
            document = try profileStore.upsert(profile)
        } catch {
            presentErrorSync(error); return
        }
        let controller = MountController(client: client)
        for bucket in profile.buckets where bucket.visibility.isPublic {
            let resolved = bucket.resolvedMountPath()
            let target = liveState.mount(for: resolved)?.mountPoint ?? resolved
            // アンマウント → マウントの窓でポーリングが着弾すると誤通知が出るので、
            // その間だけ「意図的に外している」ものとして扱う
            manuallyUnmountedAliases.insert(bucket.alias)
            await poller?.invalidate()
            try? await controller.ensureUnmounted(target)
            await mount(bucket: bucket, profile: profile, announceErrors: false)
            manuallyUnmountedAliases.remove(bucket.alias)
        }
        updateReadOnlyWatchTargets(profile: profile)
        await poller?.refreshNow()
    }

    // MARK: - §8.2 マウント断への対応

    private func apply(_ state: LiveState) {
        let currentPaths = Set(state.mounts.map { canonical($0.mountPoint) })

        // Finder / コマンドで手動アンマウントされた → 自動再マウントせず通知する（§8.2）
        if let profile = activeProfile, startupFinished {
            var buckets: [String: String] = [:]
            for bucket in profile.buckets {
                buckets[bucket.alias] = canonical(bucket.resolvedMountPath())
            }
            for alias in LifecyclePolicy.mountsLost(previous: previouslyMountedPaths,
                                                    current: currentPaths,
                                                    buckets: buckets,
                                                    manuallyUnmounted: manuallyUnmountedAliases) {
                notifyMountLost(alias: alias)
            }
        }
        previouslyMountedPaths = currentPaths
        liveState = state
    }

    private func handleRcdRestarted(_ endpoint: RcEndpoint) async {
        // 再起動で rc-user / rc-pass が変わるので、マスカも作り直す（SEC-G04）
        if let profile = activeProfile,
           let credentials = try? profileStore.credentials(for: profile) {
            rebuildMasker(credentials: credentials, accountId: profile.accountId, endpoint: endpoint)
        }
        let client = RcClient(endpoint: endpoint)
        self.client = client
        self.shareService = ShareService(client: client, history: historyStore)
        // 古いポーリングを止めてから張り直す（止めないと積み上がる）
        await poller?.stop()
        poller = nil
        logWatcher?.stop()
        logWatcher = nil
        // rcd が作り直された時点でマウントは全部消えている。
        // 直前の一覧を残したままポーリングを再開すると、
        // 再マウントが終わる前の応答で**全バケットの断を誤通知する**。
        // §8.2 は rcd 死亡を「自動再起動 → 再マウント」と規定しており、通知する経路ではない。
        previouslyMountedPaths.removeAll()
        liveState = LiveState()
        guard let profile = activeProfile else { return }
        await restartPolling(profile: profile)
        // 再起動後は autoMount のバケットを再マウントする
        for bucket in profile.buckets where bucket.autoMount
            && !manuallyUnmountedAliases.contains(bucket.alias) {
            await mount(bucket: bucket, profile: profile, announceErrors: false)
        }
    }

    // MARK: - §8.3 終了シーケンス

    /// 未送信データを確認してから終了する。
    /// - Parameter isSystemLogout: OS の強制終了タイムアウトがあるため待機を 20 秒に短縮する
    func beginTermination(isSystemLogout: Bool) async {
        guard !isTerminating else { return }
        isTerminating = true
        systemLogoutInProgress = isSystemLogout

        // §8.3: **終了要求時にまず vfs/stats を確認する。**
        // ポーリングの値（最大 5 秒古い）で判定すると、保存直後に終了した場合に
        // 「未送信 0」と誤認してダイアログを出さずに rcd を殺す — まさに §8.3 が守ろうとした窓。
        if let client, let fresh = try? await client.vfsStats() {
            await poller?.applyFreshVfsStats(fresh)
        }

        switch LifecyclePolicy.terminationDecision(pendingUploads: liveState.pendingUploads) {
        case .askUser(let pending):
            // UI が「送信完了を待つ / そのまま終了」を尋ねる。ここでは即座に終了しない。
            pendingUploadsAtTermination = pending
            return
        case .proceed:
            await finishTermination()
        }
    }

    /// 「送信完了を待つ（推奨）」を選んだ場合。
    /// - Parameter limit: 上限。通常 5 分、ログアウト時は 20 秒（R-G10）
    func waitForUploadsThenTerminate(limit: TimeInterval? = nil) async {
        let effective = limit
            ?? LifecyclePolicy.uploadWaitLimit(isSystemLogout: systemLogoutInProgress)
        let deadline = Date().addingTimeInterval(effective)
        while Date() < deadline {
            if liveState.pendingUploads == 0 { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if liveState.pendingUploads > 0 {
            // 超過したら再度選択を求める
            pendingUploadsAtTermination = liveState.pendingUploads
            return
        }
        await finishTermination()
    }

    func terminateDiscardingUploads() async {
        await finishTermination()
    }

    private func finishTermination() async {
        pendingUploadsAtTermination = nil
        await poller?.stop()
        logWatcher?.stop()
        // §8.3: mount/unmountall → rcd に SIGTERM。
        // アプリ終了時は自分が起動した rcd であり認証情報を保持しているため RC API を呼べる
        // （孤児回収の §8.6.2 (b) とは事情が違う。混同しないこと）。
        if let client {
            let controller = MountController(client: client)
            try? await controller.unmountAll()
        }
        await supervisor?.stop()
        isReadyToTerminate = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func cancelTermination() {
        isTerminating = false
        pendingUploadsAtTermination = nil
        NSApp.reply(toApplicationShouldTerminate: false)
    }

    // MARK: - R-G08 プロファイル切替

    /// v1.0 では「アクティブなプロファイルは 1 つ」に限定する。
    /// 切替時はまず未送信データの判定を行い、その後に全アンマウント → rcd 再起動 → 再マウント。
    /// この判定を省くと、アプリ終了時と同じデータ喪失が切替経路で起きる。
    func switchProfile(to profileId: String) async -> Bool {
        guard profileId != document.activeProfileId else { return true }
        if case .blocked(let pending) =
            LifecyclePolicy.profileSwitchDecision(pendingUploads: liveState.pendingUploads) {
            toast = "未送信のファイルが \(pending) 件あります。送信が終わってから切り替えてください。"
            return false
        }
        isBusy = true
        defer { isBusy = false }
        if let client {
            let controller = MountController(client: client)
            try? await controller.unmountAll()
        }
        await poller?.stop()
        logWatcher?.stop()
        await supervisor?.stop()
        manuallyUnmountedAliases.removeAll()
        previouslyMountedPaths.removeAll()
        appliedRestartSignature = nil
        do {
            document = try profileStore.setActive(profileId: profileId)
            guard let profile = document.activeProfile else { return false }
            try await activate(profile: profile)
            return true
        } catch {
            presentErrorSync(error)
            return false
        }
    }

    // MARK: - §4.4 接続テスト

    @discardableResult
    func runConnectionTest(for profile: Profile) async -> ConnectionTest.Report? {
        guard let client else { return nil }
        isBusy = true
        defer { isBusy = false }
        let report = await ConnectionTest(client: client).run(profile: profile)
        connectionResults = report.results
        publicURLVerifiedAliases = report.publicURLVerifiedAliases
        return report
    }

    /// オンボーディング / 設定から呼ぶ。rcd が未起動なら先に起動する（§4.4 手順 1）。
    func prepareEngine(for profile: Profile, credentials: R2Credentials) async throws {
        guard let supervisor else { return }
        try paths.ensureDirectories(profileId: profile.id)
        masker = LogMasker(secrets: [credentials.accessKeyId, credentials.secretAccessKey],
                           accountIds: [profile.accountId])
        let rcloneURL = self.rcloneURL
        let paths = self.paths
        // 既に別プロファイルで動いていれば止めてから入れ替える（R-G08）
        await supervisor.stop()
        let makeSpec: @Sendable () -> RcdLaunchSpec = {
            RcdLaunchSpec(rcloneURL: rcloneURL, profile: profile,
                          credentials: credentials, paths: paths)
        }
        let endpoint = try await supervisor.start(specFactory: makeSpec)
        appliedRestartSignature = makeSpec().restartSignature
        rebuildMasker(credentials: credentials, accountId: profile.accountId, endpoint: endpoint)
        let client = RcClient(endpoint: endpoint)
        self.client = client
        self.shareService = ShareService(client: client, history: historyStore)
        mountTypes = (try? await client.mountTypes()) ?? []
    }

    func saveProfile(_ profile: Profile, credentials: R2Credentials?, makeActive: Bool) async {
        do {
            document = try profileStore.upsert(profile, credentials: credentials,
                                               makeActive: makeActive)
            let toastBefore = toast
            if makeActive || document.activeProfileId == profile.id {
                try await activate(profile: profile)
            }
            // `activate` が警告（未送信があるので接続設定を反映できない等）を出していたら、
            // それを「保存しました」で上書きしない — 上書きすると警告が一度も表示されない。
            if toast == toastBefore { toast = "設定を保存しました。" }
        } catch {
            presentErrorSync(error)
        }
    }

    func deleteProfile(_ profileId: String) async {
        do {
            let wasActive = document.activeProfileId == profileId
            document = try profileStore.delete(profileId: profileId)
            if wasActive {
                // §8.3 / R-G08 と同じ手順で畳む。畳み方が甘いと、
                // 止まった rcd のマウント一覧を UI が描画し続ける（§02 DESIGN INVARIANT 違反）。
                if let client {
                    try? await MountController(client: client).unmountAll(rcTimeout: 5)
                }
                await poller?.stop()
                poller = nil
                logWatcher?.stop()
                logWatcher = nil
                await supervisor?.stop()
                client = nil
                shareService = nil
                appliedRestartSignature = nil
                manuallyUnmountedAliases.removeAll()
                previouslyMountedPaths.removeAll()
                liveState = LiveState()
                publicURLVerifiedAliases.removeAll()
                connectionResults.removeAll()
                if let next = document.activeProfile {
                    try await activate(profile: next)
                }
            }
        } catch {
            presentErrorSync(error)
        }
    }

    // MARK: - §8.5 ログイン時起動

    /// U-14: `register()` が登録済みの状態で例外を投げるかは未検証。
    /// `status` を先に読み、望む状態と異なるときだけ呼ぶ（これなら冪等性は担保される）。
    var launchAtLoginEnabled: Bool { LaunchAtLoginPolicy.isEnabled }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLoginPolicy.apply(desired: enabled)
        } catch {
            toast = "ログイン項目の設定を変更できませんでした: \(error.localizedDescription)"
        }
    }

    // MARK: - §6.4 前景 / 背景の切り替え

    /// §6.4 の間隔表は前景と背景で値が違う。切り替えないと背景側の値が到達不能になる。
    func setForeground(_ foreground: Bool) async {
        await poller?.setForeground(foreground)
    }

    // MARK: - メニューバー

    var menuBarState: MenuBarState {
        let profile = activeProfile
        let expected = Set((profile?.buckets ?? [])
            .filter { $0.autoMount && !manuallyUnmountedAliases.contains($0.alias) }
            .map(\.alias))
        let actual = Set((profile?.buckets ?? [])
            .filter { liveState.isMounted($0.resolvedMountPath()) }
            .map(\.alias))
        return LifecyclePolicy.menuBarState(
            engineRunning: rcdStatus.isRunning,
            startupFinished: startupFinished,
            hasProfile: profile != nil,
            expectedMountedAliases: expected,
            actuallyMountedAliases: actual,
            isTransferring: liveState.isTransferring,
            transferSpeed: liveState.transferSpeed,
            pendingUploads: liveState.pendingUploads)
    }

    /// §5.5: 未送信キャッシュがあるときの再試行
    func retryPendingUploads() async {
        guard let client else { return }
        _ = try? await client.callRaw(RcPath.vfsRefresh)
        await poller?.refreshNow()
    }

    // MARK: - 診断

    func diagnosticsSnapshot() async -> DiagnosticsSnapshot {
        var snapshot = DiagnosticsSnapshot()
        let env = DiagnosticsCollector.environmentInfo()
        snapshot.osVersion = env.os
        snapshot.architecture = env.arch
        snapshot.appVersion = env.app
        snapshot.rcloneVersion = rcloneVersion
        snapshot.rcloneDistributionSHA256 = rcloneDistributionSHA256
        snapshot.rcloneEmbeddedSHA256 = rcloneEmbeddedSHA256
        snapshot.mountTypes = mountTypes
        snapshot.rcdStatus = rcdStatus
        snapshot.mounts = liveState.mounts
        snapshot.vfsStats = liveState.vfsStats
        snapshot.connectionResults = connectionResults
        snapshot.dsDontWriteNetworkStores = DiagnosticsCollector.readDSDontWriteNetworkStores()
        snapshot.keychainMode = KeychainStore().activeMode
        if let client {
            snapshot.configDumpIsEmpty = ((try? await client.configDump())?.isEmpty ?? true)
        }
        if let profile = activeProfile {
            snapshot.recentLog = DiagnosticsCollector.tailLog(
                at: paths.logFile(profileId: profile.id), masker: masker)
        }
        return snapshot
    }

    // MARK: - 補助

    private func updateReadOnlyWatchTargets(profile: Profile) {
        var targets: [String: String] = [:]
        for bucket in profile.buckets
        where bucket.isReadOnly(allowDirectWriteToPublic: profile.advanced.allowDirectWriteToPublic) {
            targets[bucket.alias] = bucket.resolvedMountPath()
        }
        logWatcher?.setReadOnlyMounts(targets)
    }

    private func handleReadOnlyDenial(_ detection: LogWatcher.Detection) {
        let alias = detection.matchedAlias ?? "公開バケット"
        currentError = ErrorCatalog.e14ReadOnlyWriteAttempt(alias: alias)
        notify(title: "公開バケットは読み取り専用です",
               body: "公開するには「共有…」をお使いください。")
    }

    private func notifyMountLost(alias: String) {
        notify(title: "\(alias) のマウントが外れました",
               body: "メニューバーから再マウントできます。")
    }

    private func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: UUID().uuidString,
                                                content: content, trigger: nil)
            center.add(request)
        }
    }

    func presentError(_ error: Error) async { presentErrorSync(error) }

    func presentErrorSync(_ error: Error) {
        let cataloged = ErrorCatalog.from(error)
        // 主文はアプリが組み立てた定型文だが、将来 detail を混ぜたときに漏れないよう
        // ここもマスクを通しておく（SEC-G04）
        let masked = masker.mask(cataloged.message)
        logger.error("\(cataloged.id, privacy: .public): \(masked, privacy: .public)")
        currentError = cataloged
    }

    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
