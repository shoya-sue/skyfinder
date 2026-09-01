# SkyFolder — 対応状況台帳

**このファイルの役割**: 「確定していること」と「まだ確定していないこと」を分けて置く。
次に何をやるかは **§4 だけを見て決められる**ようにしてある。

> **台帳の作り方（守らないと意味が無くなる）**
> - §1〜§2 に入れてよいのは、**証拠列（テスト名・実測値・コマンドの出力）が書けるものだけ**
> - 「実装した」は §1 に入らない。**確かめた**ものが §1 に入る
> - §3 の項目を根拠にした判断・見積り・設計変更をしない。**未検証は分析の入力にしない**
>
> 最終更新: 2026-09-01

---

## 1. 確定事項 — 決定（設計として固定済み）

変更するには設計書の改版が要る。実装の都合で曲げない。

| ID | 決定 | 出典 |
|---|---|---|
| D-01 | Finder マウントは **rclone nfsmount**（kext 不要） | DD-001 §3.1 / GUI §G-03 で macOS 26 時点で再評価・継続 |
| D-02 | **private / public の 2 バケット物理分離** | DD-001 §3.2 |
| D-04 | 期限付き共有は **presigned URL**（最大 7 日・カスタムドメイン不可） | DD-001 §3.3 |
| SEC-08 | 公開画像の **Exif（GPS 等）除去は必須（MUST）** | DD-001 §8.3 / GUI §7.4 |
| SEC-09 | **単一利用者・単一 Mac 前提**。localhost NFS は認証なしで待ち受ける | DD-001 |
| G-01 | GUI は **SwiftUI ネイティブ** | GUI §3.1 |
| G-02 | rclone は **rcd 常駐 + HTTP RC API** で制御（プロセスは常に 1 本） | GUI §3.2 |
| G-07 | 配布は **Developer ID 署名 + notarization**。App Sandbox 無効のため **MAS 配布は構造的に不可** | GUI §3.8 |
| G-08 | **public バケットは read-only でマウント**。Exif 除去の迂回を構造的に塞ぐ | GUI §3.7 |
| §15.1 | **bundle id `dev.fracturelab.skyfolder` と文書 ID は変更不可**。リポジトリ名・プロダクト名が変わっても追随させない | GUI §15.1 |
| §15.2.2 | 青 `#5DA7E4` = プロダクト、オレンジ `#E8710A` = 公開の警告。**役割で使い分け、公開表示に青を使わない** | GUI §15.2.2 |
| §8.6 | 冪等性は**操作ではなく「望む終了状態」に対して**取る | GUI §8.6 |

## 2. 確定事項 — 検証済み（証拠がある）

