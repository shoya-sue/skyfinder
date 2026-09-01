# SkyFolder

Cloudflare R2 を macOS Finder にマウントし、URL ベースで共有する macOS ネイティブアプリ。

接続情報をアプリ画面に入力するだけで任意の R2 バケットが Finder のドライブになり、
マウント済みファイルから恒久公開 URL・期限付き共有 URL をワンクリックで発行できる。
**ターミナル操作は要らない。**

> **リポジトリ名は `r2-finder-mount-tool` → `skyfinder` に改名済み（2026-09-01）。bundle identifier `dev.fracturelab.skyfolder` は変更していません。**
> 変更すると Keychain のアクセス権とログイン項目の登録が切れ、ユーザーが Secret の再入力を強いられます。
> **ソースコード内でリポジトリ名を参照しないでください。**（設計書 §15.1）

## つくり

| | |
|---|---|
| UI | SwiftUI（MenuBarExtra 常駐 + ウィンドウ）/ macOS 14+ / Apple Silicon |
| バックエンド | 同梱した `rclone rcd` を HTTP RC API で制御（プロセスは常に 1 本） |
| マウント | `nfsmount`（macOS 内蔵 NFS クライアント・**kext もドライバも要らない**） |
| 認証情報 | Keychain に保存し、rcd へは環境変数で注入。**設定ファイルを一切生成しない** |
| 配布 | Developer ID 署名 + notarization の `.app`。App Sandbox は無効なので **MAS 配布は構造的に不可能** |

## サイト

**<https://skyfolder.fracturelab.dev/>** — 機能・しくみ・制約・FAQ をまとめてあります。

## インストール（Release からダウンロードする場合）

