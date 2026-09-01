import SwiftUI
import SkyFolderKit

/// §5.4 公開物一覧・取り下げ。DD-001 §8.1 の `r2share ls` / `r2share gone` に対応。
struct PublishedListView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedAlias = ""
    @State private var entries: [RcListEntry] = []
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var goneBytes: Int64 = 0
    @State private var stagingBytes: Int64 = 0
    @State private var confirmPurge = false

    private var buckets: [BucketConfig] {
        model.activeProfile?.buckets.filter { $0.visibility.isPublic } ?? []
    }
    private var bucket: BucketConfig? {
        buckets.first { $0.alias == selectedAlias } ?? buckets.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("公開物一覧").font(.headline)
                Spacer()
                if buckets.count > 1 {
                    Picker("", selection: $selectedAlias) {
                        ForEach(buckets) { Text($0.alias).tag($0.alias) }
                    }
                    .labelsHidden().frame(width: 160)
                }
                Button("閉じる") { dismiss() }
            }
            .padding(16)
            Divider()

            if isLoading { ProgressView().padding(24) }
            if let errorText { Text(errorText).foregroundStyle(.red).padding(16) }

            List(entries) { entry in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.path).font(.callout.monospaced())
                        HStack(spacing: 8) {
                            Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                            if let date = entry.modTime {
                                Text(date.formatted(date: .abbreviated, time: .shortened))
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("URL をコピー") { copyURL(entry) }.controlSize(.small)
                    Button("取り下げ") { Task { await takedown(entry) } }
                        .controlSize(.small)
                }
                .padding(.vertical, 3)
            }

            Divider()
            // R-G09 / SEC-07: gone/ と share-staging/ の合計サイズを常時表示する
            HStack(spacing: 14) {
                Text("gone/: \(ByteCountFormatter.string(fromByteCount: goneBytes, countStyle: .file))")
                Text("share-staging/: \(ByteCountFormatter.string(fromByteCount: stagingBytes, countStyle: .file))")
                if goneBytes > 1_073_741_824 {
                    Label("1GB を超えています", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(BrandColor.publicWarning)
                }
                Spacer()
                // §5.4 四半期棚卸し
                Button("gone/ を一括削除") { confirmPurge = true }
                    .controlSize(.small)
                    .disabled(goneBytes == 0)
            }
            .font(.caption)
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 720, height: 520)
        .task { await reload() }
        .onChange(of: selectedAlias) { Task { await reload() } }
        .confirmationDialog("gone/ の中身を完全に削除します。元に戻せません。",
                            isPresented: $confirmPurge, titleVisibility: .visible) {
            Button("削除する", role: .destructive) { Task { await purge() } }
            Button("キャンセル", role: .cancel) {}
        }
    }

    private func reload() async {
        guard let bucket, let service = model.shareService else { return }
        isLoading = true; errorText = nil
        defer { isLoading = false }
        if selectedAlias.isEmpty { selectedAlias = bucket.alias }
        do {
            entries = try await service.listObjects(bucketName: bucket.bucketName)
            let sizes = try await service.housekeepingSizes(bucketName: bucket.bucketName)
            goneBytes = sizes.gone
            stagingBytes = sizes.staging
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func copyURL(_ entry: RcListEntry) {
        guard let bucket else { return }
        let url = PublicKeyTemplate.publicURL(publicBaseURL: bucket.publicBaseURL, key: entry.path)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        model.toast = "URL をコピーしました。"
    }

    /// 削除ではなく `gone/` へサーバサイド移動する（DD-001 §4.4 RULE: 公開 URL の不変性）
    private func takedown(_ entry: RcListEntry) async {
        guard let bucket, let service = model.shareService else { return }
        do {
            _ = try await service.takedown(bucketName: bucket.bucketName, key: entry.path)
            model.toast = "取り下げました。CDN キャッシュが残るため即座には 404 になりません。"
            await reload()
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func purge() async {
        guard let bucket, let service = model.shareService else { return }
        do {
            let n = try await service.purgeGone(bucketName: bucket.bucketName)
            model.toast = "\(n) 件を削除しました。"
            await reload()
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
