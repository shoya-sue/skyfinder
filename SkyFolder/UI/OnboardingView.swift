import SwiftUI
import SkyFolderKit

/// §5.1 初回セットアップ（オンボーディング）。4 ステップのウィザード。
/// 各ステップは「Cloudflare ダッシュボードで何をするか」を具体的に指示する。
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel

    @State private var step = 1
    @State private var displayName = ""
    @State private var accountId = ""
    @State private var accessKeyId = ""
    @State private var secretAccessKey = ""
    @State private var buckets: [BucketConfig] = []
    @State private var issues: [ValidationIssue] = []
    @State private var report: ConnectionTest.Report?
    @State private var testing = false
    @State private var draftId = ULID.generate()

    private var draftProfile: Profile {
        Profile(id: draftId,
                displayName: displayName.isEmpty ? "R2" : displayName,
                accountId: ProfileValidator.normalizeAccountId(accountId),
                buckets: buckets,
                credentialCreatedAt: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepIndicator
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch step {
                    case 1: stepAccount
                    case 2: stepToken
                    case 3: stepBuckets
                    default: stepVerify
                    }
                }
                .padding(24)
            }
            Divider()
            footer
        }
    }

    private var stepIndicator: some View {
        HStack(spacing: 14) {
            Image("Logo").resizable().scaledToFit().frame(height: 26)
            Spacer()
            ForEach(1...4, id: \.self) { i in
                HStack(spacing: 6) {
                    Circle()
                        .fill(i <= step ? BrandColor.brand : Color.secondary.opacity(0.3))
                        .frame(width: 9, height: 9)
                    Text(["アカウント", "トークン", "バケット", "確認"][i - 1])
                        .font(.caption)
                        .foregroundStyle(i == step ? .primary : .secondary)
                }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
    }

    // MARK: - 1/4

    private var stepAccount: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cloudflare アカウント").font(.title3.bold())
            Text("Cloudflare ダッシュボードの R2 画面、右サイドに表示されている 32 桁の Account ID をコピーしてください。")
                .foregroundStyle(.secondary)
            LabeledField("この接続の名前", text: $displayName,
                         placeholder: "例: 仕事用", issues: issues, field: "displayName")
            LabeledField("Account ID", text: $accountId,
                         placeholder: "0123abcd…（32 桁）", issues: issues, field: "accountId")
            Button("ダッシュボードを開く ↗") {
                if let url = ErrorCatalog.cloudflareR2Dashboard { NSWorkspace.shared.open(url) }
            }
            // SEC-09: nfsmount の localhost NFS は認証なしで待ち受ける
            noteBox("このアプリは自分専用の Mac で使ってください。共有 Mac やゲストアカウントが有効な環境では、"
                    + "同じ Mac の他の利用者からマウント内容が見えることがあります。")
        }
    }

    // MARK: - 2/4

    private var stepToken: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("R2 API トークン").font(.title3.bold())
            Text("Cloudflare ダッシュボード → R2 → Manage R2 API Tokens → Create API token で、"
                 + "以下の設定のトークンを作成してください。")
                .foregroundStyle(.secondary)
            // SEC-01: 必要権限を画面上に明示し、Admin トークンの入力を推奨しない旨を表示する
            VStack(alignment: .leading, spacing: 6) {
                row("Permissions", "Object Read & Write")
                row("Specify bucket(s)", "使用するバケットのみを指定")
                Label("Admin 権限のトークンは使用しないでください", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(BrandColor.publicWarning)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

            Button("ダッシュボードを開く ↗") {
                if let url = ErrorCatalog.cloudflareR2Dashboard { NSWorkspace.shared.open(url) }
            }
            LabeledField("Access Key ID", text: $accessKeyId, placeholder: "",
                         issues: issues, field: "accessKeyId")
            VStack(alignment: .leading, spacing: 4) {
                Text("Secret Access Key").font(.callout)
                // V-09: 入力欄はマスク表示・コピー不可
                SecureField("", text: $secretAccessKey)
                    .textFieldStyle(.roundedBorder)
                inlineIssues(field: "secretAccessKey")
                Text("Keychain に保存されます。設定ファイルには書かれません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 3/4

    private var stepBuckets: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("バケットの登録").font(.title3.bold())
            Text("R2 上の既存バケットを登録します。バケットの作成は Cloudflare ダッシュボードで行ってください。")
                .foregroundStyle(.secondary)

            ForEach(Array(buckets.enumerated()), id: \.offset) { index, _ in
                BucketEditor(bucket: Binding(
                    get: { buckets[index] },
                    set: { buckets[index] = $0 }),
                             profile: draftProfile,
                             issues: issues, index: index,
                             onDelete: { buckets.remove(at: index) })
            }

            HStack {
                Button("非公開バケットを追加") { addBucket(.privateBucket) }
                Button("公開バケットを追加") { addBucket(.publicBucket) }
            }
            inlineIssues(field: "buckets")
        }
    }

    private func addBucket(_ visibility: BucketVisibility) {
        let alias = visibility.isPublic ? "public" : "private"
        var unique = alias
        var n = 2
        while buckets.contains(where: { $0.alias == unique }) { unique = "\(alias)-\(n)"; n += 1 }
        buckets.append(BucketConfig(
            alias: unique, bucketName: "", visibility: visibility,
            mountPath: ProfileValidator.defaultMountPath(profile: draftProfile, alias: unique)))
    }

    // MARK: - 4/4

    private var stepVerify: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("接続テスト").font(.title3.bold())
            Text("入力した内容で実際に R2 へ接続します。全項目が通過すると設定を保存できます。")
                .foregroundStyle(.secondary)

            if testing { ProgressView("テストしています…") }

            if let report {
                ForEach(report.results) { result in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: result.passed ? "checkmark.circle.fill"
                                                        : (result.isBlocking ? "xmark.circle.fill"
                                                                             : "exclamationmark.triangle.fill"))
                            .foregroundStyle(result.passed ? .green
                                             : (result.isBlocking ? .red : BrandColor.publicWarning))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.bucketAlias.map { "\(result.step.title)（\($0)）" }
                                 ?? result.step.title)
                                .font(.callout.weight(.medium))
                            Text(result.message).font(.caption).foregroundStyle(.secondary)
                            if let id = result.catalogID {
                                Text(id).font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                    }
                }
                if !report.allPassed, report.canSave {
                    noteBox("公開 URL の確認だけが通っていません。マウントは使えますが、恒久公開の機能は無効のままになります。")
                }
            }

            Button(testing ? "テスト中…" : "接続テストを実行") { Task { await runTest() } }
                .disabled(testing)
        }
    }

    // MARK: - footer

    private var footer: some View {
        HStack {
            if step > 1 { Button("戻る") { step -= 1 } }
            Spacer()
            if step < 4 {
                Button("次へ →") { advance() }.keyboardShortcut(.defaultAction)
            } else {
                Button("完了") { Task { await finish() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(report?.canSave != true)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
    }

    private func advance() {
        issues = ProfileValidator.validate(draftProfile,
                                           otherProfiles: model.document.profiles,
                                           secretProvided: !secretAccessKey.isEmpty)
        let relevant: (ValidationIssue) -> Bool = { issue in
            switch step {
            case 1: return ["displayName", "accountId"].contains(issue.field)
            case 2: return ["accessKeyId", "secretAccessKey"].contains(issue.field)
            case 3: return issue.field.hasPrefix("buckets")
            default: return false
            }
        }
        let blocking = issues.filter { $0.severity == .error && relevant($0) }
        if step == 2, accessKeyId.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(.init(rule: "V-09", field: "accessKeyId",
                                message: "Access Key ID を入力してください。"))
            return
        }
        guard blocking.isEmpty else { return }
        step += 1
        if step == 4 { Task { await runTest() } }
    }

    private func runTest() async {
        testing = true
        defer { testing = false }
        let profile = draftProfile
        do {
            try await model.prepareEngine(
                for: profile,
                credentials: R2Credentials(accessKeyId: accessKeyId.trimmingCharacters(in: .whitespaces),
                                           secretAccessKey: secretAccessKey))
        } catch {
            model.presentErrorSync(error)
            return
        }
        report = await model.runConnectionTest(for: profile)
    }

    private func finish() async {
        await model.saveProfile(draftProfile,
                                credentials: R2Credentials(
                                    accessKeyId: accessKeyId.trimmingCharacters(in: .whitespaces),
                                    secretAccessKey: secretAccessKey),
                                makeActive: true)
        // §8.5: オンボーディング完了時に 1 回だけ尋ねる（既定 OFF）
    }

    // MARK: - 部品

    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).bold() }
    }

    private func noteBox(_ text: String) -> some View {
        Text(text).font(.callout)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func inlineIssues(field: String) -> some View {
        // §4.3: エラーは該当フィールド直下にインライン表示する（ダイアログにしない）
        ForEach(issues.filter { $0.field == field }) { issue in
            Text(issue.message)
                .font(.caption)
                .foregroundStyle(issue.severity == .error ? Color.red : BrandColor.publicWarning)
        }
    }
}

