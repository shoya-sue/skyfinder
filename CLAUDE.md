# SkyFolder — プロジェクト context

Cloudflare R2 を macOS Finder にマウントし、URL で共有する macOS ネイティブアプリ。
**フォルダ名・リポジトリ名・プロダクト名・bundle id はすべて `skyfolder` / `SkyFolder` に揃えてある。**

## 名前の階層（事故が起きるので必ず守る）

| 対象 | 値 | 変更 |
|---|---|---|
| bundle identifier | `dev.fracturelab.skyfolder` | **不可**。変えると Keychain のアクセス権とログイン項目が切れ、ユーザーが Secret を再入力する羽目になる |
| 文書 ID | `FL-R2GUI-DD-001` / `FL-R2FS-DD-001` | **不可**。履歴の連続性を保つため、プロダクト名が変わっても据え置く |
| プロダクト名 | `SkyFolder` | 可（表示のみ） |
| リポジトリ / フォルダ名 | `skyfolder`（`r2-finder-mount-tool` → `skyfinder` → `skyfolder`・いずれも 2026-09-01） | 可・自由 |

**ソースコード内でリポジトリ名を参照しない**（設計書 §15.1）。改名しても壊れないことが要件。

## 着手前に読む順

1. `docs/STATUS.md` — **確定事項と未確定の台帳。次アクションはここから導く**
2. `docs/IMPLEMENTATION-NOTES.md` — 設計書どおりに実装すると壊れる 8 件（M-12〜M-26）。**設計書より優先**
3. `docs/README.md` — 資料インデックスと資料間の関係
4. `docs/FL-R2GUI-DD-001_v1.4.html` — GUI 版の詳細設計（本体の正）
5. `docs/FL-R2FS-DD-001_v1.4.html` — CLI 版。**R2 バケット作成・トークン発行・カスタムドメイン・CORS はこちらが唯一の正**

## 判断のルール

- **設計書と実装ノートが食い違ったら実装ノートが正。** 設計書 v1.4 は実装の反映を取り込んだ版だが、`IMPLEMENTATION-NOTES.md` にはなぜそう直したかの実測値が残る
- **「実装済み」と「検証済み」を分けて書く。** `docs/STATUS.md` の確定事項は証拠（テスト名・実測値・コマンド）とセットでしか増やさない
- **未検証を確定事項に混ぜない。** G1-9 / T-G18 / T-G28 / T-G29 / U-03 残りは手段が用意済みなだけで、まだ確かめていない

## 触るときの前提

- **git リポジトリではない**（2026-09-01 時点で未初期化）。変更の退避先が無いので、大きな改変の前に確認する
- 生成物（`.xcodeproj` / `Assets.xcassets` / `SkyFolder/Resources/rclone`）はコミット対象外。**唯一の正は `project.yml`・`docs/design/` の原本・`scripts/`**
- ビルド `./scripts/build.sh release` / テスト `./scripts/test.sh`（157 件・約 95 秒）/ 実 R2 検証 `./scripts/verify-r2.sh`
- 秘密情報は環境変数からのみ受け取る。ディスクにも引数にも置かない

## 設計上、忘れると事故になること

- **public バケットは read-only でマウント**（G-08）。公開を必ず共有ダイアログに通し、Exif 除去・slug 化・上書き確認を迂回させない構造。ただし **OS レベルでは read-only ボリュームにならない**ので Finder は書けると誤認する
- **Exif 除去（SEC-08）は MUST だが無言で壊れる。** ImageIO は properties をマージするので `kCFNull` の明示が要り、PNG テキストは PNG/IPTC/TIFF の 3 箇所を潰さないと消えない（M-15 / M-26）
- **公開バケットは秘匿性ゼロ。** 取り下げは削除ではなく `gone/` への移動。**期限付きリンクは発行後に取り消せない**
- **保存 ≠ 即クラウド同期**（VFS write-back で約 30 秒）。アプリは「未送信 N 件」として可視化する
- **単一利用者・単一 Mac が前提。** localhost NFS は認証なしで待ち受ける
