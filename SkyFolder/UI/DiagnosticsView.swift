import SwiftUI
import SkyFolderKit

/// §10.2 診断画面。「何かおかしい」と感じたユーザーが最初に開く画面。
struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var snapshot = DiagnosticsSnapshot()
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("診断").font(.headline)
                Spacer()
                Button("再取得") { Task { await reload() } }
                Button("閉じる") { dismiss() }
            }
            .padding(16)
            Divider()

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        section("環境") {
                            row("macOS", snapshot.osVersion)
                            row("アーキテクチャ", snapshot.architecture)
                            row("アプリ", snapshot.appVersion)
                        }
                        section("同梱 rclone") {
                            row("バージョン", snapshot.rcloneVersion)
                            // SEC NOTE: docs/BUNDLED.md と照合するのは「配布物（署名前）」のほう。
                            // .app 内の実体は G0-3 で個別署名されるためハッシュが変わる（T-G30）。
                            row("SHA-256（配布物・BUNDLED.md と照合）",
                                snapshot.rcloneDistributionSHA256, monospaced: true)
                            row("SHA-256（署名後の実体・参考）",
                                snapshot.rcloneEmbeddedSHA256, monospaced: true)
                            row("mount/types", snapshot.mountTypes.joined(separator: ", "))
                            if !snapshot.mountTypes.contains("nfsmount") {
                                Label("nfsmount が使えません。マウント機能は無効です（E-03）。",
                                      systemImage: "xmark.circle.fill").foregroundStyle(.red)
                            }
                        }
                        section("rcd") {
                            row("状態", phaseText)
                            row("ポート", snapshot.rcdStatus.port.map(String.init) ?? "-")
                            row("PID", snapshot.rcdStatus.pid.map(String.init) ?? "-")
                            if let uptime = snapshot.rcdStatus.uptime {
                                row("稼働時間", "\(Int(uptime)) 秒")
                            }
                            row("再起動回数", String(snapshot.rcdStatus.restartCount))
                            // M-05: 環境変数由来のリモートは config/dump に現れない。これは異常ではない。
                            row("config/dump", snapshot.configDumpIsEmpty
                                ? "空（環境変数でリモートを定義しているため正常）" : "内容あり")
                        }
                        section("接続") {
                            if snapshot.connectionResults.isEmpty {
                                Text("まだ実行していません").foregroundStyle(.secondary)
                            }
                            ForEach(snapshot.connectionResults) { result in
                                HStack {
                                    Image(systemName: result.passed ? "checkmark.circle.fill"
                                                                    : "xmark.circle.fill")
                                        .foregroundStyle(result.passed ? .green : .red)
                                    Text(result.bucketAlias.map { "\(result.step.title)（\($0)）" }
                                         ?? result.step.title)
                                    Spacer()
                                    if let id = result.catalogID {
                                        Text(id).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Button("接続テストを再実行") {
                                Task {
                                    if let profile = model.activeProfile {
                                        await model.runConnectionTest(for: profile)
                                        await reload()
                                    }
                                }
                            }
                            .controlSize(.small)
                        }
                        section("マウント（mount/listmounts の生の応答）") {
                            if snapshot.mounts.isEmpty {
                                Text("0 件").foregroundStyle(.secondary)
                            }
                            ForEach(snapshot.mounts) { mount in
                                Text("\(mount.fs) → \(mount.mountPoint)")
                                    .font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                        section("VFS（vfs/stats の生の応答）") {
                            if let stats = snapshot.vfsStats?.diskCache {
                                row("未送信（queued）", String(stats.uploadsQueued))
                                row("送信中（inProgress）", String(stats.uploadsInProgress))
                                row("キャッシュ使用量",
                                    ByteCountFormatter.string(fromByteCount: stats.bytesUsed,
                                                              countStyle: .file))
                                row("ファイル数", String(stats.files))
                                row("エラー", String(stats.erroredFiles))
                                row("空き容量不足", stats.outOfSpace ? "はい" : "いいえ")
                            } else {
                                Text("未取得").foregroundStyle(.secondary)
                            }
                        }
                        section("認証情報の保護（SEC-G06）") {
                            switch snapshot.keychainMode {
                            case .dataProtection:
                                Label("data protection keychain を使用中。画面ロック中は読み取れません。",
                                      systemImage: "lock.shield")
                                    .foregroundStyle(.green)
                            case .legacy:
                                Label("login.keychain を使用中。**画面ロック中でも読み取れます。**",
                                      systemImage: "exclamationmark.shield")
                                    .foregroundStyle(BrandColor.publicWarning)
                                Text("data protection keychain には Team ID に紐づく entitlement が必要で、"
                                     + "ad-hoc 署名のビルドでは使えません。"
                                     + "Developer ID で署名したビルドでは自動的にそちらへ切り替わります。")
                                    .font(.caption).foregroundStyle(.secondary)
                            case .undetermined:
                                Text("まだ認証情報を保存していません").foregroundStyle(.secondary)
                            }
                        }

                        section("OS 設定") {
                            // §6.3 第 2 層: アプリが勝手に書き換えず、現在値を表示して明示操作で設定する
                            row("DSDontWriteNetworkStores",
                                snapshot.dsDontWriteNetworkStores.map { $0 ? "true" : "false" } ?? "未設定")
                            HStack {
                                Button("true に設定する") {
                                    _ = DiagnosticsCollector.writeDSDontWriteNetworkStores(true)
                                    Task { await reload() }
                                }
                                .controlSize(.small)
                                Text("反映にはログアウトが必要です")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text("ネットワークボリュームに .DS_Store を書かない設定です。マウント先に不要なファイルが残るのを防ぎます。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        section("ログ（直近 200 行・マスク済み）") {
                            // SEC-G04: secret・presigned URL は表示前にマスクする
                            ScrollView {
                                Text(snapshot.recentLog.joined(separator: "\n"))
                                    .font(.caption.monospaced())
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(height: 200)
                            .background(Color(nsColor: .textBackgroundColor),
                                        in: RoundedRectangle(cornerRadius: 6))
                            HStack {
                                Button("Finder で表示") {
                                    if let profile = model.activeProfile {
                                        NSWorkspace.shared.activateFileViewerSelecting(
                                            [model.paths.logFile(profileId: profile.id)])
                                    }
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                    .padding(18)
                }
            }
        }
        .frame(width: 760, height: 620)
        .task { await reload() }
    }

    private var phaseText: String {
        switch snapshot.rcdStatus.phase {
        case .running: return "稼働中"
        case .starting: return "起動中"
        case .stopped: return "停止"
        case .restarting(let n): return "再起動中（\(n)/5）"
        case .failed(let m): return "失敗: \(m)"
        }
    }

    private func reload() async {
        isLoading = true
        snapshot = await model.diagnosticsSnapshot()
        isLoading = false
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.bold())
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(monospaced ? .caption.monospaced() : .body)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }
}
