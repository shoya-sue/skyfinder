import SwiftUI
import SkyFolderKit

/// プロファイル設定・詳細設定・公開設定。
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            ProfileSettingsView().tabItem { Label("接続", systemImage: "link") }.tag(0)
            AdvancedSettingsView().tabItem { Label("詳細", systemImage: "slider.horizontal.3") }.tag(1)
            GeneralSettingsView().tabItem { Label("一般", systemImage: "gearshape") }.tag(2)
        }
    }
}

struct ProfileSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft: Profile?
    @State private var issues: [ValidationIssue] = []
    @State private var newSecret = ""
    @State private var newAccessKey = ""
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if var profile = draft {
                    LabeledField("表示名", text: Binding(get: { profile.displayName },
                                                     set: { profile.displayName = $0; draft = profile }),
                                 placeholder: "", issues: issues, field: "displayName")
                    LabeledField("Account ID", text: Binding(get: { profile.accountId },
                                                             set: { profile.accountId = $0; draft = profile }),
                                 placeholder: "", issues: issues, field: "accountId")

                    GroupBox("認証情報") {
                        VStack(alignment: .leading, spacing: 8) {
                            // V-09: 保存後は再表示せず「設定済み」とだけ表示する
                            HStack {
                                Text("Secret Access Key")
                                Spacer()
                                Text(model.profileStore.hasCredentials(for: profile) ? "設定済み" : "未設定")
                                    .foregroundStyle(.secondary)
                            }
                            if profile.credentialsAreStale() {
                                Label("登録から 1 年以上経過しています。トークンの再発行をご検討ください。",
                                      systemImage: "clock.badge.exclamationmark")
                                    .font(.caption).foregroundStyle(BrandColor.publicWarning)
                            }
                            TextField("新しい Access Key ID", text: $newAccessKey)
                            SecureField("新しい Secret Access Key", text: $newSecret)
                            Text("入力すると置き換えます。空のままなら現在の値を保持します。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(6)
                    }

                    ForEach(Array(profile.buckets.enumerated()), id: \.offset) { index, _ in
                        BucketEditor(bucket: Binding(
                            get: { profile.buckets[index] },
                            set: { profile.buckets[index] = $0; draft = profile }),
                                     profile: profile, issues: issues, index: index,
                                     onDelete: { profile.buckets.remove(at: index); draft = profile })
                    }

                    HStack {
                        Button("非公開バケットを追加") { addBucket(&profile, .privateBucket); draft = profile }
                        Button("公開バケットを追加") { addBucket(&profile, .publicBucket); draft = profile }
                    }

                    Divider()
                    HStack {
                        Button("接続テストを実行") {
                            Task { _ = await model.runConnectionTest(for: profile) }
                        }
                        Spacer()
                        Button("プロファイルを削除", role: .destructive) { confirmDelete = true }
                        Button("保存") { Task { await save(profile) } }
                            .keyboardShortcut(.defaultAction)
                            .disabled(ProfileValidator.hasBlockingErrors(issues))
                    }
                } else {
                    Text("プロファイルがありません。").foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .onAppear { draft = model.activeProfile }
        .onChange(of: model.document.activeProfileId) { draft = model.activeProfile }
        .confirmationDialog("このプロファイルと、保存された認証情報を削除します。",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("削除する", role: .destructive) {
                if let id = draft?.id { Task { await model.deleteProfile(id) } }
            }
            Button("キャンセル", role: .cancel) {}
        }
    }

    private func addBucket(_ profile: inout Profile, _ visibility: BucketVisibility) {
        let base = visibility.isPublic ? "public" : "private"
        var alias = base; var n = 2
        while profile.buckets.contains(where: { $0.alias == alias }) { alias = "\(base)-\(n)"; n += 1 }
        profile.buckets.append(BucketConfig(
            alias: alias, bucketName: "", visibility: visibility,
            mountPath: ProfileValidator.defaultMountPath(profile: profile, alias: alias)))
    }

    private func save(_ profile: Profile) async {
        var updated = profile
        updated.accountId = ProfileValidator.normalizeAccountId(profile.accountId)
        updated.buckets = profile.buckets.map { bucket in
            var b = bucket
            b.publicBaseURL = ProfileValidator.normalizePublicBaseURL(bucket.publicBaseURL)
            return b
        }
        let hasNewCredentials = !newSecret.isEmpty && !newAccessKey.isEmpty
        if hasNewCredentials { updated.credentialCreatedAt = Date() }

        issues = ProfileValidator.validate(
            updated, otherProfiles: model.document.profiles,
            secretProvided: hasNewCredentials || model.profileStore.hasCredentials(for: updated))
        guard !ProfileValidator.hasBlockingErrors(issues) else { return }

        await model.saveProfile(
            updated,
            credentials: hasNewCredentials
                ? R2Credentials(accessKeyId: newAccessKey.trimmingCharacters(in: .whitespaces),
                                secretAccessKey: newSecret)
                : nil,
            makeActive: false)
        newSecret = ""; newAccessKey = ""
        draft = model.activeProfile
    }
}

struct AdvancedSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft: Profile?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if var profile = draft {
                    GroupBox("公開バケットへの書き込み") {
                        VStack(alignment: .leading, spacing: 8) {
                            // G-08 / R-G01
                            Toggle("公開バケットに Finder から直接書き込めるようにする",
                                   isOn: Binding(
                                    get: { profile.advanced.allowDirectWriteToPublic },
                                    set: { value in
                                        profile.advanced.allowDirectWriteToPublic = value
                                        draft = profile
                                        // §3.7 NOTE: 変更は即座に再マウントして反映する
                                        Task { await model.setAllowDirectWriteToPublic(value) }
                                    }))
                            if profile.advanced.allowDirectWriteToPublic {
                                Label("Finder から直接置いたファイルは Exif（GPS 位置情報など）が除去されません。"
                                      + "公開は「共有…」から行うことを強く推奨します。",
                                      systemImage: "exclamationmark.triangle.fill")
                                    .font(.callout).foregroundStyle(.red)
                            } else {
                                Text("既定では公開バケットは読み取り専用でマウントされます。"
                                     + "公開は必ず共有ダイアログを通るため、メタデータ除去を迂回できません。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text("なお macOS の仕様上、読み取り専用でも Finder はドラッグを受け付けてから失敗します。"
                                 + "これは異常ではありません。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(6)
                    }

                    GroupBox("マウント") {
                        VStack(alignment: .leading, spacing: 8) {
                            // G-03 NOTE: 値の候補は mount/types の応答から動的に構成する
                            Picker("マウント方式", selection: Binding(
                                get: { profile.advanced.mountType },
                                set: { profile.advanced.mountType = $0; draft = profile })) {
                                ForEach(model.mountTypes.isEmpty ? ["nfsmount"] : model.mountTypes,
                                        id: \.self) { Text($0).tag($0) }
                            }
                            stepper("キャッシュ上限 (GB)", 5...50,
                                    Binding(get: { profile.advanced.vfsCacheMaxSizeGB },
                                            set: { profile.advanced.vfsCacheMaxSizeGB = $0; draft = profile }))
                            stepper("書き戻し間隔 (秒)", 5...60,
                                    Binding(get: { profile.advanced.vfsWriteBackSec },
                                            set: { profile.advanced.vfsWriteBackSec = $0; draft = profile }))
                            stepper("並列転送数", 4...16,
                                    Binding(get: { profile.advanced.transfers },
                                            set: { profile.advanced.transfers = $0; draft = profile }))
                            stepper("ディレクトリキャッシュ (秒)", 60...300,
                                    Binding(get: { profile.advanced.dirCacheTimeSec },
                                            set: { profile.advanced.dirCacheTimeSec = $0; draft = profile }))
                            // V-08 のツールチップ
                            Text("ディレクトリキャッシュを 60 秒より短くすると、R2 の Class A リクエストが増えて料金が上がります。")
                                .font(.caption).foregroundStyle(.secondary)
                            LabeledContent("キャッシュ方式") {
                                Text("full（変更不可）").foregroundStyle(.secondary)
                            }
                        }
                        .padding(6)
                    }

                    GroupBox("共有") {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("期限の既定値", selection: Binding(
                                get: { profile.share.defaultExpire },
                                set: { profile.share.defaultExpire = $0; draft = profile })) {
                                ForEach(["1h", "6h", "24h", "3d", "7d"], id: \.self) { Text($0).tag($0) }
                            }
                            TextField("公開先の既定 prefix", text: Binding(
                                get: { profile.share.defaultPrefix },
                                set: { profile.share.defaultPrefix = $0; draft = profile }))
                            // SEC-G03（MUST）: **永続的なオプトアウト設定を提供しない。**
                            // 以前ここに「除去する（既定値）」トグルを置いていたが、
                            // 値が profiles.json に永続化され、共有ダイアログの初期値として読まれるため、
                            // 一度 OFF にすると以後すべての公開が既定 OFF になっていた。
                            // それは SEC-G03 が名指しで禁じている構造なので、トグルごと削除した。
                            // OFF にできるのは共有ダイアログでの都度操作のみ。
                            Label("公開時の画像メタデータ除去は常に既定 ON です",
                                  systemImage: "checkmark.shield")
                                .font(.callout)
                            Text("GPS 位置情報などを残したまま公開する選択は、共有ダイアログで毎回行います。"
                                 + "設定として保存することはできません。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(6)
                    }

                    Button("保存") {
                        Task { await model.saveProfile(profile, credentials: nil, makeActive: false) }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
        .onAppear { draft = model.activeProfile }
        .onChange(of: model.document.activeProfileId) { draft = model.activeProfile }
    }

    private func stepper(_ title: String, _ range: ClosedRange<Int>,
                         _ value: Binding<Int>) -> some View {
        Stepper("\(title): \(value.wrappedValue)", value: value, in: range)
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var launchAtLogin = false

    var body: some View {
        Form {
            // §8.5: 既定 OFF。ユーザーは「システム設定 > 一般 > ログイン項目」から確認・無効化できる。
            Toggle("ログイン時に自動で起動する", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, value in model.setLaunchAtLogin(value) }
            Text("「システム設定 > 一般 > ログイン項目」から確認・無効化できます。")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            // SEC-06: 本アプリの機能範囲外。案内リンクにとどめる。
            VStack(alignment: .leading, spacing: 6) {
                Text("公開設定").font(.headline)
                Text("公開バケットのダウンロードが急増したときの通知は、Cloudflare のゾーン設定"
                     + "（Notifications: HTTP requests spike）で設定できます。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Cloudflare ダッシュボードを開く ↗") {
                    if let url = ErrorCatalog.cloudflareR2Dashboard { NSWorkspace.shared.open(url) }
                }
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = model.launchAtLoginEnabled }
    }
}
