import SwiftUI
import SkyFolderKit

/// §15.2.2: 青 = プロダクトのアイデンティティ / オレンジ = 「公開」という危険側の警告。
/// **公開バケットの表示に青を使ってはならない** — 警告としての識別性が失われる。
enum BrandColor {
    static let brand = Color("BrandColor")
    static let publicWarning = Color("PublicWarningColor")
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showShareDialog = false
    @State private var shareTargets: [URL] = []
    @State private var showPublishedList = false
    @State private var showDiagnostics = false

    var body: some View {
        Group {
            if !model.startupFinished {
                ProgressView("起動しています…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.needsOnboarding {
                OnboardingView()
            } else {
                MainWindowView(onShare: { urls in
                    shareTargets = urls
                    showShareDialog = true
                },
                               onShowPublishedList: { showPublishedList = true },
                               onShowDiagnostics: { showDiagnostics = true })
            }
        }
        .task { await model.start() }
        // §5.3 (b) / §5.5: メニューバーからの画面要求を受け取る。
        // メニューバーは別シーンなので、この `@State` を直接は立てられない。
        // **`initial: true` が要る。** メニューバー常駐アプリはウィンドウを閉じた状態が通常で、
        // 「共有…」を押すと `openWindow` で RootView が**新規生成**される。
        // そのとき `sheetRequest` は「最初からある値」なので、initial なしでは onChange が発火せず
        // シートが開かない — §5.3 (b) の経路が、いちばん普通の使い方で成立しなくなる。
        .onChange(of: model.sheetRequest, initial: true) { _, request in
            guard let request else { return }
            switch request {
            case .share:
                // ファイルはダイアログ側の「選択…」で選ぶ（`pickFiles()`）。
                // Finder 経由の共有と違い、対象が未確定の状態で開く。
                shareTargets = []
                showShareDialog = true
            case .publishedList:
                showPublishedList = true
            case .diagnostics:
                showDiagnostics = true
            }
            model.sheetRequest = nil
        }
        .sheet(isPresented: $showShareDialog) {
            ShareDialogView(fileURLs: shareTargets)
                .environmentObject(model)
        }
        .sheet(isPresented: $showPublishedList) {
            PublishedListView().environmentObject(model)
        }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsView().environmentObject(model)
        }
        // 閉じられたときは **`cancelTermination()` を通す**。
        // 値だけ nil に戻すと `isTerminating` が true のまま残り、
        // `beginTermination` の guard に弾かれて**以後の Cmd+Q が全部無視される**。
        // ボタンで進んだ場合は先に値が nil になっているので、ここは Esc 等の dismiss だけが通る。
        .sheet(item: Binding(get: { model.pendingUploadsAtTermination.map { PendingCount(value: $0) } },
                             set: { if $0 == nil { model.cancelTermination() } })) { pending in
            TerminationGuardView(pending: pending.value)
                .environmentObject(model)
        }
        .alert(item: $model.currentError) { error in
            Alert(title: Text(error.message),
                  message: error.detail.map { Text($0) },
                  dismissButton: .default(Text("OK")))
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        model.toast = nil
                    }
            }
        }
        .animation(.default, value: model.toast)
    }
}

struct PendingCount: Identifiable { let value: Int; var id: Int { value } }

extension CatalogedError: @retroactive Identifiable {}

/// §8.3 CAUTION: 未送信データの保護。
/// 終了時にこれを無視して rcd を殺すと、そのデータは失われる。
struct TerminationGuardView: View {
    @EnvironmentObject private var model: AppModel
    let pending: Int
    @State private var waiting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("未送信のファイルが \(pending) 件あります", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(BrandColor.publicWarning)
            Text("保存済みに見えても、まだクラウドに送られていないファイルがあります。このまま終了すると失われる可能性があります。")
                .font(.callout).foregroundStyle(.secondary)
            if waiting {
                ProgressView("送信しています… 残り \(model.liveState.pendingUploads) 件")
            }
            HStack {
                Button("キャンセル") { model.cancelTermination() }
                Spacer()
                Button("そのまま終了") {
                    Task { await model.terminateDiscardingUploads() }
                }
                Button("送信完了を待つ") {
                    waiting = true
                    Task { await model.waitForUploadsThenTerminate() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
