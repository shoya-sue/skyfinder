# SkyFolder — 対応状況台帳

**このファイルの役割**: 「確定していること」と「まだ確定していないこと」を分けて置く。
次に何をやるかは **§4 だけを見て決められる**ようにしてある。

> **台帳の作り方（守らないと意味が無くなる）**
> - §1〜§2 に入れてよいのは、**証拠列（テスト名・実測値・コマンドの出力）が書けるものだけ**
> - 「実装した」は §1 に入らない。**確かめた**ものが §1 に入る
> - §3 の項目を根拠にした判断・見積り・設計変更をしない。**未検証は分析の入力にしない**
>
> 最終更新: 2026-09-01 / 検証欄の出典は `IMPLEMENTATION-NOTES.md` §D と `docs/README.md`（**2026-08-31 に実施された記録**。本台帳の作成時に再実行してはいない）

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
| 自動テスト | **157 件全通過**（20 suites・94.501 秒） | `./scripts/test.sh` — **2026-09-01 に再実行して確認** | 2026-09-01 |
| 署名済み `.app` の自己診断 | **20/20 通過**（FAIL / SKIP なし） | `./scripts/build.sh release` → `--selftest`。署名は `flags=0x10002(adhoc,runtime)` / `TeamIdentifier=not set` — **2026-09-01 に再実行して確認** | 2026-09-01 |
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
| 改名の追随 | Swift / sh / yml / json / md での旧名参照 **0 件**。設計書 §15.1 の「現在のリポジトリ名」を更新 | `grep -rn -i r2-finder`（本台帳作成時に実行） | 2026-09-01 |

**この 2 節の内容は、そのまま分析・見積り・設計判断の入力にしてよい。**

## 3. 未確定 — まだ確かめていない

**ここを根拠に「できている」と判断しない。** 手段が用意されていることと、確かめたことは別。

| ID | 内容 | 手段（用意済み） | 何が足りないか |
|---|---|---|---|
| **G1-9** | 実 R2 アカウントでの通し確認（SigV4・マルチパート・presigned 実失効・`Cache-Control` 実付与・未送信件数の遷移・`deletefile` 冪等性） | `./scripts/verify-r2.sh` | **R2 の認証情報**（環境変数 4 本） |
| **U-03（残り）** | **Developer ID 署名**での子プロセス実行。ad-hoc では確認済みだが証明書が違う | 加入後に `--selftest` | **Apple Developer Program** |
| **T-G28 / T-G29** | Developer ID 署名 + 公証 / 別 Mac で Gatekeeper 警告なし | `./scripts/build.sh release dmg` + `notarytool` | **同上** |
| **SEC-G06(a)** | 画面ロック中は認証情報を読めない、が成立しているか。**現在どちらの keychain を使っているか自体が分かっていない**（下記） | 加入後に再確認（G5-2）+ 診断の是正 | **同上**、加えて**診断の表示が当てにならない**（§3-1） |
| **T-G18** | Mac 再起動後にマウントが復活する | 実機で再起動 | **なし**（実行するだけで確かめられる） |
| **T-G13 / T-G21 の実 R2 版** | 未送信件数の遷移 / 公開画像の Exif 検査 | G1-9 のあと | G1-9 の完了 |
| **別ベンダーの独立レビュー** | Codex **未インストール**、Grok **402（残高切れ）**。レビュー内容は 1 行も得ていない | `codex exec -s read-only` / `grok -p` | **インストール / 残高**。買えたのは「別コンテキスト」までで、エラーの非相関性は不十分 |
| **A-01** | アイコン原本が 903px で、必要な 1024px に届かない（現在は 824px に縮小して配置する暫定対応） | `docs/design/icon.jpeg` を差し替えて `./scripts/make-assets.sh` | **1024px 以上の正方形の原本**（人手） |
| **A-07** | DMG 背景 | — | 未着手。**無くても配布は成立する** |
| U-06 / U-07 | R2 の料金 / FSEvents | — | 設計に影響しない・G-08 によりブロッカーではない |

### 3-1. 自己診断の SEC-G06 は結果を実態と照合していない（2026-09-01 発見・未修正）

`--selftest` は SEC-G06 を PASS にし、詳細に **「data protection keychain が使える」と表示する。
だがこの文字列は固定値で、実際にどちらの keychain を使ったかを見ていない。**

- `SkyFolder/Core/Diag/SelfTest.swift:139` — `add("SEC-G06", ..., readBack == "probe", "data protection keychain が使える")`
- `KeychainStore.write` は `modesToTry = [.dataProtection, .legacy]` を順に試し、
  **data protection が `errSecMissingEntitlement` で落ちても legacy で成功すれば成功を返す**（`KeychainStore.swift:94`）
- どちらで通ったかは `KeychainStore.activeMode` に残る。**診断はそれを読んでいない**

**帰結**: legacy へフォールバックしていても診断は「data protection keychain が使える」と表示する。
`KeychainStore.swift` の docstring が「黙って落ちると SEC-G06 (a) が満たされていない事実が見えなくなる」として
避けようとした欠陥が、**表示側で復活している**。M-24 の実測（ad-hoc + Hardened Runtime で `-34018`）が今も成り立つなら、
**現在は legacy で動いていて SEC-G06(a) は未達**ということになるが、**診断からはそれを判別できない**。

> **この項目は「PASS した」を根拠にしてはいけない。** 診断を `activeMode` ベースに直すまで、SEC-G06 の状態は未確定。

## 4. 次に実施すること（依存順）

### 4-1. 今すぐできる（ブロッカーなし）

| # | 内容 | 完了条件 |
|---|---|---|
| 0 | **自己診断の SEC-G06 を `activeMode` ベースに直す**（§3-1）。1 行の表示修正で、アプリの振る舞いは変えない | `--selftest` の詳細が `dataProtection` / `legacy` を実際に出し分ける。`legacy` なら **PASS ではなく警告**にする |
| 1 | **git init** — 現在このプロジェクトは git リポジトリではない。変更の退避先が無い | `git log` が初回コミットを返す。`.gitignore` は整備済み |
| 2 | **T-G18** — Mac を再起動してマウントが復活するか確かめる | 再起動後に Finder でマウントが見える。結果を §2 か §3 に移す |
| 3 | **Codex CLI をインストール**して別ベンダーレビューを 1 本通す | 出力末尾に `APPROVE` / `REQUEST_CHANGES` がある。**無ければ「結果を得ていない」** |

### 4-2. R2 の認証情報が手に入ったらできる

| # | 内容 | 完了条件 |
|---|---|---|
| 4 | **G1-9** を通す | `./scripts/verify-r2.sh` が全項目通過。T-G13 / T-G21 の実 R2 版もここで閉じる |

> 設計書 §11 は G1-9 を「**省略して先へ進んではならない**」としている。G5 の前に置く。

### 4-3. Apple Developer Program 加入が前提（= G5）

| # | 内容 | 完了条件 |
|---|---|---|
| 5 | Developer ID 署名でビルドし `--selftest` | U-03 の残りが閉じる |
| 6 | 公証 + 別 Mac で Gatekeeper 確認 | T-G28 / T-G29 が閉じる |
| 7 | `kSecUseDataProtectionKeychain` の再確認 | SEC-G06(a) が担保される（診断画面の表示が data protection になる） |
| 8 | A-01 の原本差し替え | 1024px 原本を置いて `make-assets.sh` 再実行 |

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
