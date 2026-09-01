import SwiftUI
import SkyFolderKit
import UniformTypeIdentifiers

/// §5.3 共有ダイアログ。
///
/// **既定の選択は常に「期限付きリンク」**。恒久公開は明示的に選ばせる。
/// 誤操作 1 回で恒久公開が成立してはならない。
/// **前回の選択を記憶して既定にする実装をしてはならない**（SEC-G03 / CRIT-02 と同じ「危険側に倒さない」原則）。
struct ShareDialogView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let fileURLs: [URL]

    private enum Mode: Hashable { case temporary, permanent }
    @State private var mode: Mode = .temporary          // 既定は常に期限付き
    @State private var expire = "24h"
    @State private var prefix = ""
    @State private var stripMetadata = true
    @State private var immutableCache = false
    @State private var destinationAlias = ""
    @State private var stagingAlias = ""
    @State private var isWorking = false
    @State private var resultURL: String?
    @State private var overwriteKey: String?
    @State private var errorText: String?
    @State private var pickedURLs: [URL] = []

    private var files: [URL] { pickedURLs.isEmpty ? fileURLs : pickedURLs }
    private var file: URL? { files.first }

    private var profile: Profile? { model.activeProfile }

    private var resolver: ShareDestinationResolver {
        ShareDestinationResolver(publicURLVerifiedAliases: model.publicURLVerifiedAliases)
    }
    private var permanentDestinations: [BucketConfig] {
        profile.map { resolver.permanentDestinations(in: $0) } ?? []
    }
    private var stagingDestinations: [BucketConfig] {
        profile.map { resolver.stagingDestinations(in: $0) } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()

            if file == nil {
                emptyState
            } else {
                temporaryOption
                permanentOption
            }

            if let resultURL {
                VStack(alignment: .leading, spacing: 4) {
                    Text("URL をクリップボードにコピーしました").font(.callout.weight(.medium))
                    Text(resultURL).font(.caption.monospaced()).textSelection(.enabled)
                        .lineLimit(3)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            if let errorText {
                Text(errorText).font(.callout).foregroundStyle(.red)
            }

            Divider()
            footer
        }
        .padding(20)
        .frame(width: 560)
        .onAppear(perform: seedDefaults)
        .alert("すでに存在します", isPresented: Binding(get: { overwriteKey != nil },
                                              set: { if !$0 { overwriteKey = nil } })) {
            Button("キャンセル", role: .cancel) { overwriteKey = nil }
            Button("上書きする", role: .destructive) {
                let key = overwriteKey; overwriteKey = nil
                if key != nil { Task { await publish(confirmedOverwrite: true) } }
            }
        } message: {
            Text("\(overwriteKey ?? "") は既に公開されています。上書きすると内容が置き換わります。")
        }
    }

    private var header: some View {
        HStack {
            Text(file.map { "共有 — \($0.lastPathComponent)" } ?? "共有").font(.headline)
            Spacer()
            Button("ファイルを選ぶ…") { pickFiles() }.controlSize(.small)
        }
    }

    private var emptyState: some View {
        Text("共有するファイルを選んでください。メイン画面のバケット行にドラッグ&ドロップすることもできます。")
            .foregroundStyle(.secondary)
    }

    // MARK: - 期限付きリンク

    private var temporaryOption: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { mode == .temporary },
                                 set: { if $0 { mode = .temporary } })) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("期限付きリンク").bold()
                        Text("既定").font(.caption)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                    Text("非公開のまま・URL を知る人だけ・期限あり")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.radioGroup(disabled: stagingDestinations.isEmpty && !fileIsOnBucket))

            if mode == .temporary {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("有効期限")
                        Picker("", selection: $expire) {
                            ForEach(["1h", "6h", "24h", "3d", "7d"], id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().frame(width: 100)
                        Text("最大 7 日").font(.caption).foregroundStyle(.secondary)
                    }
                    if !stagingDestinations.isEmpty, stagingDestinations.count > 1 {
                        Picker("保存先", selection: $stagingAlias) {
                            ForEach(stagingDestinations) { Text($0.alias).tag($0.alias) }
                        }
                    }
                    if stagingDestinations.isEmpty {
                        Text("期限付き共有には非公開バケットが必要です。")
                            .font(.caption).foregroundStyle(.red)
                    }
                    if fileIsOnPublicBucket {
                        // §7.1 RULE: 公開バケット上のファイルは「期限付き」にならない
                        Label("このファイルは公開バケット上にあります。期限付きリンクを作っても、"
                              + "公開 URL からは誰でも恒久的にアクセスできます。",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(BrandColor.publicWarning)
                    }
                    // R-05 / D-04: ホストは {accountId}.r2.cloudflarestorage.com 固定
                    Text("→ https://{accountId}.r2.cloudflarestorage.com/… の形式になります（カスタムドメインは使えません）")
                        .font(.caption).foregroundStyle(.secondary)
                    // §7.2: 発行後の無効化は不可
                    Text("発行済みリンクの取り消しはできません。無効にするにはファイル名を変更してください。")
                        .font(.caption).foregroundStyle(.secondary)
                    // §7.2 メタデータ
                    Text("期限付きリンクでは画像のメタデータを除去しません（原本がそのまま渡ります）。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.leading, 22)
            }
        }
    }

    // MARK: - 恒久公開

    private var permanentOption: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { mode == .permanent },
                                 set: { if $0 { mode = .permanent } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("恒久公開").bold()
                    Text("公開バケットへ配置・誰でも常時アクセス可")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.radioGroup(disabled: permanentDestinations.isEmpty))

            if permanentDestinations.isEmpty {
                Text("公開 URL を発行するには、公開用ドメインの設定と接続テストの通過が必要です。")
                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 22)
            }

            if mode == .permanent, let bucket = selectedPermanentBucket, let file {
                VStack(alignment: .leading, spacing: 8) {
                    if permanentDestinations.count > 1 {
                        Picker("配置先バケット", selection: $destinationAlias) {
                            ForEach(permanentDestinations) { Text($0.alias).tag($0.alias) }
                        }
                    }
                    HStack {
                        Text("配置先")
                        TextField("assets", text: $prefix).frame(width: 120)
                    }
                    // slug プレビュー: 入力ファイル名から生成される最終 key を実行前に表示する
                    Text("→ \(previewURL(bucket: bucket, file: file))")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    if ImageMetadataStripper.isTargetFile(file) {
                        Toggle("画像のメタデータ（GPS 位置情報など）を除去する", isOn: $stripMetadata)
                        if !stripMetadata {
                            // SEC-G03: OFF にすると赤字の注意文が展開される。
                            // 「今後表示しない」の選択肢は存在しない。
                            Text("メタデータを除去せずに公開すると、撮影場所（GPS）・撮影日時・機材の情報が"
                                 + "URL を知る誰にでも読める状態になります。")
                                .font(.caption).foregroundStyle(.red)
                        }
                    }
                    Toggle("長期キャッシュを設定する（変更しないファイル向け）", isOn: $immutableCache)

                    // §5.3: 公開の警告文は毎回表示し、「今後表示しない」を提供しない
                    Label("恒久公開は URL を知る誰でもアクセスできます。取り消してもキャッシュや保存済みリンクからは"
                          + "即座に消えません。",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(BrandColor.publicWarning)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(BrandColor.publicWarning.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 6))
                }
                .padding(.leading, 22)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("閉じる") { dismiss() }
            Spacer()
            if isWorking { ProgressView().controlSize(.small) }
            Button(mode == .permanent ? "公開して URL をコピー" : "リンクを作成してコピー") {
                Task { mode == .permanent ? await publish(confirmedOverwrite: false) : await issueLink() }
            }
            // §8.6.1 MUST: 発行要求の in-flight 中はボタンを無効化し、
            // 1 回のユーザー操作から 1 本しか発行されないことを UI 側で保証する。
            .disabled(isWorking || file == nil || !canSubmit)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var canSubmit: Bool {
        mode == .permanent ? selectedPermanentBucket != nil
                           : (!stagingDestinations.isEmpty || fileIsOnBucket)
    }

    private var selectedPermanentBucket: BucketConfig? {
        permanentDestinations.first { $0.alias == destinationAlias } ?? permanentDestinations.first
    }
    private var selectedStagingBucket: BucketConfig? {
        stagingDestinations.first { $0.alias == stagingAlias } ?? stagingDestinations.first
    }

    /// 対象ファイルが公開バケットのマウント上にあるか（警告表示に使う）
    private var fileIsOnPublicBucket: Bool {
        guard let file, let profile else { return false }
        let path = file.standardizedFileURL.path
        return profile.buckets.contains { bucket in
            guard bucket.visibility.isPublic else { return false }
            let root = model.liveState.mount(for: bucket.resolvedMountPath())?.mountPoint
                ?? bucket.resolvedMountPath()
            return path.hasPrefix(URL(fileURLWithPath: root).standardizedFileURL.path + "/")
        }
    }

    /// §7.1: 対象ファイルがすでにいずれかのバケット上にある場合はコピーしない
    private var fileIsOnBucket: Bool { bucketContainingFile != nil }

    /// **非公開バケット上のファイルだけ**を対象にする（§7.1 RULE）。
    ///
    /// 公開バケット上のファイルに presigned URL を出すと、
    /// UI の「非公開のまま・URL を知る人だけ・期限あり」という説明が嘘になる
    /// — そのオブジェクトは `publicBaseURL` 経由で誰でも恒久的に取れる。
    /// ユーザーが「期限で消える」と誤認したまま機密ファイルを公開バケットに置き続ける導線になる。
    private var bucketContainingFile: (BucketConfig, String)? {
        guard let file, let profile else { return nil }
        let path = file.standardizedFileURL.path
        for bucket in profile.buckets where !bucket.visibility.isPublic {
            let root = model.liveState.mount(for: bucket.resolvedMountPath())?.mountPoint
                ?? bucket.resolvedMountPath()
            let canonicalRoot = URL(fileURLWithPath: root).standardizedFileURL.path
            if path.hasPrefix(canonicalRoot + "/") {
                return (bucket, String(path.dropFirst(canonicalRoot.count + 1)))
            }
        }
        return nil
    }

    // MARK: - アクション

    private func seedDefaults() {
        guard let profile else { return }
        expire = profile.share.defaultExpire
        prefix = profile.share.defaultPrefix
        stripMetadata = profile.share.stripImageMetadata
        immutableCache = profile.share.immutableCacheControl
        destinationAlias = permanentDestinations.first?.alias ?? ""
        stagingAlias = stagingDestinations.first?.alias ?? ""
        // mode は seed しない — 前回の選択を記憶して既定にしてはならない（§5.3）
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false      // §7.2: フォルダは共有できない
        panel.canChooseFiles = true
        if panel.runModal() == .OK { pickedURLs = panel.urls }
    }

    private func previewURL(bucket: BucketConfig, file: URL) -> String {
        guard let profile else { return "" }
        let key = PublicKeyTemplate.render(template: profile.share.publicKeyTemplate,
                                           prefix: prefix,
                                           fileName: file.lastPathComponent)
        return PublicKeyTemplate.publicURL(publicBaseURL: bucket.publicBaseURL, key: key)
    }

    private func issueLink() async {
        guard let file, let service = model.shareService else { return }
        isWorking = true; errorText = nil; resultURL = nil
        defer { isWorking = false }
        do {
            let link: ShareService.PresignedLink
            if let (bucket, key) = bucketContainingFile {
                link = try await service.issuePresignedLink(bucketName: bucket.bucketName,
                                                            key: key, expire: expire)
            } else if let staging = selectedStagingBucket {
                link = try await service.issuePresignedLinkForLocalFile(file,
                                                                        stagingBucket: staging,
                                                                        expire: expire)
            } else {
                errorText = ShareError.noPrivateDestination.errorDescription
                return
            }
            copy(link.url)
            resultURL = link.url
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func publish(confirmedOverwrite: Bool) async {
        guard let file, let profile, let service = model.shareService,
              let bucket = selectedPermanentBucket else { return }
        isWorking = true; errorText = nil; resultURL = nil
        defer { isWorking = false }
        var share = profile.share
        share.immutableCacheControl = immutableCache
        do {
            let result = try await service.publishPermanently(
                fileURL: file, bucket: bucket, share: share,
                prefixOverride: prefix, stripMetadata: stripMetadata,
                confirmedOverwrite: confirmedOverwrite)
            // G4 AC: URL のコピーはジョブの完了を待ってから行う
            //（まだ存在しないオブジェクトの URL を渡してしまうことを防ぐ）
            copy(result.url)
            resultURL = result.url
        } catch let error as ShareError {
            if case .overwriteConfirmationRequired(let key) = error {
                overwriteKey = key
            } else {
                errorText = error.errorDescription
            }
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// ラジオ風のトグル（無効化を扱えるようにする）
private struct RadioToggleStyle: ToggleStyle {
    let disabled: Bool
    func makeBody(configuration: Configuration) -> some View {
        Button {
            if !disabled { configuration.isOn = true }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: configuration.isOn ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(configuration.isOn ? BrandColor.brand : .secondary)
                configuration.label
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }
}

extension ToggleStyle where Self == RadioToggleStyle {
    static func radioGroup(disabled: Bool) -> RadioToggleStyle { RadioToggleStyle(disabled: disabled) }
}