| 対象 | 結果 | 証拠 | 実施 |
|---|---|---|---|
| 自動テスト | **161 件全通過**（21 suites・約 95 秒） | `./scripts/test.sh` — 2026-09-01 に 3 回実行し、いずれも全通過 | 2026-09-01 |
| 署名済み `.app` の自己診断 | **19/20 通過・警告 1 件・FAIL なし**（警告は SEC-G06。下の行を参照） | `./scripts/build.sh release` → `--selftest`。署名は `flags=0x10002(adhoc,runtime)` / `TeamIdentifier=not set` | 2026-09-01 |
| U-03（ad-hoc の範囲） | Hardened Runtime 下で同梱 rclone を子プロセス実行できる | `--selftest` の U-03 が PASS（rclone v1.75.0 を取得） | 2026-09-01 |
| T-G30 | 配布物の SHA-256 が `BUNDLED.md` と一致（`f52ccc22…`）。署名後の実体は別値（`dcb48186…`）で正常 | `--selftest` の T-G30 / T-G30b | 2026-09-01 |
| T-G02 / T-G03 / T-G05 | rcd を `127.0.0.1:0` で起動して実ポート取得・認証なしは HTTP 401・`mount/types` に `nfsmount` | `--selftest` | 2026-09-01 |
| T-G10 | `~/.config/rclone/rclone.conf` を作らない（§4.1 MUST） | `--selftest` | 2026-09-01 |
| 設計書の受入基準 | T-Gxx **39 件中 30 件**を自動または実測で検証 | IMPLEMENTATION-NOTES §D | 2026-08-31 |
| GUI の起動 | オンボーディング描画・ロゴ透過・ブランドカラー・`NSImage(named:)` の解決を実機で確認 | 目視 | 2026-08-31 |
| mutation | 主要ガード 9 件に変異を当てて検出を確認。生き残り 2 件は**等価変異**と切り分け（M-16） | IMPLEMENTATION-NOTES §D | 2026-08-31 |
| 独立レビュー（同一ベンダー・別コンテキスト 4 体） | 20 指摘のうち **19 件を修正・1 件は根拠を書いて受容** | IMPLEMENTATION-NOTES §D | 2026-08-31 |
| 設計書の誤り | **8 件**（M-12 / M-13 / M-14 / M-15 / M-23 / M-25 / M-26 / T-G30）を実装側で回避済み | IMPLEMENTATION-NOTES §A・§C | 2026-08-31 |
| ブランドアセットのギャップ | A-02 / A-03 / A-04 / A-05 / A-06 を解消（A-03 は前提自体が誤りと実測で判明） | `docs/design/README.md` | 2026-08-31 |
| **SEC-G06 (a) は現状 未達**（＝未達であることが確定した） | ad-hoc 署名では data protection keychain に書けず **login.keychain へ落ちている**。`kSecAttrAccessible` は解釈されず、**画面ロック中も認証情報を読める** | `--selftest` の SEC-G06 が `activeMode=legacy` を出力（M-27 の修正で可視化） | 2026-09-01 |
| 自己診断が未達を隠さないこと | `warn` は通過数に数えず WARN ラベルと見出しの件数で出る。終了コードは落とさない | `SelfTestReportTests` 4 件 + **変異を当てて検出を確認**（集計を `filter(\.passed)` に戻すと落ちる） | 2026-09-01 |
| git 管理 | リポジトリを初期化し 75 ファイルを追跡。生成物（`.xcodeproj` / `Assets.xcassets` / 同梱 rclone）は除外されている | `git log` / `git ls-files` | 2026-09-01 |
| 同梱 rclone のライセンス | **MIT の許諾文を `.app` に同梱**（`Contents/Resources/rclone-LICENSE.txt`・1345 バイト / 23 行）。公式配布 zip に LICENSE ファイルは無く、README.txt から抽出している | `fetch-rclone.sh` 実行 → DMG をマウントして `.app` 内を確認 | 2026-09-01 |
| DMG のビルド | `./scripts/build.sh release dmg` で 37MB の `dist/SkyFolder.dmg` が生成される | 実行して成果物を確認 | 2026-09-01 |
| **配布物は Gatekeeper に拒否される** | ad-hoc 署名のため `spctl -a -t execute` → **`rejected`**。ダウンロード後は quarantine が付き、**初回はダブルクリックで開かない**。ただし**バンドル自体は健全**（`codesign -v --deep --strict` は通る） | quarantine 属性を付けて `spctl` / `codesign` で判定 | 2026-09-01 |
| 改名の追随 | Swift / sh / yml / json / md での旧名参照 **0 件**。設計書 §15.1 の「現在のリポジトリ名」を更新 | `grep -rn -i r2-finder` | 2026-09-01 |

**この 2 節の内容は、そのまま分析・見積り・設計判断の入力にしてよい。**

## 3. 未確定 — まだ確かめていない

**ここを根拠に「できている」と判断しない。** 手段が用意されていることと、確かめたことは別。

| ID | 内容 | 手段（用意済み） | 何が足りないか |
|---|---|---|---|
| **G1-9** | 実 R2 アカウントでの通し確認（SigV4・マルチパート・presigned 実失効・`Cache-Control` 実付与・未送信件数の遷移・`deletefile` 冪等性） | `./scripts/verify-r2.sh` | **R2 の認証情報**（環境変数 4 本） |
| **U-03（残り）** | **Developer ID 署名**での子プロセス実行。ad-hoc では確認済みだが証明書が違う | 加入後に `--selftest` | **Apple Developer Program** |
| **T-G28 / T-G29** | Developer ID 署名 + 公証 / 別 Mac で Gatekeeper 警告なし | `./scripts/build.sh release dmg` + `notarytool` | **同上** |
| **SEC-G06(a) の解消** | 現状が未達なのは**確定済み**（§2）。**Developer ID 署名で data protection keychain に切り替わるか**が未確認 | 加入後に `--selftest` の SEC-G06 が WARN → PASS になるか（G5-2） | **Apple Developer Program** |
| **T-G18** | Mac 再起動後にマウントが復活する | 実機で再起動 | **なし**（実行するだけで確かめられる） |
| **T-G13 / T-G21 の実 R2 版** | 未送信件数の遷移 / 公開画像の Exif 検査 | G1-9 のあと | G1-9 の完了 |
| **別ベンダーの独立レビュー** | Codex **未インストール**、Grok **402（残高切れ）**。レビュー内容は 1 行も得ていない | `codex exec -s read-only` / `grok -p` | **インストール / 残高**。買えたのは「別コンテキスト」までで、エラーの非相関性は不十分 |
| **A-01** | アイコン原本が 903px で、必要な 1024px に届かない（現在は 824px に縮小して配置する暫定対応） | `docs/design/icon.jpeg` を差し替えて `./scripts/make-assets.sh` | **1024px 以上の正方形の原本**（人手） |
| **A-07** | DMG 背景 | — | 未着手。**無くても配布は成立する** |
| U-06 / U-07 | R2 の料金 / FSEvents | — | 設計に影響しない・G-08 によりブロッカーではない |