1. [Releases](https://github.com/shoya-sue/skyfinder/releases) から `SkyFolder.dmg` をダウンロード
2. DMG を開き、`SkyFolder.app` を `Applications` へドラッグ
3. **初回だけ、macOS の警告を手動で越える必要があります**（下記）
4. 起動するとオンボーディングが開くので、R2 の接続情報を入力

### 初回起動時の警告について

**現在の配布物は ad-hoc 署名で、Apple の公証（notarization）を受けていません。**
そのため Gatekeeper はこのアプリを拒否します（実測: `spctl -a -t execute` → `rejected`）。
ダウンロードしたファイルには quarantine 属性が付くため、**初回はダブルクリックでは開きません。**

開くには:

1. `Applications` の `SkyFolder.app` をダブルクリック → 「開発元を確認できません」→ **そのまま閉じる**
2. **システム設定 → プライバシーとセキュリティ** を開く
3. 下の方に出る「"SkyFolder" は開発元を確認できないため、使用がブロックされました」の横の **「このまま開く」**
4. 確認ダイアログで **「開く」**

一度許可すれば以降は普通に起動します。

> **バンドル自体は壊れていません**（`codesign -v --deep --strict` は通ります）。
> 拒否されるのは Developer ID 証明書と公証チケットが無いためだけです。
> **Apple Developer Program（有料）に加入して署名・公証すれば、この手順は不要になります。**
> 設計書はそれを G5 として定義しており、`docs/STATUS.md` §4-3 に手順があります。

> 上の手順 2〜4 は macOS 26 の画面名です。**GUI の実挙動は未検証**（この環境では
> Gatekeeper の判定結果までしか自動で確かめられないため）。手順が違ったら issue にしてください。

## 使いかた（開発）

```bash
./scripts/build.sh release     # 同梱 rclone 取得 → アセット生成 → ビルド → 署名 → 自己診断
./scripts/test.sh              # 全テスト（176 件・約 95 秒）
./scripts/build.sh release dmg # DMG まで作る
```

初回は `xcodegen` が要ります（`brew install xcodegen`）。

### 実 R2 アカウントでの通し確認

設計書 §11 が「省略して先へ進んではならない」としている G1-9 を 1 コマンドで実行できます。

```bash
SKYFOLDER_ACCOUNT_ID=...         \
SKYFOLDER_ACCESS_KEY_ID=...      \
SKYFOLDER_SECRET_ACCESS_KEY=...  \
SKYFOLDER_PRIVATE_BUCKET=...     \
./scripts/verify-r2.sh
```

SigV4 の成立・presigned の実発行と失効・`Cache-Control` の実付与・未送信件数の遷移・
`deletefile` の冪等性を確認します。テスト用オブジェクトは `.skyfolder-probe-*` で作り、実行後に削除します。
秘密情報は環境変数からのみ受け取り、ディスクにも引数にも置きません。

## リポジトリ構成

```
project.yml                  XcodeGen の定義。.xcodeproj は生成物で、唯一の正はこちら
scripts/
  fetch-rclone.sh            同梱 rclone を SHA-256 検証つきで取得（冪等）
  make-assets.swift / .sh    docs/design/ の原本 → Assets.xcassets（描画領域は自動検出）
  build.sh / test.sh         ビルド / テスト
  verify-r2.sh               G1-9 実アカウント検証
SkyFolder/
  Core/                      UI を含まない中核。静的ライブラリなのでホストアプリなしで単体テストできる
    Model/                   識別子・パス・プロファイルのスキーマ
    Store/                   profiles.json（原子的置換）と Keychain
    Validation/              §4.3 の V-01〜V-12 と slug 規則
    Rcd/                     rcd の起動・監視・回収と RC API クライアント
    Mount/                   マウント制御・OS のマウント表・vfsOpt の組み立て
    Share/                   presigned・恒久公開・Exif 除去・取り下げ
    Stats/                   ポーリング（応答の陳腐化を判定して破棄する）
    Diag/                    エラーカタログ・ログマスク・診断・自己診断・G1-9
  App/                       SwiftUI エントリとライフサイクル
  UI/                        オンボーディング / メイン / 共有 / 公開物一覧 / 診断 / 設定 / メニューバー
  Resources/                 Info.plist・entitlements・同梱 rclone
Tests/SkyFolderKitTests/     176 件（うち rcd 統合 30 — 実際に rclone を起動し NFS マウントする）
docs/                        設計資料。着手前に docs/README.md を読むこと
```

生成物（`.xcodeproj` / `Assets.xcassets` / 同梱 rclone）はコミットしません。
原本とスクリプトから何度でも同じものを作れることが要件です（設計書 §8.6 / §15.3）。

## 設計上、知っておくべきこと

- **公開バケットは read-only でマウントされる。** Finder から直接置けないので、公開は必ず共有ダイアログを通り、
  Exif 除去・slug 化・上書き確認を迂回できない（G-08）
- ただし **OS レベルでは read-only ボリュームにならない。** Finder は書けると認識してドラッグを許可し、
  そのあと失敗する。異常ではない
- **保存 ≠ 即クラウド同期。** VFS write-back により反映は 30 秒程度。アプリは「未送信 N 件」として可視化する
- **公開バケットは秘匿性ゼロ。** key を知れば誰でも読める。取り下げは削除ではなく `gone/` への移動
- **期限付きリンクは発行後に取り消せない。** 署名はローカル計算で完結し、サーバに状態を持たないため
- **単一利用者・単一 Mac が前提。** localhost NFS は認証なしで待ち受けるので、共有 Mac では使わない

## ドキュメント

作業を始める前に [CLAUDE.md](CLAUDE.md)（名前の階層と判断のルール）と `docs/STATUS.md` を読んでください。

| ファイル | 内容 |
|---|---|
| [docs/STATUS.md](docs/STATUS.md) | **対応状況の台帳。確定事項 / 未確定 / 次アクション。まずここ** |
| [docs/README.md](docs/README.md) | 資料インデックスと資料間の関係 |
| [docs/IMPLEMENTATION-NOTES.md](docs/IMPLEMENTATION-NOTES.md) | **実装したら設計書と食い違った点。着手前に必読** |
| `docs/FL-R2GUI-DD-001_v1.4.html` | GUI 版の詳細設計書 |
| `docs/FL-R2FS-DD-001_v1.4.html` | CLI 版。技術基盤と R2 側の構築手順はこちらが正 |
| [docs/BUNDLED.md](docs/BUNDLED.md) | 同梱 rclone のバージョン・ハッシュ・実測済みの挙動 |
| [docs/design/README.md](docs/design/README.md) | ブランド原本と実測値 |

## 同梱しているもの

| | |
|---|---|
| [rclone](https://rclone.org/) v1.75.0 | **MIT License** — Copyright (C) 2019 by Nick Craig-Wood。許諾文は `.app` 内の `Contents/Resources/rclone-LICENSE.txt` に同梱しています（`scripts/fetch-rclone.sh` が公式配布物から取り出します） |

> `LICENSE` は SkyFolder 本体の MIT 全文だけを置いています。第三者コードの表示をそこに混ぜると GitHub がライセンスを検出できなくなるためです。

SkyFolder 本体は **[MIT License](LICENSE)** です。利用・改変・再配布は自由で、著作権表示と許諾文を残すことだけが条件です。
