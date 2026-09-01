import SwiftUI
import SkyFolderKit
import UniformTypeIdentifiers

/// §5.2 マウント管理（メイン画面）
struct MainWindowView: View {
    @EnvironmentObject private var model: AppModel
    let onShare: ([URL]) -> Void
    let onShowPublishedList: () -> Void
    let onShowDiagnostics: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 12) {
                    if let profile = model.activeProfile {
                        if profile.credentialsAreStale() {
                            // SEC-04: 365 日を超えたらローテーション推奨バナー
                            banner("この接続の認証情報は 1 年以上前に登録されました。R2 API トークンの再発行をご検討ください。",
                                   systemImage: "clock.badge.exclamationmark")
                        }
                        if profile.advanced.allowDirectWriteToPublic {
                            // R-G01: この設定を有効にした場合のみ、直置きによる Exif 未除去公開が起こりうる
                            banner("公開バケットへの直接書き込みが有効です。Finder から直接置いたファイルは Exif（GPS 等）が除去されません。",
                                   systemImage: "exclamationmark.triangle.fill", isDanger: true)
                        }
                        ForEach(profile.buckets) { bucket in
                            BucketRow(bucket: bucket, profile: profile, onShare: onShare)
                        }
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image("MenuBarIcon").renderingMode(.template).foregroundStyle(BrandColor.brand)
            Text("SkyFolder").font(.headline)
            if model.document.profiles.count > 1 {
                Picker("プロファイル", selection: Binding(
                    get: { model.document.activeProfileId },
                    set: { id in Task { _ = await model.switchProfile(to: id) } })) {
                    ForEach(model.document.profiles) { p in Text(p.displayName).tag(p.id) }
                }
                .labelsHidden().frame(maxWidth: 220)
            } else if let profile = model.activeProfile {
                Text(profile.displayName).foregroundStyle(.secondary)
            }
            Spacer()
            Button { onShowPublishedList() } label: { Image(systemName: "list.bullet.rectangle") }
                .help("公開物一覧")
                .disabled(publicBuckets.isEmpty)
            Button { onShowDiagnostics() } label: { Image(systemName: "stethoscope") }
                .help("診断")
            SettingsLink { Image(systemName: "gearshape") }
                .help("設定")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("rclone \(model.rcloneVersion)")
            Text("·")
            Group {
                switch model.rcdStatus.phase {
                case .running:
                    Text("rcd 稼働中 (127.0.0.1:\(model.rcdStatus.port.map(String.init) ?? "-"))")
                case .starting: Text("rcd 起動中…")
                case .restarting(let n): Text("rcd 再起動中 (\(n)/5)")
                case .stopped: Text("rcd 停止")
                case .failed(let m): Text("rcd エラー: \(m)").foregroundStyle(.red)
                }
            }
            Text("·")
            Text(model.activeProfile?.advanced.mountType ?? "-")
            Spacer()
            if model.isBusy { ProgressView().controlSize(.small) }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var publicBuckets: [BucketConfig] {
        model.activeProfile?.buckets.filter { $0.visibility.isPublic } ?? []
    }

    private func banner(_ text: String, systemImage: String, isDanger: Bool = false) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((isDanger ? Color.red : BrandColor.publicWarning).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(isDanger ? Color.red : BrandColor.publicWarning)
    }
}

/// §5.2: バケット 1 行
struct BucketRow: View {
    @EnvironmentObject private var model: AppModel
    let bucket: BucketConfig
    let profile: Profile
    let onShare: ([URL]) -> Void

    @State private var isTargeted = false

    private var resolved: String { bucket.resolvedMountPath() }
    private var mount: RcMountPoint? { model.liveState.mount(for: resolved) }
    private var isMounted: Bool { mount != nil }
    private var isReadOnly: Bool {
        bucket.isReadOnly(allowDirectWriteToPublic: profile.advanced.allowDirectWriteToPublic)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // 公開バケットの視覚的分離: 左端にオレンジの帯を常時表示（§5.2）
            Rectangle()
                .fill(bucket.visibility.isPublic ? BrandColor.publicWarning : Color.clear)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle().fill(indicatorColor).frame(width: 9, height: 9)
                    Text(bucket.alias).font(.headline)
                    Text(bucket.bucketName).foregroundStyle(.secondary)
                    if bucket.visibility.isPublic {
                        Text("公開")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(BrandColor.publicWarning.opacity(0.18), in: Capsule())
                            .foregroundStyle(BrandColor.publicWarning)
                        if !bucket.publicBaseURL.isEmpty {
                            Text(bucket.publicBaseURL
                                .replacingOccurrences(of: "https://", with: ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !model.publicURLVerifiedAliases.contains(bucket.alias) {
                            // §7.1 RULE: 手順 5 未通過は恒久公開の解決対象から除外される
                            Text("公開 URL 未確認")
                                .font(.caption)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                        }
                    } else {
                        Text("非公開").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                Text(resolved).font(.caption).foregroundStyle(.secondary)
                // §6.2 RULE: mountPath（設定値）と mountPoint（実際値）が乖離したら併記する
                if let actual = mount?.mountPoint, canonical(actual) != canonical(resolved) {
                    Text("実際: \(actual)").font(.caption).foregroundStyle(.orange)
                }

                if bucket.visibility.isPublic {
                    Label("このバケットの中身は URL を知る誰でも読めます",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(BrandColor.publicWarning)
                }

                HStack(spacing: 10) {
                    Text(statusText).font(.caption)
                    if isReadOnly, isMounted {
                        Text("読み取り専用")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }

                if bucket.visibility.isPublic, isReadOnly {
                    Text("公開するには「共有…」を使ってください")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack {
                    Button("Finder で開く") {
                        // §6.2 RULE: 「Finder で開く」には常に mountPoint（実際値）を使う
                        let path = mount?.mountPoint ?? resolved
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    }
                    .disabled(!isMounted)

                    Button(isMounted ? "アンマウント" : "マウント") {
                        Task { await model.toggleMount(bucket: bucket) }
                    }
                    .disabled(model.mountTypes.isEmpty)

                    Button("共有…") { onShare([]) }
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
            .padding(12)
        }
        .background(isTargeted ? BrandColor.brand.opacity(0.10) : Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.18)))
        // §5.3 (a): メイン画面のバケット行へのドラッグ&ドロップ
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier)
                        as? Data, let resolved = URL(dataRepresentation: url, relativeTo: nil) {
                        urls.append(resolved)
                    }
                }
                if !urls.isEmpty { onShare(urls) }
            }
            return true
        }
    }

    private var indicatorColor: Color {
        // ● の色: 緑 = マウント済み / 灰 = 未マウント / 黄 = 処理中 / 赤 = エラー
        if model.isBusy { return .yellow }
        if case .failed = model.rcdStatus.phase { return .red }
        return isMounted ? .green : .gray
    }

    private var statusText: String {
        guard isMounted else { return "未マウント" }
        var parts = ["マウント済み"]
        let bytes = model.liveState.vfsStats?.cacheBytesUsed ?? 0
        if bytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + " キャッシュ")
        }
        let pending = model.liveState.pendingUploads
        parts.append("未送信 \(pending) 件")
        let errored = model.liveState.erroredFiles
        if errored > 0 { parts.append("⚠︎ 送信失敗 \(errored) 件") }
        return parts.joined(separator: " · ")
    }

    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