### 3-1. 自己診断の SEC-G06 は実態を照合していなかった（2026-09-01 発見 → 同日修正・M-27）

**この節は解決済み。** 経緯を残すために置いてある。次アクションは無い。

修正前の `--selftest` は SEC-G06 を PASS にし、詳細に「data protection keychain が使える」を
**固定文字列**で出していた。`KeychainStore` は data protection が使えないと legacy へ落ちて成功を返すため、
**落ちていても同じ表示**になっていた（`SelfTest.swift` が `activeMode` を読んでいなかった）。

`activeMode` を読む形に直した結果、**実測は `legacy`** だった。
つまり **SEC-G06 (a) は未達**で、修正前はそれが「20/20 通過」の裏に隠れていた。
現在は `19/20 通過（警告 1 件）` と表示され、WARN 行に理由が出る。

- 詳細と実測値: `IMPLEMENTATION-NOTES.md` の **M-27**
- 未達そのものの扱い: §2（確定事項）と §3 の「SEC-G06(a) の解消」
- 再発防止: `SelfTestReportTests` 4 件。**変異を当てて検出することを確認済み**


## 4. 次に実施すること（依存順）

### 4-1. 今すぐできる（ブロッカーなし）

| # | 内容 | 完了条件 |
|---|---|---|
| 1 | **T-G18** — Mac を再起動してマウントが復活するか確かめる | 再起動後に Finder でマウントが見える。結果を §2 か §3 に移す |
| 2 | **Codex CLI をインストール**して別ベンダーレビューを 1 本通す | 出力末尾に `APPROVE` / `REQUEST_CHANGES` がある。**無ければ「結果を得ていない」** |

> **完了済み（2026-09-01）**
> - ~~git init~~ → `9accc11` で初期化・75 ファイル追跡（§2）
> - ~~自己診断の SEC-G06 を `activeMode` ベースに直す~~ → M-27 で修正。**その結果 SEC-G06 (a) の未達が確定**（§2 / §3-1）

### 4-2. R2 の認証情報が手に入ったらできる

| # | 内容 | 完了条件 |
|---|---|---|
| 3 | **G1-9** を通す | `./scripts/verify-r2.sh` が全項目通過。T-G13 / T-G21 の実 R2 版もここで閉じる |

> 設計書 §11 は G1-9 を「**省略して先へ進んではならない**」としている。G5 の前に置く。

### 4-3. Apple Developer Program 加入が前提（= G5）

| # | 内容 | 完了条件 |
|---|---|---|
| 4 | Developer ID 署名でビルドし `--selftest` | U-03 の残りが閉じる |
| 5 | 公証 + 別 Mac で Gatekeeper 確認 | T-G28 / T-G29 が閉じる |
| 6 | **SEC-G06 (a) の解消を確認**（現状は未達で確定・§2） | `--selftest` の SEC-G06 が **WARN → PASS** に変わり、詳細が `activeMode=dataProtection` になる |
| 7 | A-01 の原本差し替え | 1024px 原本を置いて `make-assets.sh` 再実行 |

> **G5 は仕上げではなくゴール達成の必須要件。** 加入前は Xcode でのローカルビルドが要るため、
> 「ターミナル操作は要らない」というプロダクトのゴールがそもそも成立しない。

### 4-4. 配布の前に（推奨）

- **別ベンダーの外部レビュー**（§3）。同一ベンダーの別コンテキストは最も弱い段
- 影響の重い過去の指摘（staging key の決定性・SEC-G03 のトグル・`reclaimedOrphans` の適用範囲）が
  再発していないことを、修正箇所のテストで確認する

---

## 参照

- `../CLAUDE.md` — 名前の階層と判断のルール
- `IMPLEMENTATION-NOTES.md` — 設計書との差分 M-12〜M-26（**設計書より優先**）
- `README.md` — 資料インデックス
- `BUNDLED.md` — 同梱 rclone のバージョンと実測済みの挙動
- `design/README.md` — ブランド原本と A-01〜A-07
