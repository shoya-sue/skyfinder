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
            MenuBarLabel(state: model.menuBarState)
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
