import SwiftUI
import SkyFolderKit

@main
struct SkyFolderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    init() {
        // `--selftest` は署名済みの .app の中で前提を確かめるための経路。
        // Hardened Runtime は Xcode の実行やユニットテストのプロセスには掛からないため、
        // U-03 はここでしか確かめられない。
        let arguments = CommandLine.arguments
        if arguments.contains("--selftest") {
            Self.runCommandLine { rcloneURL in
                let results = await SelfTest.run(rcloneURL: rcloneURL)
                return (SelfTest.report(results), results.allSatisfy(\.passed))
            }
        }

        // G1-9: 実 R2 アカウントでの通し確認。認証情報は環境変数から受け取り、
        // ディスクにも引数にも置かない（SEC-G01 / SEC-G02）。
        if arguments.contains("--verify-r2") {
            guard let input = R2Verification.Input.fromEnvironment() else {
                FileHandle.standardError.write(Data((R2Verification.Input.usage + "\n").utf8))
                exit(2)
            }
            Self.runCommandLine { rcloneURL in
                guard let rcloneURL else { return ("同梱 rclone が見つかりません", false) }
                let checks = await R2Verification.run(input: input, rcloneURL: rcloneURL)
                return (R2Verification.report(checks), checks.allSatisfy(\.passed))
            }
        }
    }

    /// GUI を出さずにコマンドラインとして走らせる経路。実行後は必ず終了する。
    private static func runCommandLine(
        _ body: @escaping @Sendable (URL?) async -> (report: String, allPassed: Bool)
    ) -> Never {
        let rcloneURL = Bundle.main.url(forResource: "rclone", withExtension: nil)
        let semaphore = DispatchSemaphore(value: 0)
        let box = OutputBox()
        Task.detached {
            let result = await body(rcloneURL)
            box.store(result)
            semaphore.signal()
        }
        semaphore.wait()
        let result = box.value
        FileHandle.standardOutput.write(Data((result.report + "\n").utf8))
        exit(result.allPassed ? 0 : 1)
    }

    var body: some Scene {
        Window("SkyFolder", id: "main") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 720, minHeight: 480)
                // 配線は MenuBarExtra 側で必ず通るが、ウィンドウから起動した場合の保険。
                // 冪等なので二重に通っても問題ない。
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 820, height: 620)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        // §5.5 常駐 UI
        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(model)
        } label: {
            MenuBarLabelHost { appDelegate.model = model }
                .environmentObject(model)
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 640, height: 520)
        }
    }
}

/// `runCommandLine` の結果受け渡し（Task 境界を跨ぐため）
private final class OutputBox: @unchecked Sendable {
    private var stored: (report: String, allPassed: Bool) = ("", false)
    private let lock = NSLock()
    func store(_ value: (report: String, allPassed: Bool)) {
        lock.lock(); stored = value; lock.unlock()
    }
    var value: (report: String, allPassed: Bool) {
        lock.lock(); defer { lock.unlock() }; return stored
    }
}

/// メニューバーの label を包み、**常駐 UI でしか確実にできない 2 つのこと**を引き受ける。
///
/// 1. **`AppDelegate` への `AppModel` の配線**
///
///    `AppDelegate` は `applicationShouldTerminate` / `willPowerOff` / `didBecomeActive` の
///    各ハンドラで `guard let model else { return }` を通る。配線されていないと
///    **それらが全部無言で素通りし**、終了時の未送信ガードも `unmountAll` も
///    `supervisor.stop()` も R-G10 の記録も走らない — 通常終了のたびに rcd が孤児化する
///    （M-25 / CRIT-03）。実際にその状態だった（M-30）。
///
/// 2. **終了ガードのダイアログの提示先を確保する**
///
///    `TerminationGuardView` は `RootView` の `.sheet` でしか出ない。
///    ウィンドウを閉じたまま終了しようとすると提示先が無く、
///    `.terminateLater` への reply が永遠に来ずアプリが固まる。
///    ユーザーは強制終了するしかなく、そこで rcd が孤児化して R-G10 の記録も残らない。
///
/// **メニューバーの label に置く理由**: 常駐 UI なので起動直後に必ず評価され、
/// ウィンドウが閉じていても生きている。`Window` の `onAppear` はウィンドウを開かないと
/// 呼ばれず、このアプリはウィンドウを閉じたまま常駐するのが通常の使い方。
private struct MenuBarLabelHost: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    let wireUp: () -> Void

    var body: some View {
        MenuBarLabel(state: model.menuBarState)
            .onAppear(perform: wireUp)
            .onChange(of: model.pendingUploadsAtTermination) { _, pending in
                if pending != nil { openWindow(id: "main") }
            }
    }
}
