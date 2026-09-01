import SwiftUI
import SkyFolderKit

/// §5.5 メニューバー UI（常駐）。
///
/// A-06: アイコンは単色のテンプレート画像。青いタイルのアイコンはそのまま使えない
/// （メニューバーは明暗が反転するため）。5 つの状態はテンプレート画像 + バッジで表現する。
struct MenuBarLabel: View {
    let state: MenuBarState

    var body: some View {
        Image("MenuBarIcon")
            .renderingMode(.template)
            .overlay(alignment: .topTrailing) { badge }
    }

    @ViewBuilder
    private var badge: some View {
        switch state {
        case .normal:
            EmptyView()
        case .transferring:
            Circle().fill(BrandColor.brand).frame(width: 5, height: 5).offset(x: 2, y: -1)
        case .pendingUploads:
            Circle().fill(BrandColor.publicWarning).frame(width: 5, height: 5).offset(x: 2, y: -1)
        case .mountLost, .engineStopped:
            Circle().fill(Color.red).frame(width: 5, height: 5).offset(x: 2, y: -1)
        }
    }
}

struct MenuBarContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            statusLine

            Divider()

            if let profile = model.activeProfile {
                ForEach(profile.buckets) { bucket in
                    let mounted = model.liveState.isMounted(bucket.resolvedMountPath())
                    Button {
                        Task { await model.toggleMount(bucket: bucket) }
                    } label: {
                        Text("\(mounted ? "✓ " : "  ")\(bucket.alias)"
                             + (bucket.visibility.isPublic ? "（公開）" : ""))
                    }
                }

                Divider()

                Menu("Finder で開く") {
                    ForEach(profile.buckets) { bucket in
                        let mount = model.liveState.mount(for: bucket.resolvedMountPath())
                        Button(bucket.alias) {
                            // §6.2 RULE: 常に mountPoint（実際値）を使う
                            let path = mount?.mountPoint ?? bucket.resolvedMountPath()
                            NSWorkspace.shared.open(URL(fileURLWithPath: path))
                        }
                        .disabled(mount == nil)
                    }
                }
            }

            // §5.3 (b): メニューバーからの共有。ウィンドウを開くだけでは
            // ファイル選択に到達しないので、開く画面をモデル経由で伝える。
            Button("共有…") {
                model.sheetRequest = .share
                openWindow(id: "main")
            }
            Button("公開物一覧") {
                model.sheetRequest = .publishedList
                openWindow(id: "main")
            }

            if model.document.profiles.count > 1 {
                Menu("プロファイル") {
                    ForEach(model.document.profiles) { profile in
                        Button("\(profile.id == model.document.activeProfileId ? "✓ " : "  ")\(profile.displayName)") {
                            Task { _ = await model.switchProfile(to: profile.id) }
                        }
                    }
                }
            }

            Divider()

            SettingsLink { Text("設定…") }
            Button("診断…") {
                model.sheetRequest = .diagnostics
                openWindow(id: "main")
            }

            Divider()
            Button("SkyFolder を終了") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        Group {
            // §8.2「ネットワーク断」: マウントは維持したまま、状態だけを知らせる。
            // 断だからといってアンマウントはしない（そのほうが復帰時に何もしなくて済む）。
            if model.liveState.isOffline {
                Label("オフライン（接続を確認しています）", systemImage: "wifi.slash")
                    .foregroundStyle(BrandColor.publicWarning)
            }
            stateDescription
        }
    }

    @ViewBuilder
    private var stateDescription: some View {
        switch model.menuBarState {
        case .normal:
            Text("すべて正常")
        case .transferring(let speed, let remaining):
            Text("転送中 \(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file))/s"
                 + (remaining > 0 ? " · 残り \(remaining) 件" : ""))
        case .pendingUploads(let count):
            Text("\(count) 件がまだクラウドに送られていません")
            Button("再試行") { Task { await model.retryPendingUploads() } }
        case .mountLost(let alias):
            Text("\(alias) のマウントが外れました")
            Button("再マウント") {
                Task {
                    if let profile = model.activeProfile,
                       let bucket = profile.bucket(alias: alias) {
                        await model.mount(bucket: bucket, profile: profile)
                    }
                }
            }
        case .engineStopped:
            Text("内部エンジンが停止しています")
            Button("診断を開く") { openWindow(id: "main") }
        }
    }
}
