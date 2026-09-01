import AppKit
import os
import SkyFolderKit

/// §8.6.2 (c) / §8.3: 単一インスタンス化と終了フックを持つ。
final class AppDelegate: NSObject, NSApplicationDelegate {

    static let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "app")

    /// AppModel は SwiftUI 側が所有する。終了時の判定に使うため参照を預かる。
    ///
    /// **配線は `SkyFolderApp` の `MenuBarExtra` の label（常駐 UI）で行う。**
    /// ここが nil のままだと、下のハンドラが全部無言で素通りする。
    weak var model: AppModel?

    /// 配線されていれば返す。されていなければ**記録して気づけるようにする**。
    ///
    /// `guard let model else { return }` で黙って抜けると、終了ガードも前景/背景の切替も
    /// 「動いているつもり」で全滅する。**実際に一度そうなっていた**
    /// — 代入する箇所が存在せず、Cmd+Q のたびに §8.3 の終了シーケンスが丸ごと素通りし、
    /// rcd が生きたマウントを保持したまま孤児化していた（M-30）。
    /// `weak var` が nil でも guard は静かに通るので、**失敗の形が無言になる**のが厄介だった。
    private func requireModel(_ site: StaticString = #function) -> AppModel? {
        if let model { return model }
        Self.logger.fault(
            "AppModel が AppDelegate に配線されていない（\(String(describing: site), privacy: .public)）。§8.3 の終了ガードと §6.4 の前景/背景切替が働かない")
        assertionFailure("AppDelegate.model が未配線: \(site)")
        return nil
    }

    /// §8.6.2 (c): macOS は通常 .app の二重起動を防ぐが、
    /// ターミナルから実行ファイルを直接叩けば回避できる。
    /// 同一 bundle identifier の先行インスタンスを検出し、存在すればそれを前面に出して自分は終了する。
    func applicationWillFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: AppIdentity.bundleIdentifier)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let existing = others.first {
            Self.logger.notice("先行インスタンスを検出したため前面に出して終了する")
            existing.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
        }
    }

    /// §8.3: 未送信データの保護。
    ///
    /// DD-001 R-03 のとおり、VFS write-back により「保存済みに見えるがまだクラウドに無い」データが
    /// 常時存在しうる。終了時にこれを無視して rcd を殺すと、そのデータは失われる。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = requireModel() else { return .terminateNow }
        if model.isReadyToTerminate { return .terminateNow }
        Task { @MainActor in
            await model.beginTermination(isSystemLogout: false)
        }
        return .terminateLater
    }

    /// §8.3: **システムのログアウト・シャットダウン時も同じ判定を行う。**
    /// ただし OS の強制終了タイムアウトがあるため、待機は最大 20 秒に短縮する（R-G10）。
    ///
    /// これを購読しないと `isSystemLogout` が常に false になり、
    /// R-G10 の 20 秒短縮が到達不能なコードになる。
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let model = self?.requireModel() else { return }
            Task { @MainActor in
                await model.beginTermination(isSystemLogout: true)
            }
        }

        // §6.4: 前景 / 背景でポーリング間隔を切り替える
        // （アプリのアクティブ状態は NotificationCenter.default に流れる。NSWorkspace ではない）
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification,
                           object: nil, queue: .main) { [weak self] _ in
            guard let model = self?.requireModel() else { return }
            Task { @MainActor in await model.setForeground(true) }
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification,
                           object: nil, queue: .main) { [weak self] _ in
            guard let model = self?.requireModel() else { return }
            Task { @MainActor in await model.setForeground(false) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.logger.notice("アプリ終了")
    }

    /// ログイン項目から起動された場合はウィンドウを開かず、メニューバーのみで常駐する（§8.5）。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        true
    }
}