struct LabeledField: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    let issues: [ValidationIssue]
    let field: String

    init(_ title: String, text: Binding<String>, placeholder: String,
         issues: [ValidationIssue], field: String) {
        self.title = title
        self._text = text
        self.placeholder = placeholder
        self.issues = issues
        self.field = field
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout)
            TextField(placeholder, text: $text).textFieldStyle(.roundedBorder)
            ForEach(issues.filter { $0.field == field }) { issue in
                Text(issue.message).font(.caption)
                    .foregroundStyle(issue.severity == .error ? Color.red : BrandColor.publicWarning)
            }
        }
    }
}

struct BucketEditor: View {
    @Binding var bucket: BucketConfig
    let profile: Profile
    let issues: [ValidationIssue]
    let index: Int
    let onDelete: () -> Void

    private func field(_ name: String) -> String { "buckets[\(index)].\(name)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(bucket.visibility.isPublic ? "公開バケット" : "非公開バケット")
                    .font(.headline)
                    .foregroundStyle(bucket.visibility.isPublic ? BrandColor.publicWarning : .primary)
                Spacer()
                Button(role: .destructive) { onDelete() } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            if bucket.visibility.isPublic {
                Label("このバケットに置いたものは URL を知る誰でも読めます",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(BrandColor.publicWarning)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(BrandColor.publicWarning.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 6))
            }
            LabeledField("バケット名（R2 上の実名）", text: $bucket.bucketName,
                         placeholder: "flab-stor-private", issues: issues, field: field("bucketName"))
            LabeledField("別名（マウント先の名前）", text: $bucket.alias,
                         placeholder: "private", issues: issues, field: field("alias"))
            LabeledField("マウント先", text: $bucket.mountPath,
                         placeholder: "~/SkyFolder/…", issues: issues, field: field("mountPath"))
            if bucket.visibility.isPublic {
                LabeledField("公開用ドメイン", text: $bucket.publicBaseURL,
                             placeholder: "https://files.example.com",
                             issues: issues, field: field("publicBaseURL"))
                Text("このドメインは Cloudflare ダッシュボードで対象バケットに接続済みである必要があります。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Custom Domains の設定を開く ↗") {
                    if let url = ErrorCatalog.cloudflareR2Dashboard { NSWorkspace.shared.open(url) }
                }
                .controlSize(.small)
            }
            Toggle("起動時に自動マウントする", isOn: $bucket.autoMount)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.18)))
    }
}
